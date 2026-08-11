"""User listing and search."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_current_user
from app.models import User
from app.realtime.events import user_out
from app.realtime.hub import hub
from app.schemas import UserOut

router = APIRouter(prefix="/api/users", tags=["users"])


@router.get("", response_model=list[UserOut])
def list_users(
    q: str | None = Query(default=None, max_length=40),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[UserOut]:
    stmt = select(User).where(User.id != current.id)
    if q and q.strip():
        term = f"%{q.strip()}%"
        stmt = stmt.where(or_(User.username.ilike(term), User.display_name.ilike(term)))
    users = db.scalars(stmt.order_by(User.username).limit(50)).all()
    return [user_out(u, is_online=hub.is_online(u.id)) for u in users]


@router.get("/by-username/{username}", response_model=UserOut)
def get_by_username(
    username: str,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> UserOut:
    user = db.scalar(select(User).where(User.username == username.strip()))
    if user is None or user.id == current.id:
        raise HTTPException(
            status_code=404,
            detail="No one with that username is on this server.",
        )
    return user_out(user, is_online=hub.is_online(user.id))
