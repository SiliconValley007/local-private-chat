"""Auth routes."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import create_access_token, hash_password, verify_password
from app.db import get_db
from app.deps import get_current_user
from app.models import User
from app.realtime.events import user_out
from app.realtime.hub import hub
from app.schemas import (
    AuthResponse,
    ChangePasswordRequest,
    LoginRequest,
    RegisterRequest,
    UserOut,
)

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/register", response_model=AuthResponse)
def register(body: RegisterRequest, db: Session = Depends(get_db)) -> AuthResponse:
    existing = db.scalar(select(User).where(User.username == body.username))
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="That username is already taken. Please pick another one.",
        )
    display = (body.display_name or body.username).strip() or body.username
    user = User(
        username=body.username,
        password_hash=hash_password(body.password),
        display_name=display[:80],
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    token = create_access_token(user.id, user.username)
    return AuthResponse(token=token, user=user_out(user, is_online=True))


@router.post("/login", response_model=AuthResponse)
def login(body: LoginRequest, db: Session = Depends(get_db)) -> AuthResponse:
    user = db.scalar(select(User).where(User.username == body.username.strip()))
    if user is None or not verify_password(body.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password. Please try again.",
        )
    token = create_access_token(user.id, user.username)
    return AuthResponse(token=token, user=user_out(user, is_online=hub.is_online(user.id)))


@router.get("/me", response_model=UserOut)
def me(current: User = Depends(get_current_user)) -> UserOut:
    return user_out(current, is_online=hub.is_online(current.id))


@router.post("/change-password")
def change_password(
    body: ChangePasswordRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> dict[str, bool]:
    """Let a signed-in user replace their password (requires the current one).

    Forgotten passwords cannot use this route — an admin must run
    ``reset_password.py`` on the server instead.
    """
    if not verify_password(body.current_password, current.password_hash):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Current password is incorrect.",
        )
    if body.current_password == body.new_password:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Pick a new password that is different from the current one.",
        )
    current.password_hash = hash_password(body.new_password)
    db.add(current)
    db.commit()
    return {"ok": True}
