"""Conversations: DMs, groups, inbox."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app import audit
from app.db import get_db
from app.deps import get_current_user
from app.models import Conversation, ConversationMember, User
from app.realtime import events
from app.realtime.events import conversation_out, member_out
from app.realtime.hub import hub
from app.schemas import (
    AddMembersRequest,
    AnniversaryRequest,
    ConversationOut,
    CreateDmRequest,
    CreateGroupRequest,
    DisappearingRequest,
    MemberOut,
    NudgeOut,
    WallpaperDimRequest,
)
from app.services import (
    clear_conversation_wallpaper,
    list_nudge_events,
    member_user_ids,
    nudge_out,
    require_membership,
    set_anniversary,
    set_conversation_wallpaper,
    set_disappearing,
    update_wallpaper_dim,
)
from app.wallpapers import (
    delete_wallpaper_file,
    new_stored_name,
    resolve_wallpaper_file,
    stream_wallpaper_to_disk,
    validate_image_header,
    validate_upload_metadata,
    wallpaper_media_type,
    wallpaper_rel_path,
)

router = APIRouter(prefix="/api/conversations", tags=["conversations"])

CHAT_NOT_FOUND = "That chat is no longer available."


def _load_conv(db: Session, conversation_id: int) -> Conversation | None:
    return db.scalar(
        select(Conversation)
        .where(Conversation.id == conversation_id)
        .options(selectinload(Conversation.members).selectinload(ConversationMember.user))
    )


def _conversation_out(db: Session, conv: Conversation, viewer: User) -> ConversationOut:
    return conversation_out(db, conv, viewer, is_online_fn=hub.is_online)


@router.get("", response_model=list[ConversationOut])
def list_conversations(
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[ConversationOut]:
    conv_ids = db.scalars(
        select(ConversationMember.conversation_id).where(ConversationMember.user_id == current.id)
    ).all()
    if not conv_ids:
        return []
    convs = db.scalars(
        select(Conversation)
        .where(Conversation.id.in_(conv_ids))
        .options(selectinload(Conversation.members).selectinload(ConversationMember.user))
    ).all()
    outs = [_conversation_out(db, c, current) for c in convs]
    outs.sort(key=lambda c: c.updated_at, reverse=True)
    return outs


@router.post("/dm", response_model=ConversationOut)
async def create_or_get_dm(
    body: CreateDmRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    if body.user_id == current.id:
        raise HTTPException(status_code=400, detail="You can't start a chat with yourself.")
    other = db.get(User, body.user_id)
    if other is None:
        raise HTTPException(
            status_code=404,
            detail="That user isn't on this server anymore.",
        )

    a, b = sorted([current.id, body.user_id])
    dm_key = f"{a}:{b}"
    existing = db.scalar(select(Conversation).where(Conversation.dm_key == dm_key))
    if existing:
        conv = _load_conv(db, existing.id)
        assert conv is not None
        return _conversation_out(db, conv, current)

    conv = Conversation(type="dm", title=None, dm_key=dm_key, created_by=current.id)
    db.add(conv)
    db.flush()
    db.add(ConversationMember(conversation_id=conv.id, user_id=current.id, role="member"))
    db.add(ConversationMember(conversation_id=conv.id, user_id=other.id, role="member"))
    db.commit()
    audit.record(
        db,
        action="conversation.created",
        summary=f"{current.username} started a direct chat with {other.username}",
        actor=current,
        conversation_id=conv.id,
        target_user_id=other.id,
        details={"type": "dm"},
    )
    conv = _load_conv(db, conv.id)
    assert conv is not None
    await hub.broadcast_to_users(
        {current.id, other.id},
        events.event_conversation_updated(conv.id),
    )
    return _conversation_out(db, conv, current)


@router.post("/groups", response_model=ConversationOut)
async def create_group(
    body: CreateGroupRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    title = body.title.strip()
    if not title:
        raise HTTPException(status_code=400, detail="Please enter a name for the group.")

    member_ids = set(body.member_ids)
    member_ids.discard(current.id)
    users = db.scalars(select(User).where(User.id.in_(member_ids))).all() if member_ids else []
    if len(users) != len(member_ids):
        raise HTTPException(
            status_code=400,
            detail="Some of the people you picked are no longer on this server.",
        )

    conv = Conversation(type="group", title=title[:120], created_by=current.id)
    db.add(conv)
    db.flush()
    db.add(ConversationMember(conversation_id=conv.id, user_id=current.id, role="admin"))
    for u in users:
        db.add(ConversationMember(conversation_id=conv.id, user_id=u.id, role="member"))
    db.commit()
    audit.record(
        db,
        action="conversation.created",
        summary=f"{current.username} created the group “{title}”",
        actor=current,
        conversation_id=conv.id,
        after_text=title,
        details={"type": "group", "member_ids": sorted(u.id for u in users)},
    )

    conv = _load_conv(db, conv.id)
    assert conv is not None
    await hub.broadcast_to_users(
        member_user_ids(db, conv.id),
        events.event_conversation_updated(conv.id),
    )
    return _conversation_out(db, conv, current)


@router.get("/{conversation_id}/members", response_model=list[MemberOut])
def get_members(
    conversation_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[MemberOut]:
    require_membership(db, conversation_id, current.id)
    conv = _load_conv(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail=CHAT_NOT_FOUND)
    return [
        member_out(m, is_online=hub.is_online(m.user_id))
        for m in conv.members
    ]


@router.post("/{conversation_id}/members", response_model=ConversationOut)
async def add_members(
    conversation_id: int,
    body: AddMembersRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    membership = require_membership(db, conversation_id, current.id)
    conv = _load_conv(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail=CHAT_NOT_FOUND)
    if conv.type != "group":
        raise HTTPException(
            status_code=400,
            detail="You can only add people to a group chat.",
        )
    if membership.role != "admin":
        raise HTTPException(
            status_code=403,
            detail="Only a group admin can add people to this group.",
        )

    existing = {m.user_id for m in conv.members}
    added: list[int] = []
    added_usernames: list[str] = []
    for uid in body.member_ids:
        if uid in existing:
            continue
        user = db.get(User, uid)
        if user is None:
            raise HTTPException(
                status_code=400,
                detail="One of the people you picked is no longer on this server.",
            )
        db.add(ConversationMember(conversation_id=conv.id, user_id=uid, role="member"))
        added.append(uid)
        added_usernames.append(user.username)
    db.commit()
    if added:
        audit.record(
            db,
            action="conversation.members_added",
            summary=(
                f"{current.username} added "
                f"{', '.join(added_usernames)} to chat {conversation_id}"
            ),
            actor=current,
            conversation_id=conversation_id,
            details={"member_ids": added, "member_usernames": added_usernames},
        )
    conv = _load_conv(db, conversation_id)
    assert conv is not None
    await hub.broadcast_to_users(
        member_user_ids(db, conv.id),
        events.event_conversation_updated(conv.id),
    )
    return _conversation_out(db, conv, current)


@router.put("/{conversation_id}/wallpaper", response_model=ConversationOut)
async def upload_wallpaper(
    conversation_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    require_membership(db, conversation_id, current.id)
    ext = validate_upload_metadata(file.filename or "", file.content_type)
    stored_name = new_stored_name(ext)
    rel_path = wallpaper_rel_path(conversation_id, stored_name)
    dest_path = resolve_wallpaper_file(rel_path)

    _size, header = await stream_wallpaper_to_disk(file, dest_path)
    try:
        validate_image_header(header, ext)
    except HTTPException:
        delete_wallpaper_file(rel_path)
        raise

    conv = await set_conversation_wallpaper(
        db,
        conversation_id=conversation_id,
        user=current,
        rel_path=rel_path,
    )
    return _conversation_out(db, conv, current)


@router.patch("/{conversation_id}/wallpaper/dim", response_model=ConversationOut)
async def patch_wallpaper_dim(
    conversation_id: int,
    body: WallpaperDimRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    conv = await update_wallpaper_dim(
        db,
        conversation_id=conversation_id,
        user=current,
        dim=body.dim,
    )
    return _conversation_out(db, conv, current)


@router.delete("/{conversation_id}/wallpaper", response_model=ConversationOut)
async def delete_wallpaper(
    conversation_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    conv = await clear_conversation_wallpaper(
        db,
        conversation_id=conversation_id,
        user=current,
    )
    return _conversation_out(db, conv, current)


@router.get("/{conversation_id}/wallpaper")
async def get_wallpaper(
    conversation_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    require_membership(db, conversation_id, current.id)
    conv = _load_conv(db, conversation_id)
    if conv is None or not conv.wallpaper_path:
        raise HTTPException(status_code=404, detail="This chat has no wallpaper.")
    full = resolve_wallpaper_file(conv.wallpaper_path)
    if not full.is_file():
        raise HTTPException(status_code=404, detail="This chat has no wallpaper.")
    return FileResponse(
        path=full,
        media_type=wallpaper_media_type(conv.wallpaper_path),
        content_disposition_type="inline",
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )


@router.patch("/{conversation_id}/disappearing", response_model=ConversationOut)
async def patch_disappearing(
    conversation_id: int,
    body: DisappearingRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    conv = await set_disappearing(
        db,
        conversation_id=conversation_id,
        user=current,
        disappear_after_seconds=body.disappear_after_seconds,
    )
    return _conversation_out(db, conv, current)


@router.patch("/{conversation_id}/anniversary", response_model=ConversationOut)
async def patch_anniversary(
    conversation_id: int,
    body: AnniversaryRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    conv = await set_anniversary(
        db,
        conversation_id=conversation_id,
        user=current,
        anniversary_on=body.anniversary_on,
    )
    return _conversation_out(db, conv, current)


@router.get("/{conversation_id}/nudges", response_model=list[NudgeOut])
def list_nudges(
    conversation_id: int,
    before: str | None = Query(default=None),
    before_id: str | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[NudgeOut]:
    """Paginated nudge history for this chat (newest first)."""
    require_membership(db, conversation_id, current.id)
    before_at = None
    if before is not None:
        try:
            raw = before.replace("Z", "+00:00")
            before_at = datetime.fromisoformat(raw)
            if before_at.tzinfo is None:
                before_at = before_at.replace(tzinfo=timezone.utc)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="Invalid before cursor.") from exc
    rows = list_nudge_events(
        db,
        conversation_id=conversation_id,
        user_id=current.id,
        before_at=before_at,
        before_id=before_id,
        limit=limit,
    )
    out: list[NudgeOut] = []
    for row in rows:
        sender = db.get(User, row.sender_id)
        if sender is None:
            continue
        payload = nudge_out(row, sender)
        out.append(NudgeOut.model_validate(payload))
    return out
