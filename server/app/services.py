"""Shared conversation / membership helpers."""

from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException, status
from sqlalchemy import and_, delete, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from app.call_log import (
    build_call_log_body,
    call_log_client_id,
    call_log_outcome,
    connected_duration_secs,
    should_include_ended_by,
)
from app import audit, streaks
from app.call_sessions import CallSessionRecord
from app.fcm import send_message_push, send_reaction_push
from app.media_files import delete_message_files
from app.models import (
    Conversation,
    ConversationMember,
    DeviceToken,
    Message,
    MessageHide,
    MessagePin,
    MessageReaction,
    MessageReceipt,
    MessageStar,
    NudgeEvent,
    User,
    utcnow,
)
from app.realtime import events
from app.realtime.events import aggregate_reactions
from app.realtime.hub import hub
from app.rate_limit import nudge_limiter
from app.schemas import ReactionAggOut, SharedItemOut, to_utc_iso
from app.wallpapers import delete_wallpaper_file

# Same shape as the Flutter linkifier — keep the two in sync.
_URL_PATTERN = re.compile(r'https?://[^\s<>"{}|\\^`\[\]]+', re.IGNORECASE)

EDIT_WINDOW = timedelta(minutes=15)
NUDGE_VARIANTS = frozenset({"wave", "poke", "hug", "kiss"})
DISAPPEARING_ALLOWED = frozenset({86400, 604800, 7776000})

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
        .options(
            selectinload(Message.receipts),
            selectinload(Message.reactions),
        )
    )


def load_conversation(db: Session, conversation_id: int) -> Conversation | None:
    return db.get(Conversation, conversation_id)


def purge_expired_messages(db: Session, conversation_id: int) -> None:
    now = utcnow()
    expired = db.scalars(
        select(Message).where(
            Message.conversation_id == conversation_id,
            Message.expires_at.is_not(None),
            Message.expires_at < now,
        )
    ).all()
    if not expired:
        return
    files = [(m.media_path, m.media_thumb_path) for m in expired]
    ids = [m.id for m in expired]
    # A disappearing message is the one deletion nobody asked for, so the log
    # keeps what it said before the row is gone for good.
    for message in expired:
        audit.record(
            db,
            action="message.expired",
            summary=(
                f"message {message.id} reached its disappearing timer and was "
                "removed"
            ),
            # Nobody did this: the timer did. Naming the sender as the actor
            # would read as though they had deleted their own message, which is
            # a different act entirely — they are recorded as whose message it
            # was instead.
            target_user_id=message.sender_id,
            conversation_id=conversation_id,
            message_id=message.id,
            before_text=message.body,
            details={**audit.snapshot(message), "expires_at": message.expires_at},
        )
    db.execute(delete(MessageHide).where(MessageHide.message_id.in_(ids)))
    db.execute(delete(MessageReaction).where(MessageReaction.message_id.in_(ids)))
    db.execute(delete(MessageReceipt).where(MessageReceipt.message_id.in_(ids)))
    db.execute(delete(MessagePin).where(MessagePin.message_id.in_(ids)))
    db.execute(delete(MessageStar).where(MessageStar.message_id.in_(ids)))
    db.execute(delete(Message).where(Message.id.in_(ids)))
    db.commit()
    for media_path, thumb_path in files:
        delete_message_files(media_path, thumb_path)


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


def aggregate_outgoing_receipt_level(
    *,
    recipient_ids: set[int],
    delivered_at: dict[int, object | None],
    read_at: dict[int, object | None],
) -> int:
    """WhatsApp-style ticks for a message the viewer sent.

    Matches the Flutter ``ChatMessage.receiptLevel`` rules for DMs and groups.
    """
    if not recipient_ids:
        return 0
    if all(read_at.get(uid) is not None for uid in recipient_ids):
        return 2
    if all(delivered_at.get(uid) is not None for uid in recipient_ids):
        return 1
    if any(delivered_at.get(uid) is not None for uid in recipient_ids):
        return 1
    return 0


def outgoing_receipt_level_for_message(
    db: Session,
    message: Message,
    *,
    member_ids: set[int],
) -> int | None:
    """Receipt level for [message] from the sender's perspective, or None."""
    recipient_ids = member_ids - {message.sender_id}
    if not recipient_ids:
        return None
    rows = db.scalars(
        select(MessageReceipt).where(
            MessageReceipt.message_id == message.id,
            MessageReceipt.user_id.in_(recipient_ids),
        )
    ).all()
    delivered = {r.user_id: r.delivered_at for r in rows}
    read = {r.user_id: r.read_at for r in rows}
    return aggregate_outgoing_receipt_level(
        recipient_ids=recipient_ids,
        delivered_at=delivered,
        read_at=read,
    )


