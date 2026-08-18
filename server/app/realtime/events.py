"""Helpers to serialize messages / events for REST and WebSocket."""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.avatars import avatar_version_for, has_avatar
from app.image_shape import media_pixel_size
from app.models import Conversation, ConversationMember, Message, User
from app.schemas import (
    ConversationOut,
    MemberOut,
    MessageOut,
    QuotedMessage,
    ReactionAggOut,
    ReceiptOut,
    UserOut,
    to_utc_iso,
)
from app.wallpapers import has_wallpaper, wallpaper_version_for

DELETED_BODY = "This message was deleted"


def _message_day(created_at: datetime) -> datetime.date:
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    return created_at.astimezone(timezone.utc).date()


def compute_dm_streak(db, conversation: Conversation) -> int:
    """Consecutive UTC calendar days where every member sent at least one message."""
    if conversation.type != "dm":
        return 0
    member_ids = {m.user_id for m in conversation.members}
    if len(member_ids) < 2:
        return 0

    rows = db.execute(
        select(Message.sender_id, Message.created_at).where(
            Message.conversation_id == conversation.id,
            Message.deleted_at.is_(None),
        )
    ).all()
    by_day: dict[datetime.date, set[int]] = defaultdict(set)
    for sender_id, created_at in rows:
        by_day[_message_day(created_at)].add(sender_id)

    streak = 0
    day = datetime.now(timezone.utc).date()
    while member_ids <= by_day.get(day, set()):
        streak += 1
        day -= timedelta(days=1)
    return streak


def aggregate_reactions(
    message: Message,
    viewer_id: int | None = None,
) -> list[ReactionAggOut]:
    by_emoji: dict[str, list[int]] = defaultdict(list)
    for reaction in message.reactions or []:
        by_emoji[reaction.emoji].append(reaction.user_id)
    result: list[ReactionAggOut] = []
    for emoji, user_ids in sorted(by_emoji.items()):
        result.append(
            ReactionAggOut(
                emoji=emoji,
                count=len(user_ids),
                reacted_by_me=viewer_id in user_ids if viewer_id is not None else False,
                user_ids=sorted(user_ids),
            )
        )
    return result


def user_out(user: User, is_online: bool = False) -> UserOut:
    return UserOut(
        id=user.id,
        username=user.username,
        display_name=user.display_name,
        last_seen_at=user.last_seen_at,
        is_online=is_online,
        has_avatar=has_avatar(user),
        avatar_version=avatar_version_for(user),
        mood=user.mood,
    )


def member_out(member: ConversationMember, is_online: bool = False) -> MemberOut:
    user = member.user
    return MemberOut(
        user_id=member.user_id,
        username=user.username,
        display_name=user.display_name,
        role=member.role,
        is_online=is_online,
        has_avatar=has_avatar(user),
        avatar_version=avatar_version_for(user),
    )


def quoted_message(message: Message | None) -> QuotedMessage | None:
    if message is None:
        return None
    deleted = message.deleted_at is not None
    return QuotedMessage(
        id=message.id,
        sender_id=message.sender_id,
        type=message.type if not deleted else "text",
        body=DELETED_BODY if deleted else message.body,
        media_name=None if deleted else message.media_name,
        deleted=deleted,
    )


def preview_pixel_size(message: Message) -> tuple[int, int] | None:
    """Shape of what a chat row will draw for [message], when it draws a picture.

    Videos and photos are previewed through their thumbnail, which keeps the
    original's proportions; a drawing is shown as sent.
    """

    if message.type not in ("image", "video", "doodle"):
        return None
    return media_pixel_size(message.media_thumb_path) or media_pixel_size(
        message.media_path
    )


def message_out(
    message: Message,
    viewer_id: int | None = None,
    *,
    star_id: int | None = None,
) -> MessageOut:
    receipts = [
        ReceiptOut(user_id=r.user_id, delivered_at=r.delivered_at, read_at=r.read_at)
        for r in (message.receipts or [])
    ]
    deleted = message.deleted_at is not None
    reactions = aggregate_reactions(message, viewer_id)
    shape = None if deleted else preview_pixel_size(message)
    return MessageOut(
        id=message.id,
        conversation_id=message.conversation_id,
        sender_id=message.sender_id,
        type=message.type if not deleted else "text",
        body=DELETED_BODY if deleted else message.body,
        media_name=None if deleted else message.media_name,
        media_size=None if deleted else message.media_size,
        media_mime=None if deleted else message.media_mime,
        media_duration_ms=None if deleted else message.media_duration_ms,
        media_width=None if shape is None else shape[0],
        media_height=None if shape is None else shape[1],
        client_id=message.client_id,
        created_at=message.created_at,
        edited_at=None if deleted else message.edited_at,
        deleted_at=message.deleted_at,
        expires_at=message.expires_at,
        reply_to=quoted_message(message.reply_to),
        receipts=receipts,
        reactions=reactions,
        star_id=star_id,
    )


