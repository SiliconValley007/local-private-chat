"""Kill a signed-in session without waiting for the JWT to expire.

Auth is a signed JWT with no server-side row per login, so the only cheap way
to make an old token stop working is to bump a version on the user and reject
any token that still carries the previous one. Closing live websockets is what
makes the kill feel immediate on a phone that is already connected.
"""

from __future__ import annotations

from sqlalchemy.orm import Session

from app.models import User


def bump_token_version(db: Session, user: User) -> int:
    """Invalidates every outstanding JWT for [user]. Returns the new version."""
    user.token_version = int(user.token_version or 0) + 1
    db.add(user)
    db.commit()
    db.refresh(user)
    return int(user.token_version)


def token_version_matches(user: User, payload: dict) -> bool:
    """True when the JWT was issued for the user's current version."""
    claimed = payload.get("tv", 0)
    try:
        claimed_i = int(claimed)
    except (TypeError, ValueError):
        claimed_i = 0
    return claimed_i == int(user.token_version or 0)