async def broadcast_user_updated(db: Session, user: User) -> None:
    """Tell shared contacts that profile fields (e.g. avatar) changed."""
    conv_ids = db.scalars(
        select(ConversationMember.conversation_id).where(ConversationMember.user_id == user.id)
    ).all()
    if not conv_ids:
        return
    others = db.scalars(
        select(ConversationMember.user_id)
        .where(
            ConversationMember.conversation_id.in_(conv_ids),
            ConversationMember.user_id != user.id,
        )
        .distinct()
    ).all()
    event = events.event_user_updated(user, is_online=hub.is_online(user.id))
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
    media_thumb_path: str | None = None,
    media_name: str | None = None,
    media_size: int | None = None,
    media_mime: str | None = None,
    media_duration_ms: int | None = None,
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

    conv = load_conversation(db, conversation_id)
    now = utcnow()
    expires_at = None
    if conv and conv.disappear_after_seconds:
        expires_at = now + timedelta(seconds=conv.disappear_after_seconds)

    message = Message(
        conversation_id=conversation_id,
        sender_id=sender.id,
        type=msg_type,
        body=body,
        client_id=client_id,
        media_path=media_path,
        media_thumb_path=media_thumb_path,
        media_name=media_name,
        media_size=media_size,
        media_mime=media_mime,
        media_duration_ms=media_duration_ms,
        reply_to_message_id=reply_to_message_id,
        created_at=now,
        expires_at=expires_at,
    )
    db.add(message)
    db.flush()

    recipients = member_user_ids(db, conversation_id) - {sender.id}
    for uid in recipients:
        db.add(MessageReceipt(message_id=message.id, user_id=uid))
    # Written before anything can remove the message again: the streak counts
    # days people spoke, and a day cannot be un-spoken by a later deletion or a
    # disappearing timer.
    streaks.record_spoken_day(db, conversation_id=conversation_id, user_id=sender.id, when=now)
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

    audit.record(
        db,
        action="message.sent",
        summary=f"{sender.username} sent {audit.describe_message(message)}",
        actor=sender,
        conversation_id=conversation_id,
        message_id=message.id,
        after_text=message.body,
        details=audit.snapshot(message),
    )
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


def _nudge_event_payload(
    *,
    conversation_id: int,
    sender: User,
    nudge_id: str,
    at,
    variant: str,
) -> dict:
    return events.event_chat_nudge(
        conversation_id=conversation_id,
        sender=sender,
        nudge_id=nudge_id,
        at=at,
        variant=variant,
    )


async def _echo_nudge_to_sender(
    db: Session,
    *,
    sender: User,
    row: NudgeEvent,
) -> None:
    """Replay a persisted nudge to the sender for client reconciliation."""
    await hub.send_to_user(
        sender.id,
        _nudge_event_payload(
            conversation_id=row.conversation_id,
            sender=sender,
            nudge_id=row.id,
            at=row.created_at,
            variant=row.variant,
        ),
    )


async def send_chat_nudge(
    db: Session,
    sender: User,
    conversation_id: int,
    *,
    variant: str = "wave",
    nudge_id: str | None = None,
) -> None:
    """Persisted poke — stored in nudge_events, not the message transcript."""
    if get_membership(db, conversation_id, sender.id) is None:
        return
    if variant not in NUDGE_VARIANTS:
        variant = "wave"

    if nudge_id:
        existing = db.get(NudgeEvent, nudge_id)
        if existing is not None:
            if (
                existing.conversation_id == conversation_id
                and existing.sender_id == sender.id
            ):
                await _echo_nudge_to_sender(db, sender=sender, row=existing)
            return

    if not nudge_limiter.check(sender.id, conversation_id):
        return

    nudge_id = nudge_id or uuid.uuid4().hex
    now = utcnow()
    row = NudgeEvent(
        id=nudge_id,
        conversation_id=conversation_id,
        sender_id=sender.id,
        variant=variant,
        created_at=now,
    )
    db.add(row)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        existing = db.get(NudgeEvent, nudge_id)
        if existing is not None and existing.sender_id == sender.id:
            await _echo_nudge_to_sender(db, sender=sender, row=existing)
        return

    audit.record(
        db,
        action="chat.nudge",
        summary=f"{sender.username} sent a {variant} nudge in chat {conversation_id}",
        actor=sender,
        conversation_id=conversation_id,
        details={"variant": variant, "nudge_id": nudge_id},
    )

    event = _nudge_event_payload(
        conversation_id=conversation_id,
        sender=sender,
        nudge_id=nudge_id,
        at=now,
        variant=variant,
    )

    members = member_user_ids(db, conversation_id)
    reached = await hub.broadcast_to_users(members, event)

    offline = members - reached
    if offline:
        _push_nudge_to_offline(db, sender, conversation_id, nudge_id, now, offline, variant)


def list_nudge_events(
    db: Session,
    *,
    conversation_id: int,
    user_id: int,
    before_at: datetime | None = None,
    before_id: str | None = None,
    limit: int = 50,
) -> list[NudgeEvent]:
    """Nudges in this chat, newest first. Member-only."""
    if get_membership(db, conversation_id, user_id) is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That chat is no longer available.",
        )
    q = (
        select(NudgeEvent)
        .where(NudgeEvent.conversation_id == conversation_id)
        .order_by(NudgeEvent.created_at.desc(), NudgeEvent.id.desc())
    )
    if before_at is not None:
        if before_id is not None:
            q = q.where(
                or_(
                    NudgeEvent.created_at < before_at,
                    and_(
                        NudgeEvent.created_at == before_at,
                        NudgeEvent.id < before_id,
                    ),
                )
            )
        else:
            q = q.where(NudgeEvent.created_at < before_at)
    return list(db.scalars(q.limit(limit)).all())


def nudge_out(row: NudgeEvent, sender: User) -> dict:
    return {
        "nudge_id": row.id,
        "conversation_id": row.conversation_id,
        "sender_id": row.sender_id,
        "sender_name": sender.display_name,
        "sender_username": sender.username,
        "variant": row.variant,
        "at": row.created_at,
    }


