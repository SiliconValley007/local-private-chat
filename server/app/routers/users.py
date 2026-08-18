"""User listing, search, and profile avatars."""

from __future__ import annotations

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app import audit
from app.avatars import (
    avatar_media_type,
    avatar_rel_path,
    delete_avatar_file,
    new_stored_name,
    resolve_avatar_file,
    stream_avatar_to_disk,
    validate_image_header,
    validate_upload_metadata,
)
from app.db import get_db
from app.deps import get_current_user
from app.models import User, utcnow
from app.realtime.events import user_out
from app.realtime.hub import hub
from app.schemas import DisplayNameRequest, MoodRequest, UserOut
from app.services import broadcast_user_updated, set_user_display_name, set_user_mood

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


@router.post("/me/avatar", response_model=UserOut)
async def upload_my_avatar(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> UserOut:
    ext = validate_upload_metadata(file.filename or "", file.content_type)
    stored_name = new_stored_name(ext)
    rel_path = avatar_rel_path(current.id, stored_name)
    dest_path = resolve_avatar_file(rel_path)

    _size, header = await stream_avatar_to_disk(file, dest_path)
    try:
        validate_image_header(header, ext)
    except HTTPException:
        delete_avatar_file(rel_path)
        raise

    old_path = current.avatar_path
    now = utcnow()
    current.avatar_path = rel_path
    current.avatar_updated_at = now
    db.commit()
    db.refresh(current)
    audit.record(
        db,
        action="account.avatar_set",
        summary=f"{current.username} changed their profile photo",
        actor=current,
        before_text=old_path,
        after_text=rel_path,
    )

    delete_avatar_file(old_path)
    await broadcast_user_updated(db, current)
    return user_out(current, is_online=hub.is_online(current.id))


@router.delete("/me/avatar", response_model=UserOut)
async def delete_my_avatar(
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> UserOut:
    old_path = current.avatar_path
    if old_path:
        current.avatar_path = None
        current.avatar_updated_at = None
        db.commit()
        db.refresh(current)
        audit.record(
            db,
            action="account.avatar_removed",
            summary=f"{current.username} removed their profile photo",
            actor=current,
            before_text=old_path,
        )
        delete_avatar_file(old_path)
        await broadcast_user_updated(db, current)
    return user_out(current, is_online=hub.is_online(current.id))


@router.patch("/me/mood", response_model=UserOut)
async def patch_my_mood(
    body: MoodRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> UserOut:
    user = await set_user_mood(db, current, body.mood)
    return user_out(user, is_online=hub.is_online(user.id))


@router.patch("/me/display-name", response_model=UserOut)
async def patch_my_display_name(
    body: DisplayNameRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> UserOut:
    user = await set_user_display_name(db, current, body.display_name)
    return user_out(user, is_online=hub.is_online(user.id))


@router.get("/{user_id}/avatar")
async def get_user_avatar(
    user_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    del current  # any authenticated user may fetch avatars
    user = db.get(User, user_id)
    if user is None or not user.avatar_path:
        raise HTTPException(status_code=404, detail="This user has no profile picture.")
    full = resolve_avatar_file(user.avatar_path)
    if not full.is_file():
        raise HTTPException(status_code=404, detail="This user has no profile picture.")
    return FileResponse(
        path=full,
        media_type=avatar_media_type(user.avatar_path),
        content_disposition_type="inline",
    )
