"""Messages and receipts."""

from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.db import get_db
from app.deps import get_current_user
from app.models import Message, MessageReceipt, User, utcnow
from app.realtime import events
from app.realtime.events import message_out
from app.realtime.hub import hub
from app.schemas import (
    CallLogRequest,
    EditMessageRequest,
    MessageOut,
    ReactionRequest,
    SendMessageRequest,
    SharedItemOut,
)
from app.services import (
    create_and_broadcast_message,
    create_call_log_message,
    edit_message,
    hide_message_for_user,
    list_messages_for_user,
    list_pinned_messages,
    list_shared_items,
    list_starred_messages,
    load_message,
    pin_message,
    remove_reaction,
    require_membership,
    search_messages,
    soft_delete_message,
    star_message,
    unpin_message,
    unstar_message,
    upsert_reaction,
)

router = APIRouter(tags=["messages"])


@router.get("/api/conversations/{conversation_id}/messages", response_model=list[MessageOut])
def list_messages(
    conversation_id: int,
    before_id: int | None = Query(default=None),
    after_id: int | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[MessageOut]:
    if before_id is not None and after_id is not None:
        raise HTTPException(
            status_code=400,
            detail="Use before_id or after_id, not both.",
        )
    rows = list_messages_for_user(
        db,
        conversation_id=conversation_id,
        user_id=current.id,
        before_id=before_id,
        after_id=after_id,
        limit=limit,
    )
    return [message_out(m, current.id) for m in rows]


@router.get("/api/messages/search", response_model=list[MessageOut])
def search_all_messages(
    q: str = Query(default="", max_length=200),
    conversation_id: int | None = Query(default=None),
    sender_id: int | None = Query(default=None),
    media_type: str | None = Query(default=None),
    before: datetime | None = Query(default=None),
    after: datetime | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[MessageOut]:
    if not q.strip() and not media_type:
        raise HTTPException(
            status_code=400,
            detail="Type a search, or pick a media filter.",
        )
    rows = search_messages(
        db,
        conversation_id=conversation_id,
        user_id=current.id,
        query=q,
        limit=limit,
        sender_id=sender_id,
        media_type=media_type,
        before=before,
        after=after,
    )
    return [message_out(m, current.id) for m in rows]


@router.get(
    "/api/conversations/{conversation_id}/shared",
    response_model=list[SharedItemOut],
)
def shared_in_conversation(
    conversation_id: int,
    before_id: int | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=200),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[SharedItemOut]:
    """Media, documents, and links shared in this chat (WhatsApp-style index)."""
    return list_shared_items(
        db,
        conversation_id=conversation_id,
        user_id=current.id,
        before_id=before_id,
        limit=limit,
    )


@router.post("/api/conversations/{conversation_id}/messages", response_model=MessageOut)
async def send_message(
    conversation_id: int,
    body: SendMessageRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    require_membership(db, conversation_id, current.id)
    if body.type == "call":
        raise HTTPException(
            status_code=400,
            detail="Use the call log endpoint for call messages.",
        )
    if body.type != "text":
        raise HTTPException(
            status_code=400,
            detail="Photos, voice notes and files have to be sent as attachments.",
        )
    text = body.body.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Type a message before sending.")
    message = await create_and_broadcast_message(
        db,
        conversation_id=conversation_id,
        sender=current,
        msg_type="text",
        body=text,
        client_id=body.client_id,
        reply_to_message_id=body.reply_to_message_id,
    )
    return message_out(message, current.id)


@router.post("/api/conversations/{conversation_id}/call-log", response_model=MessageOut)
async def post_call_log(
    conversation_id: int,
    body: CallLogRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    require_membership(db, conversation_id, current.id)
    message = await create_call_log_message(
        db,
        conversation_id=conversation_id,
        sender_id=current.id,
        media=body.media,
        outcome=body.outcome,
        duration_secs=body.duration_secs,
    )
    return message_out(message, current.id)


@router.patch("/api/messages/{message_id}", response_model=MessageOut)
async def patch_message(
    message_id: int,
    body: EditMessageRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    message = await edit_message(
        db, message_id=message_id, editor=current, new_body=body.body
    )
    return message_out(message, current.id)


@router.delete("/api/messages/{message_id}", response_model=MessageOut)
async def delete_message(
    message_id: int,
    scope: str = Query(default="everyone"),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    if scope == "me":
        message = load_message(db, message_id)
        if message is None:
            raise HTTPException(status_code=404, detail="That message is no longer available.")
        await hide_message_for_user(db, message_id=message_id, user=current)
        message = load_message(db, message_id)
        assert message is not None
        return message_out(message, current.id)
    if scope != "everyone":
        raise HTTPException(status_code=400, detail="scope must be everyone or me.")
    message = await soft_delete_message(db, message_id=message_id, actor=current)
    return message_out(message, current.id)


@router.get(
    "/api/conversations/{conversation_id}/pins",
    response_model=list[MessageOut],
)
def list_pins(
    conversation_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[MessageOut]:
    rows = list_pinned_messages(
        db, conversation_id=conversation_id, user_id=current.id
    )
    return [message_out(m, current.id) for m in rows]


@router.put("/api/messages/{message_id}/pin", response_model=MessageOut)
async def put_pin(
    message_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    message = await pin_message(db, message_id=message_id, actor=current)
    return message_out(message, current.id)


@router.delete("/api/messages/{message_id}/pin", status_code=204)
async def delete_pin(
    message_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> Response:
    await unpin_message(db, message_id=message_id, actor=current)
    return Response(status_code=204)


@router.get("/api/messages/starred", response_model=list[MessageOut])
def list_starred(
    before_star_id: int | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[MessageOut]:
    rows = list_starred_messages(
        db,
        user_id=current.id,
        before_star_id=before_star_id,
        limit=limit,
    )
    return [
        message_out(message, current.id, star_id=star_id)
        for message, star_id in rows
    ]


@router.put("/api/messages/{message_id}/star", response_model=MessageOut)
async def put_star(
    message_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    message = await star_message(db, message_id=message_id, user=current)
    return message_out(message, current.id)


@router.delete("/api/messages/{message_id}/star", status_code=204)
async def delete_star(
    message_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> Response:
    await unstar_message(db, message_id=message_id, user=current)
    return Response(status_code=204)


@router.put("/api/messages/{message_id}/reactions", response_model=MessageOut)
async def put_reaction(
    message_id: int,
    body: ReactionRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    await upsert_reaction(db, message_id=message_id, user=current, emoji=body.emoji)
    message = load_message(db, message_id)
    assert message is not None
    return message_out(message, current.id)


@router.delete("/api/messages/{message_id}/reactions", response_model=MessageOut)
async def delete_reaction(
    message_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    await remove_reaction(db, message_id=message_id, user=current)
    message = load_message(db, message_id)
    assert message is not None
    return message_out(message, current.id)


@router.post("/api/conversations/{conversation_id}/read")
async def mark_read(
    conversation_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> dict:
    require_membership(db, conversation_id, current.id)
    now = utcnow()
    receipts = db.scalars(
        select(MessageReceipt)
        .join(Message, Message.id == MessageReceipt.message_id)
        .where(
            Message.conversation_id == conversation_id,
            MessageReceipt.user_id == current.id,
            MessageReceipt.read_at.is_(None),
        )
        .options(selectinload(MessageReceipt.message))
    ).all()

    for r in receipts:
        if r.delivered_at is None:
            r.delivered_at = now
        r.read_at = now
        await hub.send_to_user(
            r.message.sender_id,
            events.event_receipt("read", r.message_id, conversation_id, current.id, now),
        )
    db.commit()
    return {"ok": True, "marked": len(receipts)}


@router.post("/api/messages/{message_id}/delivered")
async def mark_delivered(
    message_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> dict:
    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(status_code=404, detail="That message is no longer available.")
    require_membership(db, message.conversation_id, current.id)
    if message.sender_id == current.id:
        return {"ok": True}

    receipt = db.scalar(
        select(MessageReceipt).where(
            MessageReceipt.message_id == message_id,
            MessageReceipt.user_id == current.id,
        )
    )
    if receipt is None:
        raise HTTPException(
            status_code=404,
            detail="That message is no longer available.",
        )
    if receipt.delivered_at is None:
        now = utcnow()
        receipt.delivered_at = now
        db.commit()
        await hub.send_to_user(
            message.sender_id,
            events.event_receipt("delivered", message_id, message.conversation_id, current.id, now),
        )
    return {"ok": True}