def _push_nudge_to_offline(
    db: Session,
    sender: User,
    conversation_id: int,
    nudge_id: str,
    at,
    offline: set[int],
    variant: str = "wave",
) -> None:
    tokens = db.scalars(
        select(DeviceToken.token).where(DeviceToken.user_id.in_(offline))
    ).all()
    if not tokens:
        return

    result = send_message_push(
        list(tokens),
        data={
            "type": "chat.nudge",
            "conversation_id": str(conversation_id),
            "sender_id": str(sender.id),
            "sender_name": sender.display_name,
            "sender_username": sender.username,
            "nudge_id": nudge_id,
            "at": to_utc_iso(at),
            "variant": variant,
        },
    )
    if result.invalid_tokens:
        db.execute(delete(DeviceToken).where(DeviceToken.token.in_(result.invalid_tokens)))
        db.commit()


async def edit_message(
    db: Session,
    *,
    message_id: int,
    editor: User,
    new_body: str,
) -> Message:
    """Edit a text message you sent. Soft-deleted messages cannot be edited."""
    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That message is no longer available.",
        )
    require_membership(db, message.conversation_id, editor.id)
    if message.sender_id != editor.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only edit messages you sent.",
        )
    if message.deleted_at is not None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Deleted messages cannot be edited.",
        )
    if message.type != "text":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only text messages can be edited.",
        )
    created = message.created_at
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    if utcnow() - created.astimezone(timezone.utc) > EDIT_WINDOW:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Edit window expired",
        )
    text = new_body.strip()
    if not text:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Type a message before saving.",
        )
    # Read before the overwrite: this is the only place the previous wording of
    # an edited message still exists.
    previous_body = message.body
    message.body = text
    message.edited_at = utcnow()
    db.commit()
    audit.record(
        db,
        action="message.edited",
        summary=f"{editor.username} edited message {message_id}",
        actor=editor,
        conversation_id=message.conversation_id,
        message_id=message_id,
        before_text=previous_body,
        after_text=text,
        details=audit.snapshot(message),
    )
    message = load_message(db, message.id)
    assert message is not None
    members = member_user_ids(db, message.conversation_id)
    await hub.broadcast_to_users(members, events.event_message_updated(message))
    await hub.broadcast_to_users(
        members, events.event_conversation_updated(message.conversation_id)
    )
    return message


async def soft_delete_message(
    db: Session,
    *,
    message_id: int,
    actor: User,
) -> Message:
    """Replace a message with a tombstone visible to everyone in the chat."""
    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That message is no longer available.",
        )
    membership = require_membership(db, message.conversation_id, actor.id)
    is_sender = message.sender_id == actor.id
    is_admin = membership.role == "admin"
    if not is_sender and not is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only delete messages you sent.",
        )
    if message.deleted_at is not None:
        return message

    media_path = message.media_path
    thumb_path = message.media_thumb_path
    # Everything about to be cleared, kept while it still exists: after the
    # commit below the row is a tombstone and the files are gone.
    deleted_body = message.body
    deleted_details = {
        **audit.snapshot(message),
        "media_path": media_path,
        "on_behalf_of_sender": message.sender_id == actor.id,
    }
    deleted_description = audit.describe_message(message)
    db.execute(delete(MessagePin).where(MessagePin.message_id == message.id))
    message.deleted_at = utcnow()
    message.body = None
    message.media_path = None
    message.media_thumb_path = None
    message.media_name = None
    message.media_size = None
    message.media_mime = None
    message.media_duration_ms = None
    message.edited_at = None
    db.commit()
    audit.record(
        db,
        action="message.deleted",
        summary=(
            f"{actor.username} deleted {deleted_description} "
            f"(message {message_id}) for everyone"
        ),
        actor=actor,
        conversation_id=message.conversation_id,
        message_id=message_id,
        target_user_id=deleted_details["sender_id"],
        before_text=deleted_body,
        details=deleted_details,
    )
    delete_message_files(media_path, thumb_path)
    message = load_message(db, message.id)
    assert message is not None
    members = member_user_ids(db, message.conversation_id)
    await hub.broadcast_to_users(members, events.event_message_updated(message))
    await hub.broadcast_to_users(
        members, events.event_conversation_updated(message.conversation_id)
    )
    await hub.broadcast_to_users(
        members, events.event_pins_changed(message.conversation_id)
    )
    return message


async def hide_message_for_user(
    db: Session,
    *,
    message_id: int,
    user: User,
) -> None:
    """Hide a message for one viewer without deleting it for everyone."""
    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That message is no longer available.",
        )
    require_membership(db, message.conversation_id, user.id)
    existing = db.scalar(
        select(MessageHide).where(
            MessageHide.message_id == message_id,
            MessageHide.user_id == user.id,
        )
    )
    if existing is None:
        db.add(MessageHide(message_id=message_id, user_id=user.id))
        # A hidden message cannot be jumped to from Starred, so drop the star.
        db.execute(
            delete(MessageStar).where(
                MessageStar.message_id == message_id,
                MessageStar.user_id == user.id,
            )
        )
        db.commit()
        audit.record(
            db,
            action="message.hidden",
            summary=(
                f"{user.username} hid message {message_id} from their own copy "
                "of the chat"
            ),
            actor=user,
            conversation_id=message.conversation_id,
            message_id=message_id,
            before_text=message.body,
            details=audit.snapshot(message),
        )
        await hub.send_to_user(user.id, events.event_stars_changed())


