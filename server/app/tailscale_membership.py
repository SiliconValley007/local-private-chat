"""Tailscale OAuth membership: who is on the tailnet, bound to which account.

The phone's Tailscale connect/disconnect flow is separate. This module only
answers "is this authenticated 100.x caller still a member of the tailnet?"
and keeps Local Chat accounts aligned with that answer.

When OAuth is not configured, nothing here runs — existing servers keep working
on a LAN. When it is configured, messaging fails closed if the membership
snapshot is stale, and a vanished identity is suspended (history kept).
"""

from __future__ import annotations

import asyncio
import base64
import ipaddress
import json
import logging
import socket
import subprocess
import threading
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import HTTPException, Request, status
from sqlalchemy import delete, or_, select
from sqlalchemy.orm import Session

from app import audit
from app.config import (
    TAILSCALE_GRACE_SECONDS,
    TAILSCALE_OAUTH_CLIENT_ID,
    TAILSCALE_OAUTH_CLIENT_SECRET,
    TAILSCALE_POLL_SECONDS,
    TAILSCALE_STALE_AFTER_SECONDS,
    TAILSCALE_TAILNET,
)
from app.models import DeviceToken, User, utcnow

logger = logging.getLogger(__name__)

CGNAT = ipaddress.ip_network("100.64.0.0/10")
SHARED_BINDING_PREFIX = "shared:"

NOT_ON_TAILNET = "Your account is not on this tailnet."
MEMBERSHIP_STALE = (
    "Tailnet membership cannot be verified right now. Messaging is paused "
    "until the server can refresh it."
)
CONNECT_OVER_TAILSCALE = "Connect over Tailscale to use this server."

_lock = threading.Lock()
_snapshot: MembershipSnapshot | None = None
_oauth_token: str | None = None
_oauth_token_expires: datetime | None = None
_poll_error: str | None = None
# Brief cache of `tailscale whois` so a burst of requests from one shared
# phone does not spawn a process per HTTP call.
_whois_cache: dict[str, tuple[datetime, str | None, str | None]] = {}
_WHOIS_TTL = timedelta(seconds=60)


@dataclass(frozen=True)
class TailscaleIdentity:
    login: str
    user_id: str | None
    display: str
    addresses: tuple[str, ...]


@dataclass(frozen=True)
class TailscaleDevice:
    """One machine in the tailnet, whether or not it is online right now."""

    node_id: str
    name: str
    login: str
    addresses: tuple[str, ...]


@dataclass
class MembershipSnapshot:
    fetched_at: datetime
    identities: dict[str, TailscaleIdentity] = field(default_factory=dict)
    login_by_ip: dict[str, str] = field(default_factory=dict)
    devices: dict[str, TailscaleDevice] = field(default_factory=dict)
    node_by_ip: dict[str, str] = field(default_factory=dict)
    shared_users: dict[str, str] = field(default_factory=dict)
    shares_verified: bool = False
    shares_error: str | None = None
    error: str | None = None

    @property
    def logins(self) -> set[str]:
        return set(self.identities)

    @property
    def node_ids(self) -> set[str]:
        return set(self.devices)

    def stale(self, *, now: datetime | None = None, max_age: int | None = None) -> bool:
        age = (now or datetime.now(timezone.utc)) - self.fetched_at
        limit = max_age if max_age is not None else TAILSCALE_STALE_AFTER_SECONDS
        return age > timedelta(seconds=limit)


def membership_configured() -> bool:
    return bool(
        TAILSCALE_OAUTH_CLIENT_ID
        and TAILSCALE_OAUTH_CLIENT_SECRET
        and TAILSCALE_TAILNET
    )


def enforcement_active() -> bool:
    """Configured, and describing a tailnet this server actually belongs to.

    Credentials for somebody else's tailnet are worse than none at all: every
    answer they give is about unrelated machines, so no account can be matched
    and everyone is locked out of their own chat while nobody gains access.
    That is misconfiguration, not a security boundary, so the gate stands down
    and says so loudly instead of holding the door shut against its own users.
    """
    return membership_configured() and not serves_a_foreign_tailnet()


def current_snapshot() -> MembershipSnapshot | None:
    with _lock:
        return _snapshot


def install_snapshot(snapshot: MembershipSnapshot | None) -> None:
    """Tests (and the poller) replace the in-memory snapshot here."""
    global _snapshot
    with _lock:
        _snapshot = snapshot


def reset_membership_state() -> None:
    global _snapshot, _oauth_token, _oauth_token_expires, _poll_error, _own_address
    with _lock:
        _snapshot = None
        _oauth_token = None
        _oauth_token_expires = None
        _poll_error = None
        _own_address = None
        _whois_cache.clear()


def last_poll_error() -> str | None:
    """Why the newest Tailscale poll failed, in words an operator can act on."""
    with _lock:
        return _poll_error


def set_poll_error(reason: str | None) -> None:
    global _poll_error
    with _lock:
        _poll_error = reason


