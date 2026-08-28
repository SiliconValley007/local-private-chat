"""Media upload and download."""

from __future__ import annotations

import asyncio
import re
import shutil
import uuid
from pathlib import Path

import aiofiles
from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Query,
    Request,
    UploadFile,
)
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import upload_sessions
from app.config import (
    MAX_MEDIA_BYTES,
    MEDIA_DISK_FLOOR_BYTES,
    MEDIA_ROOT,
    RESUMABLE_CHUNK_BYTES,
    UPLOAD_CHUNK_BYTES,
    UPLOAD_SESSION_TTL_SECONDS,
)
from app.db import get_db
from app.deps import get_current_user
from app.models import Conversation, ConversationMember, Message, User
from app.realtime.events import message_out
from app.schemas import (
    CancelUploadOut,
    DeleteOwnedMediaOut,
    DeleteOwnedMediaRequest,
    MessageOut,
    OwnedMediaOut,
    StartUploadRequest,
    UploadSessionOut,
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
UPLOAD_GONE = "That upload is no longer available. Send the file again."
MAX_THUMBNAIL_BYTES = 512 * 1024

#: Guards the tail of each partial file; see :func:`_chunk_lock`.
_CHUNK_LOCKS: dict[str, asyncio.Lock] = {}


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

    return await _publish_stored_upload(
        db,
        conversation_id=conversation_id,
        current=current,
        msg_type=msg_type,
        dest_path=dest_path,
        original=original,
        size=size,
        header=header,
        content_type=file.content_type,
        thumbnail_bytes=(
            await thumbnail.read(MAX_THUMBNAIL_BYTES + 1)
            if thumbnail is not None
            else None
        ),
        caption=caption,
        client_id=client_id,
        reply_to_message_id=reply_to_message_id,
        duration_ms=duration_ms,
    )


async def _publish_stored_upload(
    db: Session,
    *,
    conversation_id: int,
    current: User,
    msg_type: str,
    dest_path: Path,
    original: str,
    size: int,
    header: bytes,
    content_type: str | None,
    thumbnail_bytes: bytes | None,
    caption: str | None,
    client_id: str | None,
    reply_to_message_id: int | None,
    duration_ms: int | None,
) -> MessageOut:
    """Turn a file already written to media storage into a chat message.

    Shared by the single-request upload and the resumable one so that both ways of
    getting the bytes here agree exactly on validation, previews, naming, and what
    is cleaned up when the message cannot be created.
    """

    dest_dir = dest_path.parent
    thumb_path: Path | None = None
    thumb_rel_path: str | None = None

    if msg_type == "doodle":
        validate_doodle_upload(
            header=header,
            size=size,
            content_type=content_type,
            filename=original,
        )
        mime = "image/png"
        if not original.lower().endswith(".png"):
            new_path = dest_dir / f"{uuid.uuid4().hex}_drawing.png"
            dest_path.rename(new_path)
            dest_path = new_path
            original = "drawing.png"
    else:
        mime = content_type or "application/octet-stream"

    rel_path = f"{conversation_id}/{dest_path.name}"
    body = (caption or "").strip() or None

    if thumbnail_bytes is not None and msg_type in {"image", "video"}:
        if len(thumbnail_bytes) > MAX_THUMBNAIL_BYTES:
            dest_path.unlink(missing_ok=True)
            raise HTTPException(status_code=413, detail="The video preview is too large.")
        if not thumbnail_bytes.startswith(b"\xff\xd8\xff"):
            dest_path.unlink(missing_ok=True)
            raise HTTPException(
                status_code=400,
                detail="The video preview must be a JPEG image.",
            )
        thumb_name = f"{uuid.uuid4().hex}_thumb.jpg"
        thumb_path = dest_dir / thumb_name
        async with aiofiles.open(thumb_path, "wb") as out:
            await out.write(thumbnail_bytes)
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


def _own_session(upload_id: str, user_id: int) -> upload_sessions.UploadSession:
    """The caller's own session, or a plain 404.

    Someone else's session is reported exactly like one that never existed: the
    reply must not tell a signed-in user which upload ids other people hold.
    """

    try:
        session = upload_sessions.read_session(MEDIA_ROOT, upload_id)
    except upload_sessions.UnknownSession:
        raise HTTPException(status_code=404, detail=UPLOAD_GONE) from None
    if session.user_id != user_id:
        raise HTTPException(status_code=404, detail=UPLOAD_GONE)
    return session


def _session_out(session: upload_sessions.UploadSession) -> UploadSessionOut:
    return UploadSessionOut(
        upload_id=session.upload_id,
        offset=session.received,
        size=session.declared_size,
        chunk_bytes=RESUMABLE_CHUNK_BYTES,
        complete=session.complete,
    )


def _chunk_lock(upload_id: str) -> asyncio.Lock:
    """One lock per upload, so two pieces cannot append at once.

    The offset check alone is not enough: two requests carrying the same offset
    would both pass it and both append, leaving a file that is the right length
    and the wrong content.
    """

    lock = _CHUNK_LOCKS.get(upload_id)
    if lock is None:
        lock = _CHUNK_LOCKS[upload_id] = asyncio.Lock()
    return lock


def _forget_session(upload_id: str) -> None:
    upload_sessions.discard_session(MEDIA_ROOT, upload_id)
    _CHUNK_LOCKS.pop(upload_id, None)


@router.post(
    "/api/conversations/{conversation_id}/uploads",
    response_model=UploadSessionOut,
)
def start_resumable_upload(
    conversation_id: int,
    body: StartUploadRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> UploadSessionOut:
    """Open a resumable upload for a large attachment.

    The size is declared up front so that a file which could never be accepted is
    refused before a single byte crosses a metered link.
    """

    require_membership(db, conversation_id, current.id)
    msg_type = body.type.strip().lower()
    if msg_type not in ALLOWED_TYPES:
        raise HTTPException(
            status_code=400,
            detail="That kind of attachment isn't supported.",
        )
    allowance = media_allowance()
    if allowance.out_of_space:
        raise HTTPException(status_code=507, detail=too_large_detail(allowance))
    is_doodle = msg_type == "doodle"
    max_bytes = MAX_DOODLE_BYTES if is_doodle else allowance.limit_bytes
    if body.size > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=too_large_detail(allowance, is_doodle=is_doodle),
        )
    upload_sessions.purge_stale(MEDIA_ROOT, ttl_seconds=UPLOAD_SESSION_TTL_SECONDS)
    session = upload_sessions.create_session(
        MEDIA_ROOT,
        conversation_id=conversation_id,
        user_id=current.id,
        msg_type=msg_type,
        filename=secure_filename(body.filename),
        mime=body.mime,
        declared_size=body.size,
        duration_ms=body.duration_ms,
    )
    return _session_out(session)


@router.get("/api/uploads/{upload_id}", response_model=UploadSessionOut)
def resumable_upload_status(
    upload_id: str,
    current: User = Depends(get_current_user),
) -> UploadSessionOut:
    """How much of an interrupted upload survived, so sending can continue."""
    return _session_out(_own_session(upload_id, current.id))


@router.patch("/api/uploads/{upload_id}", response_model=UploadSessionOut)
async def append_resumable_chunk(
    upload_id: str,
    request: Request,
    offset: int = Query(ge=0),
    current: User = Depends(get_current_user),
) -> UploadSessionOut:
    """Append the next piece of an upload at exactly ``offset``.

    A mismatched offset answers 409 with the offset we do hold, which is all a
    sender needs to pick up again after any interruption.
    """

    session = _own_session(upload_id, current.id)
    async with _chunk_lock(upload_id):
        # Re-read inside the lock: a piece may have landed while waiting.
        session = _own_session(upload_id, current.id)
        if offset != session.received:
            raise HTTPException(
                status_code=409,
                detail=f"This upload is at {session.received} bytes.",
                headers={"X-Upload-Offset": str(session.received)},
            )
        path = upload_sessions.data_path(MEDIA_ROOT, upload_id)
        written = 0
        over_limit = False
        async with aiofiles.open(path, "ab") as out:
            async for chunk in request.stream():
                if not chunk:
                    continue
                if session.received + written + len(chunk) > session.declared_size:
                    over_limit = True
                    break
                await out.write(chunk)
                written += len(chunk)
        if over_limit:
            # The sender contradicted the size it opened the upload with; the
            # file can no longer be trusted, so the whole session goes.
            _forget_session(upload_id)
            raise HTTPException(
                status_code=413,
                detail="This upload sent more than it said it would.",
            )
        return _session_out(upload_sessions.read_session(MEDIA_ROOT, upload_id))


@router.post("/api/uploads/{upload_id}/complete", response_model=MessageOut)
async def complete_resumable_upload(
    upload_id: str,
    thumbnail: UploadFile | None = File(default=None),
    caption: str | None = Form(default=None),
    client_id: str | None = Form(default=None),
    reply_to_message_id: int | None = Form(default=None),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    """Publish a finished upload as a message, once, with its preview."""

    session = _own_session(upload_id, current.id)
    require_membership(db, session.conversation_id, current.id)
    if not session.complete:
        raise HTTPException(
            status_code=409,
            detail=f"This upload is at {session.received} bytes.",
            headers={"X-Upload-Offset": str(session.received)},
        )
    resolve_reply_target(db, session.conversation_id, reply_to_message_id)

    dest_dir = MEDIA_ROOT / str(session.conversation_id)
    dest_dir.mkdir(parents=True, exist_ok=True)
    original = secure_filename(session.filename)
    dest_path = dest_dir / f"{uuid.uuid4().hex}_{original}"
    source = upload_sessions.data_path(MEDIA_ROOT, upload_id)
    header = b""
    async with aiofiles.open(source, "rb") as handle:
        header = await handle.read(24)
    source.replace(dest_path)
    _forget_session(upload_id)

    thumb_bytes = (
        await thumbnail.read(MAX_THUMBNAIL_BYTES + 1) if thumbnail is not None else None
    )
    return await _publish_stored_upload(
        db,
        conversation_id=session.conversation_id,
        current=current,
        msg_type=session.msg_type,
        dest_path=dest_path,
        original=original,
        size=session.declared_size,
        header=header,
        content_type=session.mime,
        thumbnail_bytes=thumb_bytes,
        caption=caption,
        client_id=client_id,
        reply_to_message_id=reply_to_message_id,
        duration_ms=session.duration_ms,
    )


@router.delete("/api/uploads/{upload_id}", response_model=CancelUploadOut)
def cancel_resumable_upload(
    upload_id: str,
    current: User = Depends(get_current_user),
) -> CancelUploadOut:
    """Give up on an upload and reclaim the space it was using."""
    session = _own_session(upload_id, current.id)
    _forget_session(session.upload_id)
    return CancelUploadOut(cancelled=True, reclaimed_bytes=session.received)


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