def list_messages_for_user(
    db: Session,
    *,
    conversation_id: int,
    user_id: int,
    before_id: int | None = None,
    after_id: int | None = None,
    limit: int = 50,
) -> list[Message]:
    require_membership(db, conversation_id, user_id)
    purge_expired_messages(db, conversation_id)

    hidden_ids = set(
        db.scalars(
            select(MessageHide.message_id).where(MessageHide.user_id == user_id)
        ).all()
    )
    now = utcnow()
    base = (
        select(Message)
        .where(
            Message.conversation_id == conversation_id,
            or_(Message.expires_at.is_(None), Message.expires_at >= now),
        )
        .options(
            selectinload(Message.receipts),
            selectinload(Message.reactions),
            selectinload(Message.reply_to),
        )
    )
    if after_id is not None:
        q = base.where(Message.id > after_id).order_by(Message.id.asc()).limit(limit)
        return [m for m in db.scalars(q).all() if m.id not in hidden_ids]

    q = base.order_by(Message.id.desc()).limit(limit)
    if before_id is not None:
        q = q.where(Message.id < before_id)
    rows = [m for m in db.scalars(q).all() if m.id not in hidden_ids]
    rows.reverse()
    return rows


"""Messages of context kept older than a message someone jumped to.

Landing on the very first row reads as the top of the chat; a few rows above it
show that the message sits inside a conversation.
"""
MESSAGE_WINDOW_CONTEXT = 30


def list_message_window(
    db: Session,
    *,
    conversation_id: int,
    user_id: int,
    message_id: int,
    up_to_id: int | None = None,
    limit: int = 400,
) -> list[Message]:
    """History from just before [message_id] up to what the caller already holds.

    Walking back to a starred message one page at a time costs a round trip per
    page, which over Tailscale is seconds of a phone staring at the newest
    message. This returns the whole stretch in one answer.

    Truncation drops the *oldest* rows, never the newest, so the block always
    meets the caller's existing transcript and never leaves a hole in the middle
    of it. A caller whose target fell outside the cap sees that the message is
    missing from the answer and can page the rest of the way.
    """
    require_membership(db, conversation_id, user_id)
    purge_expired_messages(db, conversation_id)

    anchor = db.scalar(
        select(Message.id).where(
            Message.id == message_id,
            Message.conversation_id == conversation_id,
        )
    )
    if anchor is None:
        raise HTTPException(
            status_code=404,
            detail="That message is no longer available.",
        )

    hidden_ids = set(
        db.scalars(
            select(MessageHide.message_id).where(MessageHide.user_id == user_id)
        ).all()
    )
    now = utcnow()
    visible = (
        Message.conversation_id == conversation_id,
        or_(Message.expires_at.is_(None), Message.expires_at >= now),
    )

    context_ids = db.scalars(
        select(Message.id)
        .where(*visible, Message.id <= message_id)
        .order_by(Message.id.desc())
        .limit(MESSAGE_WINDOW_CONTEXT + 1)
    ).all()
    start_id = context_ids[-1] if context_ids else message_id

    q = (
        select(Message)
        .where(*visible, Message.id >= start_id)
        .options(
            selectinload(Message.receipts),
            selectinload(Message.reactions),
            selectinload(Message.reply_to),
        )
        .order_by(Message.id.desc())
        .limit(limit)
    )
    if up_to_id is not None:
        q = q.where(Message.id < up_to_id)
    rows = [m for m in db.scalars(q).all() if m.id not in hidden_ids]
    rows.reverse()
    return rows


async def set_conversation_wallpaper(
    db: Session,
    *,
    conversation_id: int,
    user: User,
    rel_path: str,
) -> Conversation:
    conv = load_conversation(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail="That chat is no longer available.")
    require_membership(db, conversation_id, user.id)
    old_path = conv.wallpaper_path
    now = utcnow()
    conv.wallpaper_path = rel_path
    conv.wallpaper_set_by = user.id
    conv.wallpaper_set_at = now
    db.commit()
    db.refresh(conv)
    audit.record(
        db,
        action="conversation.wallpaper_set",
        summary=f"{user.username} set the wallpaper for chat {conversation_id}",
        actor=user,
        conversation_id=conversation_id,
        before_text=old_path,
        after_text=rel_path,
    )
    delete_wallpaper_file(old_path)
    members = member_user_ids(db, conversation_id)
    await hub.broadcast_to_users(members, events.event_conversation_updated(conversation_id))
    return conv


async def clear_conversation_wallpaper(
    db: Session,
    *,
    conversation_id: int,
    user: User,
) -> Conversation:
    conv = load_conversation(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail="That chat is no longer available.")
    require_membership(db, conversation_id, user.id)
    old_path = conv.wallpaper_path
    conv.wallpaper_path = None
    conv.wallpaper_set_by = None
    conv.wallpaper_set_at = None
    db.commit()
    db.refresh(conv)
    audit.record(
        db,
        action="conversation.wallpaper_cleared",
        summary=f"{user.username} removed the wallpaper from chat {conversation_id}",
        actor=user,
        conversation_id=conversation_id,
        before_text=old_path,
    )
    delete_wallpaper_file(old_path)
    members = member_user_ids(db, conversation_id)
    await hub.broadcast_to_users(members, events.event_conversation_updated(conversation_id))
    return conv


async def update_wallpaper_dim(
    db: Session,
    *,
    conversation_id: int,
    user: User,
    dim: float,
) -> Conversation:
    conv = load_conversation(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail="That chat is no longer available.")
    require_membership(db, conversation_id, user.id)
    previous_dim = conv.wallpaper_dim
    conv.wallpaper_dim = dim
    db.commit()
    db.refresh(conv)
    audit.record(
        db,
        action="conversation.wallpaper_dimmed",
        summary=f"{user.username} changed the wallpaper dimming in chat {conversation_id}",
        actor=user,
        conversation_id=conversation_id,
        before_text=str(previous_dim),
        after_text=str(dim),
    )
    members = member_user_ids(db, conversation_id)
    await hub.broadcast_to_users(members, events.event_conversation_updated(conversation_id))
    return conv