def membership_status(db: Session | None = None) -> dict[str, Any]:
    """Operator-facing summary of the membership gate: why chat is open or paused."""
    snap = current_snapshot()
    status_doc: dict[str, Any] = {
        "configured": membership_configured(),
        "tailnet": TAILSCALE_TAILNET or None,
        "client_id": _masked_client_id(),
        "poll_seconds": TAILSCALE_POLL_SECONDS,
        "stale_after_seconds": TAILSCALE_STALE_AFTER_SECONDS,
        "snapshot_at": snap.fetched_at.isoformat() if snap else None,
        "identities": sorted(snap.logins) if snap else [],
        "devices": sorted(d.name for d in snap.devices.values()) if snap else [],
        "shared_logins": sorted(snap.shared_users) if snap else [],
        "shares_verified": snap.shares_verified if snap else False,
        "shares_error": snap.shares_error if snap else None,
        "addresses": len(snap.login_by_ip) if snap else 0,
        "stale": snapshot_is_stale(),
        "last_error": last_poll_error(),
        "foreign_tailnet": serves_a_foreign_tailnet(),
        "own_address": own_tailnet_address(),
    }
    if db is not None:
        rows = list(db.scalars(select(User).order_by(User.username)).all())
        status_doc["accounts"] = [
            {
                "user_id": row.id,
                "username": row.username,
                "display_name": row.display_name,
                "login": row.tailscale_login or None,
                "device": row.tailscale_device or None,
                "shared": (row.tailscale_user_id or "").startswith(
                    SHARED_BINDING_PREFIX
                ),
                "suspended": row.suspended_at is not None,
                "admin": is_admin_user(db, row),
            }
            for row in rows
        ]
    return status_doc


def _masked_client_id() -> str | None:
    value = (TAILSCALE_OAUTH_CLIENT_ID or "").strip()
    if not value:
        return None
    return value if len(value) <= 6 else f"{value[:4]}…{value[-2:]}"


def is_cgnat_ip(value: str | None) -> bool:
    if not value:
        return False
    host = value.strip()
    if host.startswith("[") and "]" in host:
        host = host[1 : host.index("]")]
    if "%" in host:
        host = host.split("%", 1)[0]
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return False
    return addr in CGNAT


def client_ip(request: Request | None) -> str | None:
    if request is None:
        return None
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",", 1)[0].strip()
    if request.client is not None:
        return request.client.host
    return None


def parse_devices_payload(payload: dict[str, Any]) -> MembershipSnapshot:
    """Turn a Tailscale devices API document into a lookup snapshot."""
    devices = payload.get("devices")
    if not isinstance(devices, list):
        devices = []
    identities: dict[str, TailscaleIdentity] = {}
    login_by_ip: dict[str, str] = {}
    nodes: dict[str, TailscaleDevice] = {}
    node_by_ip: dict[str, str] = {}
    for raw in devices:
        if not isinstance(raw, dict) or raw.get("authorized") is False:
            continue
        login, user_id, display = _identity_from_device(raw)
        addresses = _addresses_from_device(raw)
        device = _device_from_payload(raw, login=login, addresses=addresses)
        if device is not None:
            nodes[device.node_id] = device
            for ip in addresses:
                node_by_ip[ip] = device.node_id
        if not login:
            continue
        identities[login] = _merged_identity(
            identities.get(login),
            login=login,
            user_id=user_id,
            display=display,
            addresses=addresses,
        )
        for ip in addresses:
            login_by_ip[ip] = login
    return MembershipSnapshot(
        fetched_at=datetime.now(timezone.utc),
        identities=identities,
        login_by_ip=login_by_ip,
        devices=nodes,
        node_by_ip=node_by_ip,
    )


def apply_device_invites_payload(
    snapshot: MembershipSnapshot, payload: dict[str, Any] | list[Any]
) -> MembershipSnapshot:
    """Attach accepted recipients of the server device's Tailscale shares."""
    invites: Any = payload.get("invites", payload) if isinstance(payload, dict) else payload
    if not isinstance(invites, list):
        invites = []
    shared: dict[str, str] = {}
    for raw in invites:
        if not isinstance(raw, dict) or raw.get("accepted") is not True:
            continue
        accepted_by = raw.get("acceptedBy")
        if not isinstance(accepted_by, dict):
            continue
        login = str(
            accepted_by.get("loginName") or accepted_by.get("login") or ""
        ).strip()
        user_id = str(accepted_by.get("id") or "").strip()
        if login:
            shared[login] = user_id
    snapshot.shared_users = shared
    snapshot.shares_verified = True
    snapshot.shares_error = None
    return snapshot


def _device_from_payload(
    raw: dict[str, Any], *, login: str, addresses: tuple[str, ...]
) -> TailscaleDevice | None:
    node_id = str(raw.get("nodeId") or raw.get("id") or "").strip()
    if not node_id:
        return None
    return TailscaleDevice(
        node_id=node_id,
        name=_device_name(raw),
        login=login,
        addresses=addresses,
    )


def _merged_identity(
    existing: TailscaleIdentity | None,
    *,
    login: str,
    user_id: str | None,
    display: str,
    addresses: tuple[str, ...],
) -> TailscaleIdentity:
    """One person can own several devices; keep every address under one login."""
    merged = tuple(
        dict.fromkeys((*(existing.addresses if existing else ()), *addresses))
    )
    return TailscaleIdentity(
        login=login,
        user_id=user_id or (existing.user_id if existing else None),
        display=display or (existing.display if existing else login),
        addresses=merged,
    )


def _device_name(raw: dict[str, Any]) -> str:
    for key in ("name", "hostname"):
        value = str(raw.get(key) or "").strip()
        if value:
            return value.split(".", 1)[0]
    return "a tailnet device"


