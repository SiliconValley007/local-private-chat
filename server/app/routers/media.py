"""Media upload and download."""

from __future__ import annotations

import re
import uuid
from pathlib import Path

import aiofiles
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from app.config import MEDIA_ROOT
from app.db import get_db
from app.deps import get_current_user
from app.models import User
from app.realtime.events import message_out
from app.schemas import MessageOut
from app.services import (
    create_and_broadcast_message,
    load_message,
    require_membership,
    resolve_reply_target,
)

router = APIRouter(tags=["media"])

SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._\-]+")
ALLOWED_TYPES = {"image", "file", "voice"}
ATTACHMENT_GONE = "This attachment is no longer available on the server."


def secure_filename(name: str) -> str:
    name = Path(name).name
    name = SAFE_NAME_RE.sub("_", name).strip("._")
    return name[:180] or "file"


@router.post("/api/conversations/{conversation_id}/media", response_model=MessageOut)
async def upload_media(
    conversation_id: int,
    file: UploadFile = File(...),
    # Form field is named "type" on the wire; alias keeps the client API stable.
    msg_type: str = Form(alias="type"),
    caption: str | None = Form(default=None),
    client_id: str | None = Form(default=None),
    reply_to_message_id: int | None = Form(default=None),
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

    size = 0
    async with aiofiles.open(dest_path, "wb") as out:
        while True:
            chunk = await file.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            await out.write(chunk)

    rel_path = f"{conversation_id}/{stored_name}"
    mime = file.content_type or "application/octet-stream"
    body = (caption or "").strip() or None

    message = await create_and_broadcast_message(
        db,
        conversation_id=conversation_id,
        sender=current,
        msg_type=msg_type,
        body=body,
        client_id=client_id,
        media_path=rel_path,
        media_name=original,
        media_size=size,
        media_mime=mime,
        reply_to_message_id=reply_to_message_id,
    )
    return message_out(message)


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

    inline = message.type in ("image", "voice")
    return FileResponse(
        path=full,
        media_type=message.media_mime or "application/octet-stream",
        filename=message.media_name or full.name,
        content_disposition_type="inline" if inline else "attachment",
    )