async def set_disappearing(
    db: Session,
    *,
    conversation_id: int,
    user: User,
    disappear_after_seconds: int | None,
) -> Conversation:
    if disappear_after_seconds is not None and disappear_after_seconds not in DISAPPEARING_ALLOWED:
        raise HTTPException(status_code=400, detail="Invalid disappearing timer.")
    conv = load_conversation(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail="That chat is no longer available.")
    require_membership(db, conversation_id, user.id)
    previous = conv.disappear_after_seconds
    conv.disappear_after_seconds = disappear_after_seconds
    db.commit()
    db.refresh(conv)
    audit.record(
        db,
        action="conversation.disappearing_set",
        summary=(
            f"{user.username} set disappearing messages in chat {conversation_id} "
            f"to {disappear_after_seconds or 'off'}"
        ),
        actor=user,
        conversation_id=conversation_id,
        before_text=str(previous) if previous else "off",
        after_text=str(disappear_after_seconds) if disappear_after_seconds else "off",
    )
    members = member_user_ids(db, conversation_id)
    await hub.broadcast_to_users(members, events.event_conversation_updated(conversation_id))
    return conv


async def set_anniversary(
    db: Session,
    *,
    conversation_id: int,
    user: User,
    anniversary_on: str | None,
) -> Conversation:
    conv = load_conversation(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail="That chat is no longer available.")
    require_membership(db, conversation_id, user.id)
    if conv.type != "dm":
        raise HTTPException(
            status_code=400,
            detail="Anniversary dates can only be set for direct chats.",
        )
    previous = conv.anniversary_on
    conv.anniversary_on = anniversary_on
    db.commit()
    db.refresh(conv)
    audit.record(
        db,
        action="conversation.anniversary_set",
        summary=(
            f"{user.username} "
            + (
                f"set the anniversary in chat {conversation_id} to {anniversary_on}"
                if anniversary_on
                else f"cleared the anniversary in chat {conversation_id}"
            )
        ),
        actor=user,
        conversation_id=conversation_id,
        before_text=previous,
        after_text=anniversary_on,
    )
    members = member_user_ids(db, conversation_id)
    await hub.broadcast_to_users(members, events.event_conversation_updated(conversation_id))
    return conv


async def set_user_mood(db: Session, user: User, mood: str | None) -> User:
    previous = user.mood
    user.mood = mood.strip()[:40] if mood and mood.strip() else None
    db.commit()
    db.refresh(user)
    audit.record(
        db,
        action="account.mood_set",
        summary=f"{user.username} changed their mood",
        actor=user,
        before_text=previous,
        after_text=user.mood,
    )
    await broadcast_user_updated(db, user)
    return user


async def set_user_display_name(db: Session, user: User, display_name: str) -> User:
    previous = user.display_name
    user.display_name = display_name.strip()[:80]
    db.commit()
    db.refresh(user)
    audit.record(
        db,
        action="account.display_name_set",
        summary=f"{user.username} changed their display name",
        actor=user,
        before_text=previous,
        after_text=user.display_name,
    )
    await broadcast_user_updated(db, user)
    return user


async def upsert_reaction(
    db: Session,
    *,
    message_id: int,
    user: User,
    emoji: str,
) -> list[ReactionAggOut]:
    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(status_code=404, detail="That message is no longer available.")
    require_membership(db, message.conversation_id, user.id)
    if message.deleted_at is not None:
        raise HTTPException(status_code=400, detail="Deleted messages cannot be reacted to.")

    emoji = emoji.strip()
    if not emoji:
        raise HTTPException(status_code=400, detail="Choose an emoji to react with.")

    reaction = db.scalar(
        select(MessageReaction).where(
            MessageReaction.message_id == message_id,
            MessageReaction.user_id == user.id,
        )
    )
    if reaction is None:
        reaction = MessageReaction(message_id=message_id, user_id=user.id, emoji=emoji)
        db.add(reaction)
        previous_emoji = None
    else:
        previous_emoji = reaction.emoji
        reaction.emoji = emoji
    db.commit()
    audit.record(
        db,
        action="message.reacted",
        summary=f"{user.username} reacted {emoji} to message {message_id}",
        actor=user,
        conversation_id=message.conversation_id,
        message_id=message_id,
        before_text=previous_emoji,
        after_text=emoji,
        details=audit.snapshot(message),
    )
    message = load_message(db, message_id)
    assert message is not None
    reactions = aggregate_reactions(message, user.id)
    members = member_user_ids(db, message.conversation_id)
    await hub.broadcast_to_users(
        members,
        events.event_reaction_updated(message_id, message.conversation_id, reactions),
    )
    offline = members - {user.id} - {uid for uid in members if hub.is_online(uid)}
    if offline:
        _push_reaction_to_offline(db, message, user, offline)
    return reactions


async def remove_reaction(
    db: Session,
    *,
    message_id: int,
    user: User,
) -> list[ReactionAggOut]:
    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(status_code=404, detail="That message is no longer available.")
    require_membership(db, message.conversation_id, user.id)
    previous = db.scalar(
        select(MessageReaction.emoji).where(
            MessageReaction.message_id == message_id,
            MessageReaction.user_id == user.id,
        )
    )
    db.execute(
        delete(MessageReaction).where(
            MessageReaction.message_id == message_id,
            MessageReaction.user_id == user.id,
        )
    )
    db.commit()
    if previous is not None:
        audit.record(
            db,
            action="message.reaction_removed",
            summary=f"{user.username} took back their {previous} on message {message_id}",
            actor=user,
            conversation_id=message.conversation_id,
            message_id=message_id,
            before_text=previous,
            details=audit.snapshot(message),
        )
    message = load_message(db, message_id)
    assert message is not None
    reactions = aggregate_reactions(message, user.id)
    members = member_user_ids(db, message.conversation_id)
    await hub.broadcast_to_users(
        members,
        events.event_reaction_updated(message_id, message.conversation_id, reactions),
    )
    return reactions