def _identity_from_device(raw: dict[str, Any]) -> tuple[str, str | None, str]:
    user = raw.get("user")
    login = ""
    user_id = None
    display = ""
    if isinstance(user, str):
        login = user.strip()
        display = login
    elif isinstance(user, dict):
        login = str(user.get("loginName") or user.get("login") or "").strip()
        user_id = str(user.get("id") or "").strip() or None
        display = str(user.get("displayName") or login).strip()
    if not login:
        login = str(raw.get("userName") or "").strip()
    return login, user_id, display or login


def _addresses_from_device(raw: dict[str, Any]) -> tuple[str, ...]:
    found: list[str] = []
    for key in ("addresses", "address"):
        value = raw.get(key)
        if isinstance(value, str) and is_cgnat_ip(value):
            found.append(value.strip())
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, str) and is_cgnat_ip(item):
                    found.append(item.strip())
    return tuple(dict.fromkeys(found))


def lookup_login_for_ip(
    ip: str | None, snapshot: MembershipSnapshot | None = None
) -> str | None:
    snap = snapshot if snapshot is not None else current_snapshot()
    if not ip or snap is None:
        return None
    return snap.login_by_ip.get(ip.strip())


def lookup_device_for_ip(
    ip: str | None, snapshot: MembershipSnapshot | None = None
) -> TailscaleDevice | None:
    snap = snapshot if snapshot is not None else current_snapshot()
    if not ip or snap is None:
        return None
    node_id = snap.node_by_ip.get(ip.strip())
    return snap.devices.get(node_id) if node_id else None


def account_is_on_tailnet(user: User, snapshot: MembershipSnapshot) -> bool:
    """Membership follows the device, which is what a person actually owns.

    One Tailscale account usually owns every phone in a household, so asking
    "is this account's login in the tailnet?" would answer yes for anyone who
    borrows the owner's login and no for the second person in the house. The
    honest question is whether the machine they sign in from is still a member,
    and a member device counts whether or not it is online right now.
    """
    node = (user.tailscale_node_id or "").strip()
    if node:
        return node in snapshot.devices
    shared_binding = (user.tailscale_user_id or "").startswith(
        SHARED_BINDING_PREFIX
    )
    # Rows bound before devices were tracked still answer on their login, so an
    # upgrade does not suspend everyone until they next connect.
    login = (user.tailscale_login or "").strip()
    if not login:
        return False
    if shared_binding:
        # Never interpret a failed share-list request as a revoked share.
        return not snapshot.shares_verified or login in snapshot.shared_users
    return login in snapshot.logins


def is_admin_user(db: Session, user: User) -> bool:
    from app.admin import is_admin

    return is_admin(db, user)


def user_is_available(db: Session, user: User | None) -> bool:
    """Listed under Available on this tailnet, and allowed to receive chat."""
    if user is None:
        return False
    if user.suspended_at is not None:
        return False
    if not enforcement_active():
        return True
    if is_admin_user(db, user):
        return True
    snap = current_snapshot()
    if snap is None or snapshot_is_expired():
        return False
    if snap.stale():
        # Outage. Keep the accounts whose device we confirmed while we could
        # still ask, and refuse the ones we never confirmed.
        return was_confirmed_on_the_tailnet(user)
    return account_is_on_tailnet(user, snap)


def peer_left_tailnet(db: Session, user: User | None) -> bool:
    """Whether we *know* this person is off the tailnet, for what we tell people.

    Deliberately not :func:`user_is_available`. That one answers an
    authorization question and fails closed, so it says "no" while the snapshot
    is missing or stale — a server-side condition. Reporting that as "they are
    not on this tailnet" accuses every contact at once of something none of them
    did, which is exactly how a phone that is sitting online in the tailnet gets
    labelled as having left it. Messaging still pauses when membership cannot be
    verified; it just no longer blames the other person for it.
    """
    if user is None:
        return True
    if not enforcement_active():
        return False
    if user.suspended_at is not None:
        return True
    if is_admin_user(db, user):
        return False
    snap = current_snapshot()
    if snap is None or snap.stale():
        return False
    if not was_confirmed_on_the_tailnet(user):
        # Never seen here at all. That is not the same fact as having left, and
        # saying "not on this tailnet" about someone whose phone is simply
        # switched off is the accusation this whole gate keeps getting wrong.
        return False
    return not account_is_on_tailnet(user, snap)


def peer_is_pending(db: Session, user: User | None) -> bool:
    """Real, allowed, but never yet seen connecting over the tailnet.

    The server can only tie an account to a device when that account makes a
    request from it, so someone who has not opened the app since membership
    checking began is unknown rather than absent. They stay unreachable — we
    have confirmed nothing about them — but the app can say so honestly and
    tell you what would fix it.
    """
    if user is None or not enforcement_active():
        return False
    if user.suspended_at is not None or is_admin_user(db, user):
        return False
    snap = current_snapshot()
    if snap is None or snap.stale():
        return False
    return not was_confirmed_on_the_tailnet(user)


