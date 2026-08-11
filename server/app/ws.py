"""WebSocket endpoint for realtime events."""

from __future__ import annotations

import json

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import decode_access_token
from app import db as db_module
from app.models import ConversationMember, MessageReceipt, User, utcnow
from app.realtime import events
from app.realtime.hub import hub
from app.services import get_membership, load_message, notify_shared_contacts

router = APIRouter()


def _user_from_token(db: Session, token: str | None) -> User | None:
    if not token:
        return None
    payload = decode_access_token(token)
    if not payload or "sub" not in payload:
        return None
    try:
        user_id = int(payload["sub"])
    except (TypeError, ValueError):
        return None
    return db.get(User, user_id)


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: str | None = None) -> None:
    # Resolve SessionLocal at call time so tests can swap the engine.
    db = db_module.SessionLocal()
    try:
        user = _user_from_token(db, token)
        if user is None:
            await websocket.close(code=4401)
            return

        await hub.connect(user.id, websocket)
        user.last_seen_at = None
        db.commit()
        await notify_shared_contacts(db, user.id, online=True, last_seen_at=None)

        try:
            while True:
                raw = await websocket.receive_text()
                try:
                    data = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                await _handle_client_event(db, user, data)
        except WebSocketDisconnect:
            pass
        finally:
            await hub.disconnect(user.id, websocket)
            if not hub.is_online(user.id):
                now = utcnow()
                u = db.get(User, user.id)
                if u:
                    u.last_seen_at = now
                    db.commit()
                    await notify_shared_contacts(db, u.id, online=False, last_seen_at=now)
    finally:
        db.close()


async def _handle_typing(db: Session, user: User, data: dict) -> None:
    conversation_id = data.get("conversation_id")
    if not isinstance(conversation_id, int):
        return
    if get_membership(db, conversation_id, user.id) is None:
        return
    members = db.scalars(
        select(ConversationMember.user_id).where(
            ConversationMember.conversation_id == conversation_id
        )
    ).all()
    targets = set(members) - {user.id}
    await hub.broadcast_to_users(
        targets,
        events.event_typing(conversation_id, user.id, bool(data.get("is_typing"))),
    )


async def _handle_ack_delivered(db: Session, user: User, data: dict) -> None:
    message_id = data.get("message_id")
    if not isinstance(message_id, int):
        return
    message = load_message(db, message_id)
    if message is None or message.sender_id == user.id:
        return
    if get_membership(db, message.conversation_id, user.id) is None:
        return
    receipt = db.scalar(
        select(MessageReceipt).where(
            MessageReceipt.message_id == message_id,
            MessageReceipt.user_id == user.id,
        )
    )
    if receipt is None or receipt.delivered_at is not None:
        return
    now = utcnow()
    receipt.delivered_at = now
    db.commit()
    await hub.send_to_user(
        message.sender_id,
        events.event_receipt("delivered", message_id, message.conversation_id, user.id, now),
    )


async def _handle_client_event(db: Session, user: User, data: dict) -> None:
    etype = data.get("type")
    if etype == "typing":
        await _handle_typing(db, user, data)
    elif etype == "ack.delivered":
        await _handle_ack_delivered(db, user, data)
    elif etype == "ping":
        await hub.send_to_user(user.id, {"type": "pong"})