def _push_reaction_to_offline(
    db: Session,
    message: Message,
    actor: User,
    offline: set[int],
) -> None:
    tokens = db.scalars(
        select(DeviceToken.token).where(DeviceToken.user_id.in_(offline))
    ).all()
    if not tokens:
        return
    result = send_reaction_push(
        list(tokens),
        conversation_id=message.conversation_id,
        message_id=message.id,
        actor_id=actor.id,
        actor_name=actor.display_name,
    )
    if result.invalid_tokens:
        db.execute(delete(DeviceToken).where(DeviceToken.token.in_(result.invalid_tokens)))
        db.commit()


def find_call_log_message(
    db: Session,
    *,
    conversation_id: int,
    call_id: str,
) -> Message | None:
    """Return the authoritative call-log row for [call_id], if any."""
    client_id = call_log_client_id(call_id)
    return db.scalar(
        select(Message).where(
            Message.conversation_id == conversation_id,
            Message.client_id == client_id,
            Message.type == "call",
            Message.deleted_at.is_(None),
        )
    )


async def finalize_call_log(
    db: Session,
    record: CallSessionRecord,
    *,
    terminal_event: str,
    ended_by_user_id: int | None = None,
    ended_at: datetime | None = None,
) -> Message | None:
    """Create one idempotent call-log message on the first terminal event."""
    existing = find_call_log_message(
        db,
        conversation_id=record.conversation_id,
        call_id=record.call_id,
    )
    if existing is not None:
        return existing

    caller = db.get(User, record.caller_id)
    if caller is None:
        return None

    outcome = call_log_outcome(
        terminal_event,
        was_ringing=record.was_ringing,
        was_active=record.was_active,
    )
    duration = connected_duration_secs(record, ended_at=ended_at)
    ended_by = (
        ended_by_user_id
        if should_include_ended_by(outcome) and ended_by_user_id is not None
        else None
    )
    body = build_call_log_body(
        record,
        outcome=outcome,
        duration_secs=duration,
        ended_by_user_id=ended_by,
    )
    try:
        logged = await create_and_broadcast_message(
            db,
            conversation_id=record.conversation_id,
            sender=caller,
            msg_type="call",
            body=body,
            client_id=call_log_client_id(record.call_id),
            media_mime=record.media,
        )
        callee = db.get(User, record.callee_id)
        callee_name = (
            callee.username if callee is not None else f"account #{record.callee_id}"
        )
        # Whoever hung up is the one who acted. Recording the caller for every
        # ending would put a missed call, and a call the other side cut off, in
        # the caller's name.
        if ended_by == record.caller_id:
            ender: User | None = caller
        elif ended_by is not None:
            ender = db.get(User, ended_by)
        else:
            ender = None
        audit.record(
            db,
            action="call.ended",
            summary=(
                f"the {record.media} call between {caller.username} and "
                f"{callee_name} ended: {outcome}"
            ),
            actor=ender,
            conversation_id=record.conversation_id,
            message_id=logged.id,
            target_user_id=(
                record.caller_id if ended_by == record.callee_id else record.callee_id
            ),
            details={
                "call_id": record.call_id,
                "media": record.media,
                "outcome": outcome,
                "duration_secs": duration,
                "terminal_event": terminal_event,
                "ended_by_user_id": ended_by,
                "caller_user_id": record.caller_id,
                "caller_username": caller.username,
                "callee_user_id": record.callee_id,
                "callee_username": callee_name,
            },
        )
        return logged
    except IntegrityError:
        # A terminal frame from the other socket won the race. Roll this
        # transaction back, then return the one authoritative row it created.
        db.rollback()
        return find_call_log_message(
            db,
            conversation_id=record.conversation_id,
            call_id=record.call_id,
        )


async def create_call_log_message(
    db: Session,
    *,
    conversation_id: int,
    sender_id: int,
    media: str,
    outcome: str,
    duration_secs: int | None,
    call_id: str | None = None,
) -> Message:
    """Legacy client call-log POST — prefer [finalize_call_log] from signaling."""
    if call_id:
        existing = find_call_log_message(
            db, conversation_id=conversation_id, call_id=call_id
        )
        if existing is not None:
            return existing

    sender = db.get(User, sender_id)
    if sender is None:
        raise HTTPException(status_code=404, detail="That user isn't on this server anymore.")
    payload: dict = {
        "media": media,
        "outcome": outcome,
        "duration_secs": duration_secs,
    }
    if call_id:
        payload["call_id"] = call_id
    return await create_and_broadcast_message(
        db,
        conversation_id=conversation_id,
        sender=sender,
        msg_type="call",
        body=json.dumps(payload, separators=(",", ":")),
        client_id=call_log_client_id(call_id) if call_id else None,
        media_mime=media,
    )