def user_is_listable(db: Session, user: User | None) -> bool:
    """Whether a chat can be *started* with them, which is a weaker question.

    Reading is gated where reading happens: an account with no device behind it
    is refused at its own request and gets no push, so it cannot see a word of
    what was sent to it. Nothing is therefore protected by also refusing the
    sender, while hiding someone the admin has already put on the tailnet means
    the first person to install the app can never be contacted — they have to
    guess they must open it before anyone can find them.
    """
    return user_is_available(db, user) or peer_is_pending(db, user)


def receivable_user_ids(db: Session, user_ids: set[int]) -> set[int]:
    if not user_ids:
        return set()
    if not membership_configured():
        return set(user_ids)
    rows = db.scalars(select(User).where(User.id.in_(user_ids))).all()
    return {row.id for row in rows if user_is_available(db, row)}


def push_targets(db: Session, user_ids: set[int]) -> set[int]:
    """Who may still be pushed to; a blocked account's tokens are dropped here.

    Leaving a blocked account's FCM tokens in the database means every future
    push depends on each call site remembering to filter. Deleting them makes
    the block converge on its own, and the activity log shows it happened.
    """
    allowed = receivable_user_ids(db, user_ids)
    blocked = set(user_ids) - allowed
    # Act only on positive knowledge. A stale snapshot blocks everyone, and a
    # Tailscale outage must not wipe the push tokens of the whole tailnet.
    if blocked and membership_configured() and not snapshot_is_stale():
        forget_push_tokens(db, blocked)
    return allowed


def forget_push_tokens(db: Session, user_ids: set[int]) -> int:
    """Drop push tokens for accounts that are not allowed to receive anything."""
    rows = list(
        db.scalars(select(DeviceToken).where(DeviceToken.user_id.in_(user_ids))).all()
    )
    if not rows:
        return 0
    per_user: dict[int, int] = {}
    for row in rows:
        per_user[row.user_id] = per_user.get(row.user_id, 0) + 1
    db.execute(delete(DeviceToken).where(DeviceToken.user_id.in_(per_user)))
    db.commit()
    for target_id, count in per_user.items():
        target = db.get(User, target_id)
        name = target.username if target is not None else f"user {target_id}"
        audit.record(
            db,
            action="tailscale.push_blocked",
            summary=(
                f"Notification for {name} was blocked and {count} device "
                "token(s) cleared: not on this tailnet"
            ),
            target_user_id=target_id,
            details={"tokens_cleared": count},
        )
    return len(rows)


def snapshot_is_stale() -> bool:
    if not membership_configured():
        return False
    snap = current_snapshot()
    if snap is None:
        return True
    return snap.stale()


_own_address: str | None = None


def own_tailnet_address() -> str | None:
    """This host's own 100.x address, asked of the routing table.

    No packets are sent: a UDP connect only picks the route that would be used.
    Only an answer is cached. Servers routinely start before Tailscale is up —
    a phone rebooting, a laptop resuming — and latching that first empty answer
    would leave the host unable to recognise itself until someone restarts it.
    """
    global _own_address  # pylint: disable=global-statement
    if _own_address:
        return _own_address
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.settimeout(0.5)
            probe.connect(("100.100.100.100", 53))
            found = probe.getsockname()[0]
    except OSError:
        return None
    _own_address = found if is_cgnat_ip(found) else None
    return _own_address


def serves_a_foreign_tailnet(snapshot: MembershipSnapshot | None = None) -> bool:
    """True when the credentials describe a tailnet this server is not part of.

    Clients can only reach this server over its tailnet, so its own address must
    be among the devices the API lists. When it is not, the OAuth client was
    created in another Tailscale account: the poll succeeds, and every answer it
    gives is about machines that have nothing to do with this chat.
    """
    snap = snapshot if snapshot is not None else current_snapshot()
    if snap is None or not membership_configured():
        return False
    mine = own_tailnet_address()
    if mine is None:
        return False
    return mine not in snap.node_by_ip


_foreign_tailnet_warned = False


def _warn_once_about_a_foreign_tailnet(snapshot: MembershipSnapshot) -> None:
    """Say it once per outage, not once a minute, and again if it recurs."""
    global _foreign_tailnet_warned  # pylint: disable=global-statement
    if not serves_a_foreign_tailnet(snapshot):
        _foreign_tailnet_warned = False
        return
    if _foreign_tailnet_warned:
        return
    _foreign_tailnet_warned = True
    logger.warning(
        "These OAuth credentials are for a different tailnet: this server is %s "
        "but that address is not among the %d device(s) they cover, so no "
        "account can be matched to a device and chat stays paused for everyone "
        "but the admin. Generate the OAuth client in the tailnet that lists this "
        "server. Run 'python run.py tailscale-check' for the full comparison.",
        own_tailnet_address(),
        len(snapshot.devices),
    )


def snapshot_is_expired() -> bool:
    """Stale for so long that even a confirmed account stops being trusted."""
    if not membership_configured():
        return False
    snap = current_snapshot()
    if snap is None:
        return True
    return snap.stale(max_age=max(TAILSCALE_STALE_AFTER_SECONDS, TAILSCALE_GRACE_SECONDS))


def was_confirmed_on_the_tailnet(user: User) -> bool:
    """Did a fresh snapshot ever tie this account to a tailnet device?"""
    return bool(user.tailscale_node_id or user.tailscale_login)