def conversation_out(
    db,
    conv: Conversation,
    viewer: User,
    *,
    is_online_fn,
) -> ConversationOut:
    from sqlalchemy import func, select

    from app.models import Message, MessageReceipt

    peer_user = None
    if conv.type == "dm":
        for m in conv.members:
            if m.user_id != viewer.id:
                peer_user = m.user
                break
    peer = user_out(peer_user, is_online=is_online_fn(peer_user.id)) if peer_user else None

    last = db.scalar(
        select(Message)
        .where(Message.conversation_id == conv.id)
        .order_by(Message.id.desc())
        .limit(1)
    )
    last_preview = None
    updated_at = conv.created_at
    if last:
        from app.schemas import MessagePreview
        from app.services import outgoing_receipt_level_for_message

        receipt_level = None
        if last.sender_id == viewer.id:
            member_ids = {m.user_id for m in conv.members}
            receipt_level = outgoing_receipt_level_for_message(
                db, last, member_ids=member_ids
            )

        last_preview = MessagePreview(
            id=last.id,
            type="text" if last.deleted_at is not None else last.type,
            body=DELETED_BODY if last.deleted_at is not None else last.body,
            sender_id=last.sender_id,
            created_at=last.created_at,
            media_name=None if last.deleted_at is not None else last.media_name,
            receipt_level=receipt_level,
        )
        updated_at = last.created_at

    unread = db.scalar(
        select(func.count())  # pylint: disable=not-callable
        .select_from(MessageReceipt)
        .join(Message, Message.id == MessageReceipt.message_id)
        .where(
            Message.conversation_id == conv.id,
            MessageReceipt.user_id == viewer.id,
            MessageReceipt.read_at.is_(None),
        )
    ) or 0

    members_out: list[MemberOut] = []
    for m in conv.members:
        members_out.append(member_out(m, is_online=is_online_fn(m.user_id)))

    title = conv.title
    if conv.type == "dm" and peer:
        title = peer.display_name

    return ConversationOut(
        id=conv.id,
        type=conv.type,
        title=title,
        peer=peer,
        last_message=last_preview,
        unread_count=int(unread),
        updated_at=updated_at,
        members=members_out,
        wallpaper_version=wallpaper_version_for(conv),
        wallpaper_dim=conv.wallpaper_dim if has_wallpaper(conv) else None,
        has_wallpaper=has_wallpaper(conv),
        disappear_after_seconds=conv.disappear_after_seconds,
        anniversary_on=conv.anniversary_on if conv.type == "dm" else None,
        streak_days=compute_dm_streak(db, conv) if conv.type == "dm" else 0,
    )


def event_message_new(message: Message, viewer_id: int | None = None) -> dict:
    return {
        "type": "message.new",
        "message": message_out(message, viewer_id).model_dump(mode="json"),
    }


def event_message_updated(message: Message, viewer_id: int | None = None) -> dict:
    return {
        "type": "message.updated",
        "message": message_out(message, viewer_id).model_dump(mode="json"),
    }


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


def event_pins_changed(conversation_id: int) -> dict:
    return {"type": "pins.changed", "conversation_id": conversation_id}


def event_stars_changed() -> dict:
    """Tell one user their private starred list changed (sent via send_to_user)."""
    return {"type": "stars.changed"}


def event_user_updated(user: User, *, is_online: bool = False) -> dict:
    return {
        "type": "user.updated",
        "user": user_out(user, is_online=is_online).model_dump(mode="json"),
    }


def event_chat_nudge(
    *,
    conversation_id: int,
    sender: User,
    nudge_id: str,
    at,
    variant: str = "wave",
) -> dict:
    return {
        "type": "chat.nudge",
        "conversation_id": conversation_id,
        "sender_id": sender.id,
        "sender_name": sender.display_name,
        "sender_username": sender.username,
        "nudge_id": nudge_id,
        "at": to_utc_iso(at),
        "variant": variant,
    }


def event_reaction_updated(
    message_id: int,
    conversation_id: int,
    reactions: list[ReactionAggOut],
) -> dict:
    return {
        "type": "reaction.updated",
        "message_id": message_id,
        "conversation_id": conversation_id,
        "reactions": [r.model_dump(mode="json") for r in reactions],
    }


def event_call_relay(event_type: str, payload: dict) -> dict:
    return {"type": event_type, **payload}


def event_doodle_relay(payload: dict, *, from_user_id: int) -> dict:
    """Fan-out an ephemeral doodle frame; vectors are never stored."""
    return {**payload, "from_user_id": from_user_id}