def search_messages(
    db: Session,
    *,
    conversation_id: int | None,
    user_id: int,
    query: str,
    limit: int = 50,
    sender_id: int | None = None,
    media_type: str | None = None,
    before: datetime | None = None,
    after: datetime | None = None,
) -> list[Message]:
    """Find messages matching text and optional filters (sender, type, dates)."""
    needle = query.strip()
    memberships = db.scalars(
        select(ConversationMember.conversation_id).where(
            ConversationMember.user_id == user_id
        )
    ).all()
    allowed = set(memberships)
    if conversation_id is not None:
        if conversation_id not in allowed:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You're not part of this chat anymore.",
            )
        allowed = {conversation_id}
    if not allowed:
        return []

    # Search must show the same chat the reader can scroll: a message they hid
    # for themselves, or one whose disappearing timer has run out, is gone.
    hidden_ids = set(
        db.scalars(
            select(MessageHide.message_id).where(MessageHide.user_id == user_id)
        ).all()
    )
    conditions = [
        Message.conversation_id.in_(allowed),
        Message.deleted_at.is_(None),
        or_(Message.expires_at.is_(None), Message.expires_at >= utcnow()),
    ]
    if hidden_ids:
        conditions.append(Message.id.notin_(hidden_ids))
    kind = (media_type or "").strip().lower() or None
    if kind == "text" or kind is None:
        if needle:
            conditions.append(Message.type == "text")
            conditions.append(Message.body.ilike(f"%{needle}%"))
        elif kind == "text":
            conditions.append(Message.type == "text")
        elif kind is None and not needle:
            # Empty search with no filter: return nothing rather than dump history.
            return []
    elif kind == "link":
        conditions.append(Message.type == "text")
        conditions.append(Message.body.ilike("%http%"))
        if needle:
            conditions.append(Message.body.ilike(f"%{needle}%"))
    elif kind in ("image", "video", "file", "voice", "doodle"):
        conditions.append(Message.type == kind)
        if needle:
            conditions.append(
                or_(
                    Message.media_name.ilike(f"%{needle}%"),
                    Message.body.ilike(f"%{needle}%"),
                )
            )
    else:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="media_type must be text, image, video, file, voice, doodle, or link.",
        )

    if sender_id is not None:
        conditions.append(Message.sender_id == sender_id)
    if before is not None:
        conditions.append(Message.created_at < before)
    if after is not None:
        conditions.append(Message.created_at > after)

    rows = list(
        db.scalars(
            select(Message)
            .where(*conditions)
            .options(selectinload(Message.receipts))
            .order_by(Message.id.desc())
            .limit(limit)
        ).all()
    )
    return rows


def list_shared_items(
    db: Session,
    *,
    conversation_id: int,
    user_id: int,
    before_id: int | None = None,
    limit: int = 100,
) -> list[SharedItemOut]:
    """Build the Media / Docs / Links index for one conversation.

    Pulls only attachment and link-bearing rows (not the full transcript), so a
    long chat stays cheap to open. Text messages may expand into several link
    rows — one per URL.
    """
    require_membership(db, conversation_id, user_id)
    hidden_ids = set(
        db.scalars(
            select(MessageHide.message_id).where(MessageHide.user_id == user_id)
        ).all()
    )

    # Over-fetch so multi-URL texts still fill ``limit`` after expansion.
    fetch = min(max(limit * 3, limit), 300)
    conditions = [
        Message.conversation_id == conversation_id,
        Message.deleted_at.is_(None),
            or_(
                Message.type.in_(("image", "video", "file", "doodle")),
                and_(Message.type == "text", Message.body.ilike("%http%")),
            ),
        ]
    if before_id is not None:
        conditions.append(Message.id < before_id)

    rows = list(
        db.scalars(
            select(Message).where(*conditions).order_by(Message.id.desc()).limit(fetch)
        ).all()
    )

    items: list[SharedItemOut] = []
    for message in rows:
        if message.id in hidden_ids:
            continue
        # Videos join photos in the Media tab, the way a gallery mixes both.
        if message.type in ("image", "video", "doodle"):
            items.append(
                SharedItemOut(
                    message_id=message.id,
                    kind="media",
                    type=message.type,
                    media_name=message.media_name,
                    media_size=message.media_size,
                    media_mime=message.media_mime,
                    media_duration_ms=message.media_duration_ms,
                    body=message.body,
                    created_at=message.created_at,
                    sender_id=message.sender_id,
                )
            )
        elif message.type == "file":
            items.append(
                SharedItemOut(
                    message_id=message.id,
                    kind="docs",
                    type=message.type,
                    media_name=message.media_name,
                    media_size=message.media_size,
                    media_mime=message.media_mime,
                    body=message.body,
                    created_at=message.created_at,
                    sender_id=message.sender_id,
                )
            )
        elif message.type == "text" and message.body:
            for match in _URL_PATTERN.finditer(message.body):
                url = match.group(0).rstrip(".,);]!?")
                items.append(
                    SharedItemOut(
                        message_id=message.id,
                        kind="links",
                        type=message.type,
                        body=message.body,
                        url=url,
                        created_at=message.created_at,
                        sender_id=message.sender_id,
                    )
                )
        if len(items) >= limit:
            break

    return items[:limit]


def list_pinned_messages(
    db: Session,
    *,
    conversation_id: int,
    user_id: int,
) -> list[Message]:
    """Pinned messages for a chat, newest pin first. Deleted rows are skipped."""
    require_membership(db, conversation_id, user_id)
    pins = list(
        db.scalars(
            select(MessagePin)
            .where(MessagePin.conversation_id == conversation_id)
            .order_by(MessagePin.pinned_at.desc())
        ).all()
    )
    messages: list[Message] = []
    for pin in pins:
        message = load_message(db, pin.message_id)
        if message is None or message.deleted_at is not None:
            continue
        messages.append(message)
    return messages


