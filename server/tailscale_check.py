#!/usr/bin/env python3
"""Explain the Tailscale membership gate (run on the server host).

Usage (from the server/ folder, or beside LocalChatServer.exe):

    python run.py tailscale-check              # report configuration + API result
    python run.py tailscale-check --apply      # also suspend/restore from the result
    python run.py tailscale-check --unsuspend DDas   # break-glass: let one account in

When OAuth is configured but Tailscale cannot be reached, the server fails
closed and only the admin can sign in. This tool names the reason so the fix is
obvious: wrong secret, missing scope, wrong tailnet, or no internet.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Allow `python tailscale_check.py` from server/ without installing the package.
# pylint: disable=wrong-import-position,import-outside-toplevel
sys.path.insert(0, str(Path(__file__).resolve().parent))

from sqlalchemy import func, select  # noqa: E402

from app.models import User  # noqa: E402


def _print_config() -> bool:
    from app.config import TAILSCALE_OAUTH_PATH
    from app.tailscale_membership import membership_configured, membership_status

    status = membership_status()
    print("Tailscale membership")
    print(f"  Config file    : {TAILSCALE_OAUTH_PATH}")
    print(f"  File present   : {'yes' if TAILSCALE_OAUTH_PATH.is_file() else 'no'}")
    print(f"  Client id      : {status['client_id'] or '(not set)'}")
    print(f"  Tailnet        : {status['tailnet'] or '(not set)'}")
    print(f"  Poll seconds   : {status['poll_seconds']}")
    print(f"  Stale after    : {status['stale_after_seconds']}s")
    if not membership_configured():
        print()
        print(
            "OAuth is NOT configured, so membership enforcement is off and "
            "every account can sign in as before."
        )
        return False
    return True


def _print_accounts() -> None:
    from app import db as db_module
    from app.tailscale_membership import is_admin_user

    db_module.init_db()
    with db_module.SessionLocal() as db:
        rows = list(db.scalars(select(User).order_by(User.id)).all())
        if not rows:
            print("  (no accounts yet)")
            return
        for row in rows:
            marks = []
            if is_admin_user(db, row):
                marks.append("admin")
            if row.suspended_at is not None:
                marks.append(f"suspended: {row.suspension_reason or 'unknown'}")
            suffix = f"  [{', '.join(marks)}]" if marks else ""
            where = row.tailscale_device or row.tailscale_login or "(not bound)"
            print(f"  {row.username:<20} {where}{suffix}")


def _report(apply_changes: bool) -> int:
    if not _print_config():
        return 0

    from app.tailscale_membership import (
        _server_device_ids,
        apply_device_invites_payload,
        apply_snapshot,
        describe_api_error,
        fetch_devices_document,
        fetch_server_device_invites,
        parse_devices_payload,
    )

    print()
    print("Asking api.tailscale.com for the device list...")
    try:
        payload = fetch_devices_document()
    except Exception as exc:  # pylint: disable=broad-exception-caught
        print(f"  FAILED: {describe_api_error(exc)}", file=sys.stderr)
        print()
        print(
            "While this fails, only the admin account can sign in. Fix the "
            "value above and restart the server, or turn enforcement off with:"
        )
        print("    python run.py tailscale-check --disable")
        _warn_if_no_admin()
        return 1

    snapshot = parse_devices_payload(payload)
    print(
        f"  OK: {len(snapshot.devices)} devices, {len(snapshot.identities)} "
        f"identities, {len(snapshot.node_by_ip)} addresses"
    )
    for device in sorted(snapshot.devices.values(), key=lambda d: d.name):
        addresses = ", ".join(device.addresses) or "(no 100.x address)"
        print(f"  {device.name:<24} {addresses:<18} {device.login}")

    server_device_ids = _server_device_ids(payload)
    if server_device_ids:
        print()
        print(f"Checking accepted shares of device {server_device_ids[0]}...")
        try:
            invites = fetch_server_device_invites(server_device_ids)
            apply_device_invites_payload(snapshot, invites)
            print(f"  OK: {len(snapshot.shared_users)} accepted external user(s)")
            for login in sorted(snapshot.shared_users):
                print(f"  {login}")
        except Exception as exc:  # pylint: disable=broad-exception-caught
            snapshot.shares_error = describe_api_error(exc, context="device_shares")
            print(f"  FAILED: {snapshot.shares_error}", file=sys.stderr)
            print(
                "  Tailnet members still work. Shared-server mappings are kept "
                "and trusted, and the admin can still map a share by hand in "
                "the app's Activity log."
            )

    wrong_tailnet = _warn_if_server_is_not_in_this_tailnet(snapshot)

    if apply_changes:
        from app import db as db_module

        db_module.init_db()
        with db_module.SessionLocal() as db:
            apply_snapshot(db, snapshot)
            print()
            print(
                f"Applied snapshot: {len(snapshot.logins)} tailnet identities, "
                f"{len(snapshot.shared_users)} accepted server shares."
            )

    print()
    print("Local Chat accounts")
    _print_accounts()
    return 2 if wrong_tailnet else 0


def _warn_if_server_is_not_in_this_tailnet(snapshot) -> bool:
    """Catch an OAuth client generated in the wrong Tailscale account.

    This server can only be reached over the tailnet it serves, so its own
    100.x address has to be one of the devices the API just listed. When it is
    not, the credentials belong to some other account's tailnet — the check
    "succeeds" while answering about machines that have nothing to do with this
    chat, and every account stays unbound because no client address is ever
    found in the list.
    """
    from run import tailscale_ips

    mine = tailscale_ips()
    if not mine:
        print()
        print(
            "Note: this machine has no Tailscale address right now, so whether "
            "the device list above is the right tailnet could not be checked."
        )
        return False
    if any(address in snapshot.node_by_ip for address in mine):
        return False
    print()
    print("PROBLEM: this server is not in the tailnet those credentials cover.")
    print(f"  This server is {', '.join(mine)} on its tailnet.")
    print("  The device list above does not contain that address, so the OAuth")
    print("  client was created in a different Tailscale account. Membership is")
    print("  being checked against machines unrelated to this chat, which is why")
    print("  accounts stay '(not bound)' and contacts read 'Not on this tailnet'.")
    print()
    print("  Fix: sign in to login.tailscale.com as an owner or admin of the")
    print("  tailnet that lists THIS server, generate an OAuth client there with")
    print("  the Devices Read scope, put it in tailscale-oauth.env and restart.")
    return True


def _warn_if_no_admin() -> None:
    from app import admin as admin_rules
    from app import db as db_module

    db_module.init_db()
    with db_module.SessionLocal() as db:
        if admin_rules.admin_username(db) is not None:
            return
    print()
    print(
        "No admin account is appointed on this server, so while the check "
        "above fails nobody can sign in at all. Appoint one now:"
    )
    print("    python run.py set-admin <username>")


def _disable() -> int:
    from app.config import TAILSCALE_OAUTH_PATH

    if not TAILSCALE_OAUTH_PATH.is_file():
        print(f"No {TAILSCALE_OAUTH_PATH.name} to disable.")
        return 0
    parked = TAILSCALE_OAUTH_PATH.with_suffix(".env.disabled")
    if parked.exists():
        parked.unlink()
    TAILSCALE_OAUTH_PATH.rename(parked)
    print(f"Moved {TAILSCALE_OAUTH_PATH.name} to {parked.name}.")
    print(
        "Restart the server: membership enforcement is off and every account "
        "can sign in again. Rename the file back once the OAuth values are right."
    )
    return 0


def _unsuspend(username: str) -> int:
    from app import audit
    from app import db as db_module

    db_module.init_db()
    with db_module.SessionLocal() as db:
        account = db.scalar(
            select(User).where(func.lower(User.username) == username.strip().casefold())
        )
        if account is None:
            print(f"No user named {username!r}.", file=sys.stderr)
            return 1
        if account.suspended_at is None:
            print(f"@{account.username} is not suspended.")
            return 0
        account.suspended_at = None
        account.suspension_reason = None
        db.add(account)
        db.commit()
        audit.record(
            db,
            action="tailscale.unbound",
            summary=f"{account.username} was un-suspended from the server console",
            target_user_id=account.id,
            after_text="operator override",
        )
        print(f"@{account.username} can sign in again.")
        print(
            "The next membership poll will suspend them again unless their "
            "Tailscale identity is back on the tailnet."
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check why Tailscale membership is allowing or pausing chat.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply the fetched snapshot now (suspend/restore) instead of only reporting.",
    )
    parser.add_argument(
        "--unsuspend",
        metavar="USERNAME",
        help="Break glass: clear one account's suspension so it can sign in.",
    )
    parser.add_argument(
        "--disable",
        action="store_true",
        help="Park tailscale-oauth.env so enforcement is off after a restart.",
    )
    args = parser.parse_args(argv)
    if args.disable:
        return _disable()
    if args.unsuspend:
        return _unsuspend(args.unsuspend)
    return _report(apply_changes=args.apply)


if __name__ == "__main__":
    raise SystemExit(main())
