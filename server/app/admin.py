"""Who gets to read the activity log.

Exactly one account may, named by username because usernames are unique on a
server and a person can be told to type theirs. The name is kept in
``server_settings`` so it survives restarts and can be set from the app.

Claiming rules, in order:

1. ``LOCALCHAT_ADMIN_USERNAME`` in the environment wins outright, and cannot be
   changed from the app. Someone with a shell on the server box is already past
   any check this code could make.
2. With nobody appointed, the first signed-in account may claim **itself** —
   appointing someone else from a stranger's phone is not allowed.
3. Once appointed, only the current admin may hand the role on.

An optional ``admin_device_id`` pins the activity log to one install of that
account. Knowing the admin username is not enough; the request must also come
from the trusted device once a pin is set. The operator can clear the pin from
the server CLI if the trusted phone is gone.
"""

from __future__ import annotations

import os
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_current_user
from app.models import ServerSetting, User, utcnow

ADMIN_USERNAME_KEY = "admin_username"
ADMIN_DEVICE_KEY = "admin_device_id"

NOT_ADMIN_DETAIL = (
    "The activity log is only for the server's admin account."
)
WRONG_DEVICE_DETAIL = (
    "This phone is not the trusted admin device. Open the log on the phone "
    "that was trusted, or clear the pin from the server."
)


def env_admin_username() -> str | None:
    """Admin fixed by the environment, if the server was started with one."""
    value = (os.environ.get("LOCALCHAT_ADMIN_USERNAME") or "").strip()
    return value or None


def stored_admin_username(db: Session) -> str | None:
    row = db.get(ServerSetting, ADMIN_USERNAME_KEY)
    value = (row.value or "").strip() if row is not None else ""
    return value or None


def admin_username(db: Session) -> str | None:
    """The admin in force, environment first."""
    return env_admin_username() or stored_admin_username(db)


def admin_is_locked() -> bool:
    """True when the environment fixed the admin, so the app cannot change it."""
    return env_admin_username() is not None


def is_admin(db: Session, user: User) -> bool:
    current = admin_username(db)
    if current is None:
        return False
    return current.casefold() == user.username.casefold()


def may_claim(db: Session, user: User) -> bool:
    """May this account take, or hand on, the admin role?"""
    if admin_is_locked():
        return False
    if stored_admin_username(db) is None:
        return True
    return is_admin(db, user)


def stored_admin_device_id(db: Session) -> str | None:
    row = db.get(ServerSetting, ADMIN_DEVICE_KEY)
    value = (row.value or "").strip() if row is not None else ""
    return value or None


def admin_device_matches(db: Session, device_id: str | None) -> bool:
    """True when no pin is set, or [device_id] is the pinned install."""
    pinned = stored_admin_device_id(db)
    if pinned is None:
        return True
    if not device_id:
        return False
    return pinned == device_id.strip()


def set_admin_device_id(
    db: Session,
    *,
    device_id: str | None,
    actor: User,
) -> str | None:
    """Pins or clears the trusted admin device. Caller must already be admin."""
    cleaned = (device_id or "").strip() or None
    row = db.get(ServerSetting, ADMIN_DEVICE_KEY)
    if cleaned is None:
        if row is not None:
            db.delete(row)
            db.commit()
        return None
    if row is None:
        row = ServerSetting(key=ADMIN_DEVICE_KEY)
        db.add(row)
    row.value = cleaned
    row.updated_at = utcnow()
    row.updated_by = actor.id
    db.commit()
    return cleaned


def set_admin_username(db: Session, *, username: str, actor: User) -> str:
    """Appoints [username] as admin. The caller must already pass [may_claim]."""
    wanted = username.strip()
    if not wanted:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Type the username that should be the admin.",
        )
    # First claim may only appoint the caller's own account — otherwise a guest
    # who opened the app first could quietly hand the log to someone else.
    if stored_admin_username(db) is None and wanted.casefold() != actor.username.casefold():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                "While nobody is admin yet, you can only claim the role for "
                "your own username."
            ),
        )
    # Matched case-insensitively so the admin typed from memory still resolves,
    # then stored exactly as the account spells it.
    account = db.scalar(
        select(User).where(func.lower(User.username) == wanted.casefold())
    )
    if account is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No account on this server is called “{wanted}”.",
        )
    row = db.get(ServerSetting, ADMIN_USERNAME_KEY)
    if row is None:
        row = ServerSetting(key=ADMIN_USERNAME_KEY)
        db.add(row)
    row.value = account.username
    row.updated_at = utcnow()
    row.updated_by = actor.id
    # Handing the role to someone else clears any device pin from the old
    # phone — the new admin must trust theirs explicitly.
    if account.id != actor.id:
        pin = db.get(ServerSetting, ADMIN_DEVICE_KEY)
        if pin is not None:
            db.delete(pin)
    db.commit()
    return account.username


def require_admin(
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    """Dependency for admin identity (role only — not the device pin)."""
    if not is_admin(db, current):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=NOT_ADMIN_DETAIL,
        )
    return current


def require_admin_for_audit(
    current: Annotated[User, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
    x_device_id: Annotated[str | None, Header(alias="X-Device-Id")] = None,
) -> User:
    """Admin identity plus the trusted-device pin, for reading the activity log."""
    if not admin_device_matches(db, x_device_id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=WRONG_DEVICE_DETAIL,
        )
    return current


def status_fields(db: Session, current: User, *, device_id: str | None) -> dict:
    """Shared payload for /status and responses that return the same shape."""
    pinned = stored_admin_device_id(db)
    return {
        "admin_username": admin_username(db),
        "is_admin": is_admin(db, current),
        "can_claim": may_claim(db, current),
        "locked_by_server": admin_is_locked(),
        "my_username": current.username,
        "admin_device_pinned": pinned is not None,
        "this_device_trusted": bool(pinned and device_id and pinned == device_id),
        "needs_device_trust": is_admin(db, current) and pinned is None,
    }