async def pin_message(
    db: Session,
    *,
    message_id: int,
    actor: User,
) -> Message:
    """Pin a message. DMs: any member. Groups: sender or admin."""
    message = load_message(db, message_id)
    if message is None or message.deleted_at is not None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That message is no longer available.",
        )
    membership = require_membership(db, message.conversation_id, actor.id)
    conv = load_conversation(db, message.conversation_id)
    is_sender = message.sender_id == actor.id
    is_admin = membership.role == "admin"
    if conv and conv.type == "group" and not is_sender and not is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the sender or a group admin can pin that message.",
        )

    existing = db.scalar(
        select(MessagePin).where(
            MessagePin.conversation_id == message.conversation_id,
            MessagePin.message_id == message.id,
        )
    )
    if existing is None:
        db.add(
            MessagePin(
                conversation_id=message.conversation_id,
                message_id=message.id,
                pinned_by=actor.id,
            )
        )
        db.commit()
        audit.record(
            db,
            action="message.pinned",
            summary=f"{actor.username} pinned message {message_id}",
            actor=actor,
            conversation_id=message.conversation_id,
            message_id=message_id,
            details=audit.snapshot(message),
        )

    members = member_user_ids(db, message.conversation_id)
    await hub.broadcast_to_users(
        members, events.event_pins_changed(message.conversation_id)
    )
    return message


async def unpin_message(
    db: Session,
    *,
    message_id: int,
    actor: User,
) -> None:
    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That message is no longer available.",
        )
    membership = require_membership(db, message.conversation_id, actor.id)
    conv = load_conversation(db, message.conversation_id)
    is_sender = message.sender_id == actor.id
    is_admin = membership.role == "admin"
    if conv and conv.type == "group" and not is_sender and not is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the sender or a group admin can unpin that message.",
        )

    db.execute(
        delete(MessagePin).where(
            MessagePin.conversation_id == message.conversation_id,
            MessagePin.message_id == message.id,
        )
    )
    db.commit()
    audit.record(
        db,
        action="message.unpinned",
        summary=f"{actor.username} unpinned message {message_id}",
        actor=actor,
        conversation_id=message.conversation_id,
        message_id=message_id,
        details=audit.snapshot(message),
    )
    members = member_user_ids(db, message.conversation_id)
    await hub.broadcast_to_users(
        members, events.event_pins_changed(message.conversation_id)
    )


def list_starred_messages(
    db: Session,
    *,
    user_id: int,
    before_star_id: int | None = None,
    limit: int = 50,
) -> list[tuple[Message, int]]:
    """Messages this user starred, newest star first.

    Returns (message, star_id) pairs so the client can paginate with star ids.
    Skips purged rows, hidden rows, and conversations the user left.
    """
    hidden_ids = set(
        db.scalars(
            select(MessageHide.message_id).where(MessageHide.user_id == user_id)
        ).all()
    )
    membership_conv_ids = set(
        db.scalars(
            select(ConversationMember.conversation_id).where(
                ConversationMember.user_id == user_id
            )
        ).all()
    )
    q = (
        select(MessageStar)
        .where(MessageStar.user_id == user_id)
        .order_by(MessageStar.starred_at.desc(), MessageStar.id.desc())
    )
    if before_star_id is not None:
        q = q.where(MessageStar.id < before_star_id)
    stars = list(db.scalars(q.limit(max(limit * 3, limit))).all())
    out: list[tuple[Message, int]] = []
    for star in stars:
        if star.message_id in hidden_ids:
            continue
        message = load_message(db, star.message_id)
        if message is None:
            continue
        if message.conversation_id not in membership_conv_ids:
            continue
        out.append((message, star.id))
        if len(out) >= limit:
            break
    return out


async def star_message(
    db: Session,
    *,
    message_id: int,
    user: User,
) -> Message:
    """Bookmark a message for this user only. Idempotent."""
    message = load_message(db, message_id)
    if message is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That message is no longer available.",
        )
    require_membership(db, message.conversation_id, user.id)
    existing = db.scalar(
        select(MessageStar).where(
            MessageStar.message_id == message_id,
            MessageStar.user_id == user.id,
        )
    )
    if existing is None:
        db.add(MessageStar(message_id=message_id, user_id=user.id))
        db.commit()
        audit.record(
            db,
            action="message.starred",
            summary=f"{user.username} starred message {message_id}",
            actor=user,
            conversation_id=message.conversation_id,
            message_id=message_id,
            details=audit.snapshot(message),
        )
        await hub.send_to_user(user.id, events.event_stars_changed())
    return message


async def unstar_message(
    db: Session,
    *,
    message_id: int,
    user: User,
) -> None:
    message = load_message(db, message_id)
    if message is not None:
        require_membership(db, message.conversation_id, user.id)
    db.execute(
        delete(MessageStar).where(
            MessageStar.message_id == message_id,
            MessageStar.user_id == user.id,
        )
    )
    db.commit()
    audit.record(
        db,
        action="message.unstarred",
        summary=f"{user.username} unstarred message {message_id}",
        actor=user,
        conversation_id=message.conversation_id if message is not None else None,
        message_id=message_id,
        details=None if message is None else audit.snapshot(message),
    )
    await hub.send_to_user(user.id, events.event_stars_changed())


def starred_message_ids_for_user(db: Session, *, user_id: int) -> set[int]:
    return set(
        db.scalars(
            select(MessageStar.message_id).where(MessageStar.user_id == user_id)
        ).all()
    )