def enforce_authenticated_user(
    db: Session,
    user: User,
    request: Request | None = None,
    *,
    ip: str | None = None,
) -> User:
    """Bind from 100.x and refuse suspended / unbound / stale-snapshot callers."""
    if not enforcement_active():
        return user
    # The admin keeps a way in even while the gate is closed: a wrong OAuth
    # secret or an offline tailnet must never leave the server unadministrable.
    admin = is_admin_user(db, user)
    if snapshot_is_stale() and not admin:
        # Inside the grace window a confirmed account carries on: it is already
        # reaching us over the tailnet, which is the harder gate of the two.
        if snapshot_is_expired() or not was_confirmed_on_the_tailnet(user):
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=MEMBERSHIP_STALE,
            )
        if user.suspended_at is not None:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN, detail=NOT_ON_TAILNET
            )
        return user
    if snapshot_is_stale():
        return user
    bind_from_ip(db, user, ip if ip is not None else client_ip(request), actor=user)
    db.refresh(user)
    if user.suspended_at is not None and not admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail=NOT_ON_TAILNET
        )
    if not admin and not (user.tailscale_node_id or user.tailscale_login):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=CONNECT_OVER_TAILSCALE,
        )
    return user


def bind_on_login(db: Session, user: User, request: Request | None) -> User:
    """Same gates as a later request, so a suspended account cannot mint a JWT."""
    return enforce_authenticated_user(db, user, request)


def bind_from_ip(
    db: Session,
    user: User,
    ip: str | None,
    *,
    actor: User | None = None,
) -> bool:
    """Map an authenticated CGNAT source IP onto this Local Chat account."""
    if not membership_configured():
        return False
    snap = current_snapshot()
    if snap is None or snap.stale():
        return False
    device = lookup_device_for_ip(ip, snap)
    login = device.login if device is not None else lookup_login_for_ip(ip, snap)
    if device is not None or login:
        identity = snap.identities.get(login or "")
        return _bind_user_to_login(
            db,
            user,
            login=login or "",
            user_id=identity.user_id if identity else None,
            actor=actor or user,
            source=ip,
            device=device,
        )
    # Not in this tailnet's machine list. A share of the server device still
    # lets them reach us; Tailscale on this host can name that peer.
    return bind_shared_peer_from_ip(db, user, ip, actor=actor, snapshot=snap)


def bind_shared_peer_from_ip(
    db: Session,
    user: User,
    ip: str | None,
    *,
    actor: User | None = None,
    snapshot: MembershipSnapshot | None = None,
) -> bool:
    """Bind a Local Chat account that reached us only via a device share.

    The owner's OAuth device list never contains that phone. The admin map
    exists for the same reason. Asking Tailscale who owns this 100.x address
    is the same fact, learned at the moment they connect, so the operator
    does not have to pair names by hand.
    """
    snap = snapshot if snapshot is not None else current_snapshot()
    if snap is None or not snap.shares_verified:
        return False
    login, ts_user_id = whois_peer(ip)
    if not login or login not in snap.shared_users:
        return False
    shared_id = f"{SHARED_BINDING_PREFIX}{snap.shared_users[login] or ts_user_id or login}"
    conflict = db.scalar(
        select(User).where(User.tailscale_user_id == shared_id, User.id != user.id)
    )
    if conflict is not None:
        logger.warning(
            "Share %s is already bound to @%s; ignoring @%s from %s",
            login,
            conflict.username,
            user.username,
            ip,
        )
        return False
    user.tailscale_node_id = None
    user.tailscale_device = None
    return _bind_user_to_login(
        db,
        user,
        login=login,
        user_id=shared_id,
        actor=actor or user,
        source=f"whois:{ip}",
    )


def whois_peer(ip: str | None) -> tuple[str | None, str | None]:
    """(login, tailscale user id) for a CGNAT peer, or (None, None)."""
    if not ip or not is_cgnat_ip(ip):
        return None, None
    host = ip.strip()
    now = datetime.now(timezone.utc)
    with _lock:
        cached = _whois_cache.get(host)
        if cached and now - cached[0] < _WHOIS_TTL:
            return cached[1], cached[2]
    login, user_id = _run_tailscale_whois(host)
    with _lock:
        _whois_cache[host] = (now, login, user_id)
    return login, user_id


