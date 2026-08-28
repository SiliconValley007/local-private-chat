"""Attachment timers: files leave the server unless someone kept them.

Conversation disappearing timers still remove a whole message. This module is
only about the file: a photo can vanish from disk while the caption and the
bubble stay, the way a deleted-for-everyone attachment does.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, func, or_, select
from sqlalchemy.orm import Session, selectinload

from app import audit
from app.media_files import delete_message_files
from app.models import (
    Conversation,
    MediaRetain,
    Message,
    ServerSetting,
    User,
    utcnow,
)
from app.realtime import events
from app.realtime.hub import hub

MEDIA_TYPES = frozenset({"image", "video", "file", "voice", "doodle"})
MEDIA_TTL_KEY = "media_ttl_days"
DEFAULT_TTL_DAYS = 30
MIN_TTL_DAYS = 1
MAX_TTL_DAYS = 365
EXPIRE_BATCH = 40


def _as_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


class MediaPolicy:
    def __init__(self, *, default_days: int, min_days: int, max_days: int) -> None:
        self.default_days = default_days
        self.min_days = min_days
        self.max_days = max_days

    def clamp(self, days: int | None) -> int:
        if days is None:
            return self.default_days
        return max(self.min_days, min(self.max_days, int(days)))


def _parse_days(raw: str | None, fallback: int) -> int:
    try:
        value = int((raw or "").strip())
    except ValueError:
        return fallback
    return max(MIN_TTL_DAYS, min(MAX_TTL_DAYS, value))


def load_policy(db: Session) -> MediaPolicy:
    row = db.get(ServerSetting, MEDIA_TTL_KEY)
    return MediaPolicy(
        default_days=_parse_days(row.value if row else None, DEFAULT_TTL_DAYS),
        min_days=MIN_TTL_DAYS,
        max_days=MAX_TTL_DAYS,
    )


def set_server_ttl_days(db: Session, *, days: int, actor: User) -> MediaPolicy:
    policy = load_policy(db)
    wanted = policy.clamp(days)
    row = db.get(ServerSetting, MEDIA_TTL_KEY)
    if row is None:
        row = ServerSetting(key=MEDIA_TTL_KEY)
        db.add(row)
    row.value = str(wanted)
    row.updated_at = utcnow()
    row.updated_by = actor.id
    db.commit()
    return load_policy(db)


def ttl_days_for_conversation(db: Session, conv: Conversation | None, sender: User) -> int:
    """Timer the chat has agreed, else this sender's default, else the server."""
    policy = load_policy(db)
    if conv is not None and conv.media_ttl_days is not None:
        return policy.clamp(conv.media_ttl_days)
    return policy.clamp(sender.media_ttl_days)


def ttl_days_for_sender(db: Session, sender: User) -> int:
    policy = load_policy(db)
    return policy.clamp(sender.media_ttl_days)


def apply_media_timer(db: Session, message: Message, sender: User) -> None:
    """Stamp a new attachment with when it should leave the server."""
    if message.type not in MEDIA_TYPES or not message.media_path:
        return
    conv = db.get(Conversation, message.conversation_id)
    days = ttl_days_for_conversation(db, conv, sender)
    now = utcnow()
    message.media_ttl_days = days
    message.media_expires_at = now + timedelta(days=days)
    message.media_gone_at = None
    message.media_gone_reason = None


def retainers_for(db: Session, message_id: int) -> list[User]:
    rows = db.scalars(
        select(MediaRetain)
        .where(MediaRetain.message_id == message_id)
        .options(selectinload(MediaRetain.user))
        .order_by(MediaRetain.created_at.asc())
    ).all()
    return [row.user for row in rows if row.user is not None]


def has_retains(db: Session, message_id: int) -> bool:
    count = db.scalar(
        select(func.count()).select_from(MediaRetain).where(MediaRetain.message_id == message_id)
    )
    return bool(count)


def media_is_available(message: Message) -> bool:
    return bool(message.media_path) and message.media_gone_at is None


def should_index_shared_media(message: Message) -> bool:
    """Gallery rows: still on disk, or expired-but-retained (path still set)."""
    if message.type not in MEDIA_TYPES:
        return True
    if message.deleted_at is not None:
        return False
    return message.media_path is not None and message.media_gone_at is None


