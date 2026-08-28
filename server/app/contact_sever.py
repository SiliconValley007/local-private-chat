"""Hide a chat, wipe it for both people, and refuse further contact.

Tailscale ACLs are not consulted here. If someone lost network access they
already cannot reach the server; these tools remove the leftover thread and stop
a later reconnect from picking up the same conversation.
"""

from __future__ import annotations

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app import audit
from app.models import (
    Conversation,
    ConversationMember,
    Message,
    User,
    UserBlock,
    utcnow,
)
from app.realtime import events
from app.realtime.hub import hub

def refuse_if_blocked(db: Session, conversation_id: int, user_id: int) -> None:
    """Direct chats with a removed contact cannot send."""
    from fastapi import HTTPException, status

    from app.models import Conversation

    conv = db.get(Conversation, conversation_id)
    if conv is None or conv.type != "dm":
        return
    peer_id = None
    for member in conv.members:
        if member.user_id != user_id:
            peer_id = member.user_id
            break
    if peer_id is None:
        # Members may not be loaded.
        rows = db.scalars(
            select(ConversationMember.user_id).where(
                ConversationMember.conversation_id == conversation_id
            )
        ).all()
        peer_id = next((uid for uid in rows if uid != user_id), None)
    if peer_id is not None and is_blocked(db, user_id, peer_id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This contact was removed. You can't send messages.",
        )


def _pair(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a < b else (b, a)


def block_between(db: Session, user_id: int, other_id: int) -> UserBlock | None:
    if user_id == other_id:
        return None
    low, high = _pair(user_id, other_id)
    return db.scalar(
        select(UserBlock).where(
            UserBlock.user_low_id == low,
            UserBlock.user_high_id == high,
        )
    )


def is_blocked(db: Session, user_id: int, other_id: int) -> bool:
    return block_between(db, user_id, other_id) is not None


def blocked_peer_ids(db: Session, user_id: int) -> set[int]:
    rows = db.scalars(
        select(UserBlock).where(
            or_(UserBlock.user_low_id == user_id, UserBlock.user_high_id == user_id)
        )
    ).all()
    out: set[int] = set()
    for row in rows:
        out.add(row.user_high_id if row.user_low_id == user_id else row.user_low_id)
    return out


async def set_block(
    db: Session,
    *,
    actor: User,
    other: User,
    blocked: bool,
) -> None:
    if actor.id == other.id:
        raise ValueError("You cannot remove yourself.")
    existing = block_between(db, actor.id, other.id)
    if blocked and existing is None:
        low, high = _pair(actor.id, other.id)
        db.add(
            UserBlock(
                user_low_id=low,
                user_high_id=high,
                blocked_by=actor.id,
            )
        )
        db.commit()
        audit.record(
            db,
            action="contact.blocked",
            summary=f"{actor.username} removed contact with {other.username}",
            actor=actor,
            target_user_id=other.id,
        )
    elif not blocked and existing is not None:
        db.delete(existing)
        db.commit()
        audit.record(
            db,
            action="contact.unblocked",
            summary=f"{actor.username} restored contact with {other.username}",
            actor=actor,
            target_user_id=other.id,
        )
    await hub.broadcast_to_users(
        {actor.id, other.id},
        {"type": "contact.updated", "user_id": other.id if blocked else actor.id},
    )


def hide_membership(db: Session, *, conversation_id: int, user_id: int) -> None:
    member = db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user_id,
        )
    )
    if member is not None and member.hidden_at is None:
        member.hidden_at = utcnow()


def unhide_membership(db: Session, *, conversation_id: int, user_id: int) -> None:
    member = db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user_id,
        )
    )
    if member is not None:
        member.hidden_at = None


async def delete_conversation_for(
    db: Session,
    *,
    conv: Conversation,
    actor: User,
    scope: str,
) -> None:
    """scope=me hides the chat; everyone also clears history on a DM."""
    from app.media_retention import drop_retains_for_message
    from app.services import member_user_ids, soft_delete_message

    members = member_user_ids(db, conv.id)
    if scope == "everyone":
        if conv.type != "dm":
            raise ValueError("Only a direct chat can be deleted for both people.")
        messages = db.scalars(
            select(Message).where(
                Message.conversation_id == conv.id,
                Message.deleted_at.is_(None),
            )
        ).all()
        for message in messages:
            drop_retains_for_message(db, message.id)
            await soft_delete_message(
                db, message_id=message.id, actor=actor, bypass_sender_check=True
            )
        for uid in members:
            hide_membership(db, conversation_id=conv.id, user_id=uid)
        db.commit()
        audit.record(
            db,
            action="conversation.deleted",
            summary=f"{actor.username} deleted a direct chat for everyone",
            actor=actor,
            conversation_id=conv.id,
            details={"scope": "everyone"},
        )
    else:
        hide_membership(db, conversation_id=conv.id, user_id=actor.id)
        db.commit()
        audit.record(
            db,
            action="conversation.hidden",
            summary=f"{actor.username} deleted a chat from their inbox",
            actor=actor,
            conversation_id=conv.id,
            details={"scope": "me"},
        )
    await hub.broadcast_to_users(members, events.event_conversation_updated(conv.id))