def _run_tailscale_whois(ip: str) -> tuple[str | None, str | None]:
    try:
        completed = subprocess.run(
            ["tailscale", "whois", "--json", ip],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        logger.debug("tailscale whois %s failed: %s", ip, exc)
        return None, None
    if completed.returncode != 0 or not completed.stdout.strip():
        return None, None
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None, None
    return _identity_from_whois(payload)


def _identity_from_whois(payload: dict[str, Any]) -> tuple[str | None, str | None]:
    profile = payload.get("UserProfile")
    if not isinstance(profile, dict):
        profile = payload.get("userProfile") if isinstance(payload.get("userProfile"), dict) else {}
    login = str(profile.get("LoginName") or profile.get("loginName") or "").strip()
    user_id = str(profile.get("ID") or profile.get("id") or "").strip() or None
    return (login or None), user_id


def _bind_user_to_login(
    db: Session,
    user: User,
    *,
    login: str,
    user_id: str | None,
    actor: User,
    source: str | None,
    admin_override: bool = False,
    device: TailscaleDevice | None = None,
) -> bool:
    # No conflict check on the login: several people in one household share the
    # Tailscale account that owns their phones, and refusing the second one used
    # to lock them out of Local Chat entirely. The device is the identity.
    changed = False
    previous = user.tailscale_login
    if login and user.tailscale_login != login:
        user.tailscale_login = login
        changed = True
    if user_id and user.tailscale_user_id != user_id:
        user.tailscale_user_id = user_id
        changed = True
    if device is not None and user.tailscale_node_id != device.node_id:
        user.tailscale_node_id = device.node_id
        user.tailscale_device = device.name
        changed = True
    if user.tailscale_bound_at is None:
        user.tailscale_bound_at = utcnow()
        changed = True
    restored = _restore_if_needed(user)
    if changed or restored:
        db.add(user)
        db.commit()
        db.refresh(user)
        where = f" on {device.name}" if device is not None else ""
        audit.record(
            db,
            action="tailscale.bound" if changed else "tailscale.restored",
            summary=(
                f"{actor.username} bound {user.username} to Tailscale "
                f"{login or 'this tailnet'}{where}"
                if changed
                else f"{user.username} was restored on Tailscale {login}"
            ),
            actor=actor,
            target_user_id=user.id,
            before_text=previous,
            after_text=login or (device.name if device else None),
            details={
                "source": source,
                "admin_override": admin_override,
                "device": device.name if device else None,
                "node_id": device.node_id if device else None,
            },
        )
    return changed or restored


def admin_bind_user(
    db: Session,
    *,
    user: User,
    login: str,
    actor: User,
) -> User:
    cleaned = login.strip()
    if not cleaned:
        raise HTTPException(
            status_code=400, detail="Provide a Tailscale login to bind."
        )
    snap = current_snapshot()
    if snap is None or snap.stale():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=MEMBERSHIP_STALE,
        )
    shared = cleaned in snap.shared_users
    member = cleaned in snap.identities
    # When the share list itself cannot be read, an explicit admin mapping is
    # the only way to name a share recipient. It is trusted until the list can
    # be read again, at which point an absent login suspends the account.
    unverified_share = not shared and not member and not snap.shares_verified
    if shared or unverified_share:
        user_id = f"{SHARED_BINDING_PREFIX}{snap.shared_users.get(cleaned) or cleaned}"
        source = "admin_shared_device" if shared else "admin_shared_device_unverified"
        conflict = db.scalar(
            select(User).where(
                User.tailscale_user_id == user_id,
                User.id != user.id,
            )
        )
        if conflict is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=(
                    f"That accepted server share is already mapped to "
                    f"@{conflict.username}."
                ),
            )
        # A shared-user mapping follows the accepted invite, not an old device
        # this Local Chat account might previously have used.
        user.tailscale_node_id = None
        user.tailscale_device = None
    elif member:
        user_id = snap.identities[cleaned].user_id
        source = "admin"
    else:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "That login is neither a member of this tailnet nor an accepted "
                "recipient of the server device share."
            ),
        )
    _bind_user_to_login(
        db,
        user,
        login=cleaned,
        user_id=user_id,
        actor=actor,
        source=source,
        admin_override=True,
    )
    db.refresh(user)
    return user


def apply_snapshot(db: Session, snapshot: MembershipSnapshot) -> dict[str, int]:
    """Suspend accounts whose identity left; restore those that returned."""
    install_snapshot(snapshot)
    if serves_a_foreign_tailnet(snapshot):
        # Installed so the operator can see what arrived, but never acted on:
        # suspending everyone because a stranger's tailnet does not list them
        # would be this server destroying its own accounts over a typo.
        return {"suspended": 0, "restored": 0, "skipped_foreign_tailnet": 1}
    suspended = 0
    restored = 0
    bound = list(
        db.scalars(
            select(User).where(
                or_(
                    User.tailscale_node_id.is_not(None),
                    User.tailscale_login.is_not(None),
                )
            )
        ).all()
    )
    for user in bound:
        where = (user.tailscale_device or user.tailscale_login or "").strip()
        # An admin is never suspended by the tailnet; the operator has to stay
        # able to sign in and re-bind identities from the app.
        if not account_is_on_tailnet(user, snapshot) and not is_admin_user(db, user):
            reason = (
                "server_share_revoked"
                if (user.tailscale_user_id or "").startswith(
                    SHARED_BINDING_PREFIX
                )
                else "left_tailnet"
            )
            if _suspend(db, user, reason=reason):
                suspended += 1
        else:
            if _restore_if_needed(user):
                db.commit()
                restored += 1
                audit.record(
                    db,
                    action="tailscale.restored",
                    summary=f"{user.username} is on the tailnet again ({where})",
                    target_user_id=user.id,
                    after_text=where,
                )
    return {
        "suspended": suspended,
        "restored": restored,
        "bound": len(bound),
    }


def _suspend(db: Session, user: User, *, reason: str) -> bool:
    if user.suspended_at is not None:
        return False
    user.suspended_at = utcnow()
    user.suspension_reason = reason
    from app.sessions import bump_token_version

    bump_token_version(db, user)
    tokens = list(
        db.scalars(select(DeviceToken).where(DeviceToken.user_id == user.id)).all()
    )
    if tokens:
        db.execute(delete(DeviceToken).where(DeviceToken.user_id == user.id))
    db.add(user)
    db.commit()
    audit.record(
        db,
        action="tailscale.suspended",
        summary=f"{user.username} was suspended ({reason}); history kept",
        target_user_id=user.id,
        after_text=reason,
        details={
            "login": user.tailscale_login,
            "tokens_cleared": len(tokens),
        },
    )
    try:
        from app.realtime.hub import hub

        loop = asyncio.get_running_loop()
        loop.create_task(hub.disconnect_user(user.id, code=4403))
    except RuntimeError:
        pass
    except Exception:  # pylint: disable=broad-exception-caught
        logger.debug("Could not disconnect sockets for suspended user %s", user.id)
    return True


