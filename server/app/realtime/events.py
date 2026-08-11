"""Helpers to serialize messages / events for REST and WebSocket."""

from __future__ import annotations

from app.models import Message, User
from app.schemas import MessageOut, QuotedMessage, ReceiptOut, UserOut, to_utc_iso


def user_out(user: User, is_online: bool = False) -> UserOut:
    return UserOut(
        id=user.id,
        username=user.username,
        display_name=user.display_name,
        last_seen_at=user.last_seen_at,
        is_online=is_online,
    )


def quoted_message(message: Message | None) -> QuotedMessage | None:
    if message is None:
        return None
    return QuotedMessage(
        id=message.id,
        sender_id=message.sender_id,
        type=message.type,
        body=message.body,
        media_name=message.media_name,
    )


def message_out(message: Message) -> MessageOut:
    receipts = [
        ReceiptOut(user_id=r.user_id, delivered_at=r.delivered_at, read_at=r.read_at)
        for r in (message.receipts or [])
    ]
    return MessageOut(
        id=message.id,
        conversation_id=message.conversation_id,
        sender_id=message.sender_id,
        type=message.type,
        body=message.body,
        media_name=message.media_name,
        media_size=message.media_size,
        media_mime=message.media_mime,
        client_id=message.client_id,
        created_at=message.created_at,
        reply_to=quoted_message(message.reply_to),
        receipts=receipts,
    )


def event_message_new(message: Message) -> dict:
    return {"type": "message.new", "message": message_out(message).model_dump(mode="json")}


def event_receipt(kind: str, message_id: int, conversation_id: int, user_id: int, at) -> dict:
    return {
        "type": f"receipt.{kind}",
        "message_id": message_id,
        "conversation_id": conversation_id,
        "user_id": user_id,
        "at": to_utc_iso(at) if at else None,
    }


def event_typing(conversation_id: int, user_id: int, is_typing: bool) -> dict:
    return {
        "type": "typing",
        "conversation_id": conversation_id,
        "user_id": user_id,
        "is_typing": is_typing,
    }


def event_presence(user_id: int, online: bool, last_seen_at) -> dict:
    return {
        "type": "presence",
        "user_id": user_id,
        "online": online,
        "last_seen_at": to_utc_iso(last_seen_at) if last_seen_at else None,
    }


def event_conversation_updated(conversation_id: int) -> dict:
    return {"type": "conversation.updated", "conversation_id": conversation_id}
