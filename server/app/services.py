"""Shared conversation / membership helpers."""

from __future__ import annotations

from fastapi import HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.orm import Session, selectinload

from app.fcm import send_message_push
from app.models import (
    ConversationMember,
    DeviceToken,
    Message,
    MessageReceipt,
    User,
    utcnow,
)
from app.realtime import events
from app.realtime.hub import hub


def get_membership(db: Session, conversation_id: int, user_id: int) -> ConversationMember | None:
    return db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user_id,
        )
    )


def require_membership(db: Session, conversation_id: int, user_id: int) -> ConversationMember:
    m = get_membership(db, conversation_id, user_id)
    if m is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You're not part of this chat anymore.",
        )
    return m


def member_user_ids(db: Session, conversation_id: int) -> set[int]:
    rows = db.scalars(
        select(ConversationMember.user_id).where(
            ConversationMember.conversation_id == conversation_id
        )
    ).all()
    return set(rows)


def resolve_reply_target(
    db: Session,
    conversation_id: int,
    reply_to_message_id: int | None,
) -> int | None:
    """Check a quoted message exists in this chat before linking to it.

    Guards against quoting a message from another conversation, which would leak
    its text into a chat the sender may not even be a member of.
    """
    if reply_to_message_id is None:
        return None
    target = db.scalar(select(Message).where(Message.id == reply_to_message_id))
    if target is None or target.conversation_id != conversation_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The message you replied to is no longer in this chat.",
        )
    return target.id


def load_message(db: Session, message_id: int) -> Message | None:
    return db.scalar(
        select(Message)
        .where(Message.id == message_id)
        .options(selectinload(Message.receipts))
    )


async def notify_shared_contacts(db: Session, user_id: int, online: bool, last_seen_at) -> None:
    """Notify users who share any conversation with this user."""
    conv_ids = db.scalars(
        select(ConversationMember.conversation_id).where(ConversationMember.user_id == user_id)
    ).all()
    if not conv_ids:
        return
    others = db.scalars(
        select(ConversationMember.user_id)
        .where(
            ConversationMember.conversation_id.in_(conv_ids),
            ConversationMember.user_id != user_id,
        )
        .distinct()
    ).all()
    event = events.event_presence(user_id, online, last_seen_at)
    await hub.broadcast_to_users(set(others), event)


async def create_and_broadcast_message(
    db: Session,
    *,
    conversation_id: int,
    sender: User,
    msg_type: str,
    body: str | None,
    client_id: str | None = None,
    media_path: str | None = None,
    media_name: str | None = None,
    media_size: int | None = None,
    media_mime: str | None = None,
    reply_to_message_id: int | None = None,
) -> Message:
    reply_to_message_id = resolve_reply_target(db, conversation_id, reply_to_message_id)
    if client_id:
        existing = db.scalar(
            select(Message).where(
                Message.conversation_id == conversation_id,
                Message.sender_id == sender.id,
                Message.client_id == client_id,
            )
        )
        if existing:
            return load_message(db, existing.id) or existing

    message = Message(
        conversation_id=conversation_id,
        sender_id=sender.id,
        type=msg_type,
        body=body,
        client_id=client_id,
        media_path=media_path,
        media_name=media_name,
        media_size=media_size,
        media_mime=media_mime,
        reply_to_message_id=reply_to_message_id,
    )
    db.add(message)
    db.flush()

    recipients = member_user_ids(db, conversation_id) - {sender.id}
    for uid in recipients:
        db.add(MessageReceipt(message_id=message.id, user_id=uid))
    db.commit()

    message = load_message(db, message.id)
    assert message is not None

    event = events.event_message_new(message)
    # Fanout to everyone in conversation (including sender for multi-device / echo)
    all_members = recipients | {sender.id}
    reached = await hub.broadcast_to_users(all_members, event)

    # Auto-mark delivered for online recipients who got the event
    now = utcnow()
    for uid in recipients:
        if uid in reached:
            receipt = db.scalar(
                select(MessageReceipt).where(
                    MessageReceipt.message_id == message.id,
                    MessageReceipt.user_id == uid,
                )
            )
            if receipt and receipt.delivered_at is None:
                receipt.delivered_at = now
                await hub.send_to_user(
                    sender.id,
                    events.event_receipt("delivered", message.id, conversation_id, uid, now),
                )
    db.commit()
    message = load_message(db, message.id)
    assert message is not None

    await hub.broadcast_to_users(
        all_members,
        events.event_conversation_updated(conversation_id),
    )

    # Push notification for recipients with no live WebSocket (app closed,
    # backgrounded, or off the Tailscale network).
    offline = recipients - reached
    if offline:
        _push_to_offline_members(db, message, sender, offline)

    return message


def _push_to_offline_members(
    db: Session,
    message: Message,
    sender: User,
    offline: set[int],
) -> None:
    """Send a content-free push and forget any token FCM says is dead."""
    tokens = db.scalars(
        select(DeviceToken.token).where(DeviceToken.user_id.in_(offline))
    ).all()
    if not tokens:
        return

    result = send_message_push(
        list(tokens),
        data={
            "type": "message.new",
            "conversation_id": str(message.conversation_id),
            "message_id": str(message.id),
            "sender_id": str(sender.id),
            "sender_name": sender.display_name,
            "sender_username": sender.username,
            # Intentionally NO message body — privacy (1a)
        },
    )
    if result.invalid_tokens:
        db.execute(delete(DeviceToken).where(DeviceToken.token.in_(result.invalid_tokens)))
        db.commit()