def _restore_if_needed(user: User) -> bool:
    if user.suspended_at is None:
        return False
    user.suspended_at = None
    user.suspension_reason = None
    return True


def peer_server_access_revoked(user: User | None) -> bool:
    """The external Tailscale share of this server was explicitly revoked."""
    return bool(
        user is not None
        and user.suspended_at is not None
        and user.suspension_reason == "server_share_revoked"
    )


def refuse_if_peer_unavailable(
    db: Session, conversation_id: int, sender_id: int
) -> None:
    """Direct chats cannot continue with a peer we know has left the tailnet.

    Someone merely unconfirmed is let through. They cannot read the message
    until their own device answers for them, so holding the sender back
    protects nothing and instead makes the first message to any new member
    impossible to send.
    """
    from app.models import Conversation, ConversationMember

    conv = db.get(Conversation, conversation_id)
    if conv is None or conv.type != "dm":
        return
    rows = db.scalars(
        select(ConversationMember.user_id).where(
            ConversationMember.conversation_id == conversation_id
        )
    ).all()
    peer_id = next((uid for uid in rows if uid != sender_id), None)
    if peer_id is None:
        return
    peer = db.get(User, peer_id)
    if user_is_listable(db, peer):
        return
    if not peer_left_tailnet(db, peer):
        # We are the ones who cannot answer the question. Say that, rather than
        # telling someone their contact left a tailnet they are still on.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=MEMBERSHIP_STALE,
        )
    if peer_server_access_revoked(peer):
        who = (peer.display_name or peer.username) if peer is not None else "They"
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"{who}'s access to this server was revoked, so this message wasn't sent.",
        )
    # Name them. "This account is not on this tailnet" beside your own chat
    # reads as though you were the one who was removed.
    who = (peer.display_name or peer.username) if peer is not None else "They"
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail=f"{who} is not on this tailnet, so this message wasn't sent.",
    )


def refresh_membership(db: Session) -> MembershipSnapshot:
    """Fetch devices via OAuth and apply suspensions. Used by housekeeping."""
    return apply_membership_document(db, fetch_devices_document())


def apply_membership_document(db: Session, payload: dict[str, Any]) -> MembershipSnapshot:
    """Install an already-fetched devices document so network I/O can stay off the loop."""
    snapshot = parse_devices_payload(payload)
    apply_snapshot(db, snapshot)
    audit.record(
        db,
        action="tailscale.snapshot_refreshed",
        summary=f"Tailnet membership snapshot: {len(snapshot.logins)} identities",
        details={
            "identities": len(snapshot.logins),
            "addresses": len(snapshot.login_by_ip),
        },
    )
    return snapshot


def fetch_devices_document() -> dict[str, Any]:
    token = _oauth_access_token()
    tailnet = urllib.parse.quote(TAILSCALE_TAILNET, safe="")
    url = f"https://api.tailscale.com/api/v2/tailnet/{tailnet}/devices"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        logger.warning("Tailscale devices fetch failed: %s", describe_api_error(exc))
        raise


def fetch_device_invites_document(device_id: str) -> dict[str, Any] | list[Any]:
    """Accepted external users with whom the Local Chat server is shared."""
    token = _oauth_access_token()
    encoded = urllib.parse.quote(device_id, safe="")
    url = f"https://api.tailscale.com/api/v2/device/{encoded}/device-invites"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_server_device_invites(device_ids: Sequence[str]) -> dict[str, Any] | list[Any]:
    """Shares of the server device, addressed by whichever id the API accepts.

    Tailscale exposes a device under both a node id and a legacy numeric id, and
    the two are not interchangeable on every endpoint, so a 404 on the first is
    retried with the other before it counts as a failure.
    """
    error: BaseException | None = None
    for candidate in device_ids:
        try:
            return fetch_device_invites_document(candidate)
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            error = exc
    if error is not None:
        raise error
    raise RuntimeError("this server's device is not in the OAuth client's tailnet")


def _server_device_ids(payload: dict[str, Any]) -> tuple[str, ...]:
    own = own_tailnet_address()
    if not own:
        return ()
    devices = payload.get("devices")
    if not isinstance(devices, list):
        return ()
    for raw in devices:
        if not isinstance(raw, dict) or own not in _addresses_from_device(raw):
            continue
        found = []
        for key in ("nodeId", "id"):
            value = str(raw.get(key) or "").strip()
            if value and value not in found:
                found.append(value)
        if found:
            return tuple(found)
    return ()


def _server_device_id(payload: dict[str, Any]) -> str | None:
    ids = _server_device_ids(payload)
    return ids[0] if ids else None