async def unlink_media_if_unclaimed(
    db: Session,
    message: Message,
    *,
    reason: str,
    actor: User | None = None,
) -> bool:
    """Remove the file when nobody has asked to keep it.

    Returns True when the file left disk. Caption and type stay on the row.
    """
    if message.media_path is None or message.media_gone_at is not None:
        return False
    if has_retains(db, message.id):
        return False
    path, thumb = message.media_path, message.media_thumb_path
    message.media_path = None
    message.media_thumb_path = None
    message.media_gone_at = utcnow()
    message.media_gone_reason = reason
    db.commit()
    delete_message_files(path, thumb)
    audit.record(
        db,
        action="message.media_expired" if reason == "expired" else "media.deleted",
        summary=(
            f"attachment on message {message.id} left the server after "
            f"{message.media_ttl_days or DEFAULT_TTL_DAYS} days"
            if reason == "expired"
            else f"attachment on message {message.id} was removed from the server"
        ),
        actor=actor,
        target_user_id=message.sender_id,
        conversation_id=message.conversation_id,
        message_id=message.id,
        details={
            **audit.snapshot(message),
            "media_ttl_days": message.media_ttl_days,
            "reason": reason,
        },
    )
    from app.services import member_user_ids

    await hub.broadcast_to_users(
        member_user_ids(db, message.conversation_id),
        events.event_message_updated(message),
    )
    return True


async def expire_due_media(db: Session, *, limit: int = EXPIRE_BATCH) -> int:
    """Unlink attachments whose timer has passed and nobody kept.

    Saved Messages are left alone: that vault is until the owner deletes it.
    """
    now = utcnow()
    due = db.scalars(
        select(Message)
        .where(
            Message.type.in_(MEDIA_TYPES),
            Message.media_path.is_not(None),
            Message.media_gone_at.is_(None),
            Message.media_expires_at.is_not(None),
            Message.media_expires_at < now,
            Message.deleted_at.is_(None),
        )
        .limit(limit)
    ).all()
    removed = 0
    for message in due:
        conv = message.conversation_id
        from app.models import Conversation

        conversation = db.get(Conversation, conv)
        if conversation is not None and conversation.type == "notes":
            continue
        if await unlink_media_if_unclaimed(db, message, reason="expired"):
            removed += 1
    return removed


async def retain_media(db: Session, message: Message, user: User) -> list[User]:
    if message.type not in MEDIA_TYPES:
        raise ValueError("That message has no attachment to keep.")
    if message.deleted_at is not None:
        raise ValueError("That message is no longer available.")
    if message.media_gone_at is not None and message.media_path is None:
        raise ValueError("That attachment has already left the server.")
    existing = db.scalar(
        select(MediaRetain).where(
            MediaRetain.message_id == message.id,
            MediaRetain.user_id == user.id,
        )
    )
    if existing is None:
        db.add(MediaRetain(message_id=message.id, user_id=user.id))
        db.commit()
        audit.record(
            db,
            action="media.retained",
            summary=f"{user.username} kept message {message.id} on the server",
            actor=user,
            conversation_id=message.conversation_id,
            message_id=message.id,
        )
        from app.services import member_user_ids

        await hub.broadcast_to_users(
            member_user_ids(db, message.conversation_id),
            events.event_message_updated(message),
        )
    return retainers_for(db, message.id)


async def drop_retain(db: Session, message: Message, user: User) -> list[User]:
    row = db.scalar(
        select(MediaRetain).where(
            MediaRetain.message_id == message.id,
            MediaRetain.user_id == user.id,
        )
    )
    if row is not None:
        db.execute(delete(MediaRetain).where(MediaRetain.id == row.id))
        db.commit()
        audit.record(
            db,
            action="media.retain_dropped",
            summary=f"{user.username} stopped keeping message {message.id} on the server",
            actor=user,
            conversation_id=message.conversation_id,
            message_id=message.id,
        )
    remaining = retainers_for(db, message.id)
    now = utcnow()
    expires = _as_utc(message.media_expires_at)
    due = (
        expires is not None
        and expires < now
        and message.media_path is not None
    )
    if due and not remaining:
        await unlink_media_if_unclaimed(db, message, reason="expired")
    elif row is not None:
        from app.services import member_user_ids

        await hub.broadcast_to_users(
            member_user_ids(db, message.conversation_id),
            events.event_message_updated(message),
        )
    return retainers_for(db, message.id)


def drop_retains_for_message(db: Session, message_id: int) -> None:
    db.execute(delete(MediaRetain).where(MediaRetain.message_id == message_id))
