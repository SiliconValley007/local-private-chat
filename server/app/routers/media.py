"""Media upload and download."""

from __future__ import annotations

import re
import shutil
import uuid
from pathlib import Path

import aiofiles
from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import (
    MAX_MEDIA_BYTES,
    MEDIA_DISK_FLOOR_BYTES,
    MEDIA_ROOT,
    UPLOAD_CHUNK_BYTES,
)
from app.db import get_db
from app.deps import get_current_user
from app.models import Conversation, ConversationMember, Message, User
from app.realtime.events import message_out
from app.schemas import (
    DeleteOwnedMediaOut,
    DeleteOwnedMediaRequest,
    MessageOut,
    OwnedMediaOut,
)
from app.doodle_media import MAX_DOODLE_BYTES, validate_doodle_upload
from app.upload_limits import UploadAllowance, too_large_detail, upload_allowance
from app.services import (
    create_and_broadcast_message,
    load_message,
    require_membership,
    resolve_reply_target,
    soft_delete_message,
)

router = APIRouter(tags=["media"])

SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._\-]+")
ALLOWED_TYPES = {"image", "file", "voice", "video", "doodle"}
ATTACHMENT_GONE = "This attachment is no longer available on the server."
MAX_THUMBNAIL_BYTES = 512 * 1024


def media_allowance() -> UploadAllowance:
    """The largest attachment acceptable right now, cap and free space together."""
    return upload_allowance(
        max_bytes=MAX_MEDIA_BYTES,
        free_bytes=shutil.disk_usage(MEDIA_ROOT).free,
        floor_bytes=MEDIA_DISK_FLOOR_BYTES,
    )


def secure_filename(name: str) -> str:
    name = Path(name).name
    name = SAFE_NAME_RE.sub("_", name).strip("._")
    return name[:180] or "file"