def describe_api_error(exc: BaseException, *, context: str = "devices") -> str:
    """Translate a Tailscale API failure into the fix the operator has to make.

    The hint depends on which call failed. The device-share call addresses one
    device and carries no tailnet name at all, so blaming the tailnet there
    sends the operator after a setting that cannot be the cause.
    """
    if isinstance(exc, urllib.error.HTTPError):
        shares = {
            401: (
                "the OAuth client id or secret is wrong — regenerate the client "
                "and copy both values again"
            ),
            403: (
                'the OAuth client cannot read device shares — add the "Device '
                'invites: Read" scope to it, then copy the new id and secret'
            ),
            404: (
                "this call names the server device and no tailnet, so the "
                'tailnet setting is not the cause — the "Device invites: Read" '
                "scope is missing from the OAuth client, or the device running "
                "this server is not in that client's tailnet"
            ),
        }
        devices = {
            401: shares[401],
            403: (
                "the OAuth client is missing a scope — it needs Devices: Read "
                "(core) on the tailnet"
            ),
            404: (
                f"tailnet {TAILSCALE_TAILNET!r} was not found — use the name "
                "shown at the top of the Tailscale admin console, or '-'"
            ),
        }
        hint = (shares if context == "device_shares" else devices).get(exc.code)
        detail = f"HTTP {exc.code} {exc.reason}"
        return f"{detail} ({hint})" if hint else detail
    if isinstance(exc, urllib.error.URLError):
        return (
            f"cannot reach api.tailscale.com ({exc.reason}) — this server needs "
            "plain internet access, not only the tailnet"
        )
    return f"{type(exc).__name__}: {exc}"


def _oauth_access_token() -> str:
    global _oauth_token, _oauth_token_expires
    now = datetime.now(timezone.utc)
    with _lock:
        if (
            _oauth_token
            and _oauth_token_expires
            and _oauth_token_expires > now + timedelta(seconds=30)
        ):
            return _oauth_token
    raw = f"{TAILSCALE_OAUTH_CLIENT_ID}:{TAILSCALE_OAUTH_CLIENT_SECRET}".encode(
        "utf-8"
    )
    basic = base64.b64encode(raw).decode("ascii")
    body = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode("utf-8")
    req = urllib.request.Request(
        "https://api.tailscale.com/api/v2/oauth/token",
        data=body,
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    token = str(data.get("access_token") or "")
    if not token:
        raise RuntimeError("Tailscale OAuth token response had no access_token")
    expires_in = int(data.get("expires_in") or 3600)
    with _lock:
        _oauth_token = token
        _oauth_token_expires = now + timedelta(seconds=max(60, expires_in))
    return token


async def poll_once() -> None:
    if not membership_configured():
        return
    from app.db import SessionLocal

    try:
        # Only the HTTP call goes to a worker thread. Applying the snapshot stays
        # on the loop so suspensions can still close live WebSockets.
        payload = await asyncio.to_thread(fetch_devices_document)
    except Exception as exc:  # pylint: disable=broad-exception-caught
        reason = describe_api_error(exc)
        set_poll_error(reason)
        logger.warning(
            "Tailnet membership not verified: %s. Accounts already confirmed on "
            "this tailnet keep working for up to %d minutes; anyone not yet "
            "confirmed is paused now. Run 'python run.py tailscale-check' for "
            "details.",
            reason,
            max(TAILSCALE_STALE_AFTER_SECONDS, TAILSCALE_GRACE_SECONDS) // 60,
        )
        snap = current_snapshot()
        if snap is not None:
            snap.error = "poll_failed"
        return
    session = SessionLocal()
    try:
        snapshot = parse_devices_payload(payload)
        server_device_ids = _server_device_ids(payload)
        if server_device_ids:
            try:
                invites = await asyncio.to_thread(
                    fetch_server_device_invites, server_device_ids
                )
                apply_device_invites_payload(snapshot, invites)
            except Exception as exc:  # pylint: disable=broad-exception-caught
                # Core tailnet membership remains useful. Existing shared-user
                # bindings fail closed without being mistaken for revocations.
                snapshot.shares_verified = False
                snapshot.shares_error = describe_api_error(
                    exc, context="device_shares"
                )
                logger.warning(
                    "Tailscale device shares could not be verified: %s",
                    snapshot.shares_error,
                )
        apply_snapshot(session, snapshot)
        audit.record(
            session,
            action="tailscale.snapshot_refreshed",
            summary=f"Tailnet membership snapshot: {len(snapshot.logins)} identities",
            details={
                "identities": len(snapshot.logins),
                "addresses": len(snapshot.login_by_ip),
                "shared_users": len(snapshot.shared_users),
                "shares_verified": snapshot.shares_verified,
            },
        )
        set_poll_error(None)
        logger.info(
            "Tailnet membership verified: %d devices, %d identities, %d shared users",
            len(snapshot.devices),
            len(snapshot.logins),
            len(snapshot.shared_users),
        )
        _warn_once_about_a_foreign_tailnet(snapshot)
        from app.realtime.events import event_membership_changed
        from app.realtime.hub import hub

        await hub.broadcast_to_users(
            hub.online_user_ids(), event_membership_changed()
        )
    except Exception as exc:  # pylint: disable=broad-exception-caught
        set_poll_error(describe_api_error(exc))
        logger.exception("Tailscale membership poll failed")
        snap = current_snapshot()
        if snap is not None:
            snap.error = "poll_failed"
    finally:
        session.close()
