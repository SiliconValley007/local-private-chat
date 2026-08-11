"""Messages and receipts."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.db import get_db
from app.deps import get_current_user
from app.models import Message, MessageReceipt, User, utcnow
from app.realtime import events
from app.realtime.hub import hub
from app.schemas import MessageOut, SendMessageRequest
from app.services import (
    create_and_broadcast_message,
    load_message,
    require_membership,
)
from app.realtime.events import message_out

router = APIRouter(tags=["messages"])


@router.get("/api/conversations/{conversation_id}/messages", response_model=list[MessageOut])
def list_messages(
    conversation_id: int,
    before_id: int | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[MessageOut]:
    require_membership(db, conversation_id, current.id)
    q = (
        select(Message)
        .where(Message.conversation_id == conversation_id)
        .options(selectinload(Message.receipts))
        .order_by(Message.id.desc())
        .limit(limit)
    )
    if before_id is not None:
        q = q.where(Message.id < before_id)
    rows = list(db.scalars(q).all())
    rows.reverse()  # oldest -> newest within page
    return [message_out(m) for m in rows]


@router.post("/api/conversations/{conversation_id}/messages", response_model=MessageOut)
async def send_message(
    conversation_id: int,
    body: SendMessageRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> MessageOut:
    require_membership(db, conversation_id, current.id)
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
    return message_out(message)


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

    sender_ids: set[int] = set()
    for r in receipts:
        if r.delivered_at is None:
            r.delivered_at = now
        r.read_at = now
        sender_ids.add(r.message.sender_id)
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