@router.post("/api/conversations/{conversation_id}/media", response_model=MessageOut)
async def upload_media(
    conversation_id: int,
    file: UploadFile = File(...),
    thumbnail: UploadFile | None = File(default=None),
    # Form field is named "type" on the wire; alias keeps the client API stable.
    msg_type: str = Form(alias="type"),
    caption: str | None = Form(default=None),
    client_id: str | None = Form(default=None),
    reply_to_message_id: int | None = Form(default=None),
    duration_ms: int | None = Form(default=None),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    require_membership(db, conversation_id, current.id)
    msg_type = msg_type.strip().lower()
    if msg_type not in ALLOWED_TYPES:
        raise HTTPException(
            status_code=400,
            detail="That kind of attachment isn't supported.",
        )
    # Checked before the upload is written so a rejected reply leaves no file.
    resolve_reply_target(db, conversation_id, reply_to_message_id)

    original = secure_filename(file.filename or "file")
    dest_dir = MEDIA_ROOT / str(conversation_id)
    dest_dir.mkdir(parents=True, exist_ok=True)
    stored_name = f"{uuid.uuid4().hex}_{original}"
    dest_path = dest_dir / stored_name
    thumb_path: Path | None = None
    thumb_rel_path: str | None = None

    size = 0
    header = b""
    is_doodle = msg_type == "doodle"
    allowance = media_allowance()
    if allowance.out_of_space:
        raise HTTPException(
            status_code=507,
            detail=too_large_detail(allowance),
        )
    max_bytes = MAX_DOODLE_BYTES if is_doodle else allowance.limit_bytes
    over_limit = False
    async with aiofiles.open(dest_path, "wb") as out:
        while True:
            chunk = await file.read(UPLOAD_CHUNK_BYTES)
            if not chunk:
                break
            size += len(chunk)
            if size > max_bytes:
                # Deleting is left until the handle is closed below: Windows
                # refuses to unlink an open file, which turned an honest "too
                # large" into a 500 with no explanation for the sender.
                over_limit = True
                break
            if len(header) < 24:
                header += chunk[: 24 - len(header)]
            await out.write(chunk)

    if over_limit:
        dest_path.unlink(missing_ok=True)
        raise HTTPException(
            status_code=413,
            detail=too_large_detail(allowance, is_doodle=is_doodle),
        )

    if msg_type == "doodle":
        validate_doodle_upload(
            header=header,
            size=size,
            content_type=file.content_type,
            filename=original,
        )
        mime = "image/png"
        if not original.lower().endswith(".png"):
            stored_name = f"{uuid.uuid4().hex}_drawing.png"
            new_path = dest_dir / stored_name
            dest_path.rename(new_path)
            dest_path = new_path
            original = "drawing.png"
    else:
        mime = file.content_type or "application/octet-stream"

    rel_path = f"{conversation_id}/{dest_path.name}"
    body = (caption or "").strip() or None

    if thumbnail is not None and msg_type in {"image", "video"}:
        thumb_bytes = await thumbnail.read(MAX_THUMBNAIL_BYTES + 1)
        if len(thumb_bytes) > MAX_THUMBNAIL_BYTES:
            dest_path.unlink(missing_ok=True)
            raise HTTPException(status_code=413, detail="The video preview is too large.")
        if not thumb_bytes.startswith(b"\xff\xd8\xff"):
            dest_path.unlink(missing_ok=True)
            raise HTTPException(
                status_code=400,
                detail="The video preview must be a JPEG image.",
            )
        thumb_name = f"{uuid.uuid4().hex}_thumb.jpg"
        thumb_path = dest_dir / thumb_name
        async with aiofiles.open(thumb_path, "wb") as out:
            await out.write(thumb_bytes)
        thumb_rel_path = f"{conversation_id}/{thumb_name}"

    try:
        message = await create_and_broadcast_message(
            db,
            conversation_id=conversation_id,
            sender=current,
            msg_type=msg_type,
            body=body,
            client_id=client_id,
            media_path=rel_path,
            media_thumb_path=thumb_rel_path,
            media_name=original,
            media_size=size,
            media_mime=mime,
            media_duration_ms=duration_ms if msg_type == "video" else None,
            reply_to_message_id=reply_to_message_id,
        )
    except Exception:
        dest_path.unlink(missing_ok=True)
        if thumb_path is not None:
            thumb_path.unlink(missing_ok=True)
        raise
    return message_out(message, current.id)


def _conversation_title(db: Session, conversation: Conversation, user_id: int) -> str:
    if conversation.type == "group":
        return conversation.title or "Group"
    peer_name = db.scalar(
        select(User.display_name)
        .join(ConversationMember, ConversationMember.user_id == User.id)
        .where(
            ConversationMember.conversation_id == conversation.id,
            User.id != user_id,
        )
    )
    return peer_name or "Direct chat"


@router.get("/api/media/mine", response_model=list[OwnedMediaOut])
def list_my_media(
    limit: int = Query(default=500, ge=1, le=500),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[OwnedMediaOut]:
    """List only physical attachments uploaded by the signed-in user."""

    rows = db.scalars(
        select(Message)
        .where(
            Message.sender_id == current.id,
            Message.media_path.is_not(None),
            Message.deleted_at.is_(None),
        )
        .order_by(Message.id.desc())
        .limit(limit)
    ).all()
    conversations: dict[int, Conversation] = {}
    result: list[OwnedMediaOut] = []
    for message in rows:
        conversation = conversations.get(message.conversation_id)
        if conversation is None:
            conversation = db.get(Conversation, message.conversation_id)
            if conversation is None:
                continue
            conversations[conversation.id] = conversation
        result.append(
            OwnedMediaOut(
                message_id=message.id,
                conversation_id=message.conversation_id,
                conversation_title=_conversation_title(
                    db, conversation, current.id
                ),
                type=message.type,
                media_name=message.media_name,
                media_size=message.media_size or 0,
                media_mime=message.media_mime,
                created_at=message.created_at,
            )
        )
    return result


@router.delete("/api/media/mine", response_model=DeleteOwnedMediaOut)
async def delete_my_media(
    body: DeleteOwnedMediaRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> DeleteOwnedMediaOut:
    """Tombstone selected uploads, never another user's attachments."""

    ids = set(body.message_ids)
    rows = db.scalars(select(Message).where(Message.id.in_(ids))).all()
    if len(rows) != len(ids) or any(
        row.sender_id != current.id or not row.media_path for row in rows
    ):
        raise HTTPException(
            status_code=403,
            detail="You can only clear media that you uploaded.",
        )
    reclaimed = sum(row.media_size or 0 for row in rows)
    for row in rows:
        await soft_delete_message(db, message_id=row.id, actor=current)
    return DeleteOwnedMediaOut(deleted=len(rows), reclaimed_bytes=reclaimed)


@router.get("/api/media/{message_id}")
async def download_media(
    message_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    message = load_message(db, message_id)
    if message is None or not message.media_path:
        raise HTTPException(status_code=404, detail=ATTACHMENT_GONE)
    require_membership(db, message.conversation_id, current.id)

    full = (MEDIA_ROOT / message.media_path).resolve()
    if not str(full).startswith(str(MEDIA_ROOT.resolve())):
        raise HTTPException(status_code=400, detail=ATTACHMENT_GONE)
    if not full.is_file():
        raise HTTPException(status_code=404, detail=ATTACHMENT_GONE)

    # Video is served inline like a photo so the player can stream it and seek
    # through it with range requests, instead of the phone having to download
    # the whole file before anything can be watched.
    inline = message.type in ("image", "voice", "video", "doodle")
    return FileResponse(
        path=full,
        media_type=message.media_mime or "application/octet-stream",
        filename=message.media_name or full.name,
        content_disposition_type="inline" if inline else "attachment",
        # Attachments never change once uploaded, so a phone that already has one
        # can be told to keep it rather than fetching it twice.
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )


@router.get("/api/media/{message_id}/thumbnail")
async def download_media_thumbnail(
    message_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    """Serve a small upload-time preview, with legacy-image fallback."""

    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(status_code=404, detail=ATTACHMENT_GONE)
    require_membership(db, message.conversation_id, current.id)

    # Older image messages predate upload-time previews. Keep them visible by
    # serving the original through this endpoint; new images use the small JPEG.
    relative = message.media_thumb_path
    media_type = "image/jpeg"
    if not relative and message.type in {"image", "doodle"}:
        relative = message.media_path
        media_type = message.media_mime or "application/octet-stream"
    if not relative:
        raise HTTPException(status_code=404, detail=ATTACHMENT_GONE)

    full = (MEDIA_ROOT / relative).resolve()
    if not str(full).startswith(str(MEDIA_ROOT.resolve())):
        raise HTTPException(status_code=400, detail=ATTACHMENT_GONE)
    if not full.is_file():
        raise HTTPException(status_code=404, detail=ATTACHMENT_GONE)
    return FileResponse(
        path=full,
        media_type=media_type,
        content_disposition_type="inline",
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )
