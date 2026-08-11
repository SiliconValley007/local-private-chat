"""Conversations: DMs, groups, inbox."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.db import get_db
from app.deps import get_current_user
from app.models import Conversation, ConversationMember, Message, MessageReceipt, User
from app.realtime import events
from app.realtime.hub import hub
from app.schemas import (
    AddMembersRequest,
    ConversationOut,
    CreateDmRequest,
    CreateGroupRequest,
    MemberOut,
    MessagePreview,
    UserOut,
)
from app.services import member_user_ids, require_membership

router = APIRouter(prefix="/api/conversations", tags=["conversations"])

CHAT_NOT_FOUND = "That chat is no longer available."


def _peer_for_dm(conv: Conversation, viewer_id: int) -> User | None:
    for m in conv.members:
        if m.user_id != viewer_id:
            return m.user
    return None


def _conversation_out(db: Session, conv: Conversation, viewer: User) -> ConversationOut:
    peer_user = _peer_for_dm(conv, viewer.id) if conv.type == "dm" else None
    peer = None
    if peer_user:
        peer = UserOut(
            id=peer_user.id,
            username=peer_user.username,
            display_name=peer_user.display_name,
            last_seen_at=peer_user.last_seen_at,
            is_online=hub.is_online(peer_user.id),
        )

    last = db.scalar(
        select(Message)
        .where(Message.conversation_id == conv.id)
        .order_by(Message.id.desc())
        .limit(1)
    )
    last_preview = None
    updated_at = conv.created_at
    if last:
        last_preview = MessagePreview(
            id=last.id,
            type="text" if last.deleted_at is not None else last.type,
            body=(
                "This message was deleted"
                if last.deleted_at is not None
                else last.body
            ),
            sender_id=last.sender_id,
            created_at=last.created_at,
            media_name=None if last.deleted_at is not None else last.media_name,
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
        members_out.append(
            MemberOut(
                user_id=m.user_id,
                username=m.user.username,
                display_name=m.user.display_name,
                role=m.role,
                is_online=hub.is_online(m.user_id),
            )
        )

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
    )


def _load_conv(db: Session, conversation_id: int) -> Conversation | None:
    return db.scalar(
        select(Conversation)
        .where(Conversation.id == conversation_id)
        .options(selectinload(Conversation.members).selectinload(ConversationMember.user))
    )


@router.get("", response_model=list[ConversationOut])
def list_conversations(
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[ConversationOut]:
    conv_ids = db.scalars(
        select(ConversationMember.conversation_id).where(ConversationMember.user_id == current.id)
    ).all()
    if not conv_ids:
        return []
    convs = db.scalars(
        select(Conversation)
        .where(Conversation.id.in_(conv_ids))
        .options(selectinload(Conversation.members).selectinload(ConversationMember.user))
    ).all()
    outs = [_conversation_out(db, c, current) for c in convs]
    outs.sort(key=lambda c: c.updated_at, reverse=True)
    return outs


@router.post("/dm", response_model=ConversationOut)
async def create_or_get_dm(
    body: CreateDmRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    if body.user_id == current.id:
        raise HTTPException(status_code=400, detail="You can't start a chat with yourself.")
    other = db.get(User, body.user_id)
    if other is None:
        raise HTTPException(
            status_code=404,
            detail="That user isn't on this server anymore.",
        )

    a, b = sorted([current.id, body.user_id])
    dm_key = f"{a}:{b}"
    existing = db.scalar(select(Conversation).where(Conversation.dm_key == dm_key))
    if existing:
        conv = _load_conv(db, existing.id)
        assert conv is not None
        return _conversation_out(db, conv, current)

    conv = Conversation(type="dm", title=None, dm_key=dm_key, created_by=current.id)
    db.add(conv)
    db.flush()
    db.add(ConversationMember(conversation_id=conv.id, user_id=current.id, role="member"))
    db.add(ConversationMember(conversation_id=conv.id, user_id=other.id, role="member"))
    db.commit()
    conv = _load_conv(db, conv.id)
    assert conv is not None
    await hub.broadcast_to_users(
        {current.id, other.id},
        events.event_conversation_updated(conv.id),
    )
    return _conversation_out(db, conv, current)


@router.post("/groups", response_model=ConversationOut)
async def create_group(
    body: CreateGroupRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    title = body.title.strip()
    if not title:
        raise HTTPException(status_code=400, detail="Please enter a name for the group.")

    member_ids = set(body.member_ids)
    member_ids.discard(current.id)
    users = db.scalars(select(User).where(User.id.in_(member_ids))).all() if member_ids else []
    if len(users) != len(member_ids):
        raise HTTPException(
            status_code=400,
            detail="Some of the people you picked are no longer on this server.",
        )

    conv = Conversation(type="group", title=title[:120], created_by=current.id)
    db.add(conv)
    db.flush()
    db.add(ConversationMember(conversation_id=conv.id, user_id=current.id, role="admin"))
    for u in users:
        db.add(ConversationMember(conversation_id=conv.id, user_id=u.id, role="member"))
    db.commit()

    conv = _load_conv(db, conv.id)
    assert conv is not None
    await hub.broadcast_to_users(
        member_user_ids(db, conv.id),
        events.event_conversation_updated(conv.id),
    )
    return _conversation_out(db, conv, current)


@router.get("/{conversation_id}/members", response_model=list[MemberOut])
def get_members(
    conversation_id: int,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> list[MemberOut]:
    require_membership(db, conversation_id, current.id)
    conv = _load_conv(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail=CHAT_NOT_FOUND)
    return [
        MemberOut(
            user_id=m.user_id,
            username=m.user.username,
            display_name=m.user.display_name,
            role=m.role,
            is_online=hub.is_online(m.user_id),
        )
        for m in conv.members
    ]


@router.post("/{conversation_id}/members", response_model=ConversationOut)
async def add_members(
    conversation_id: int,
    body: AddMembersRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> ConversationOut:
    membership = require_membership(db, conversation_id, current.id)
    conv = _load_conv(db, conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail=CHAT_NOT_FOUND)
    if conv.type != "group":
        raise HTTPException(
            status_code=400,
            detail="You can only add people to a group chat.",
        )
    if membership.role != "admin":
        raise HTTPException(
            status_code=403,
            detail="Only a group admin can add people to this group.",
        )

    existing = {m.user_id for m in conv.members}
    for uid in body.member_ids:
        if uid in existing:
            continue
        user = db.get(User, uid)
        if user is None:
            raise HTTPException(
                status_code=400,
                detail="One of the people you picked is no longer on this server.",
            )
        db.add(ConversationMember(conversation_id=conv.id, user_id=uid, role="member"))
    db.commit()
    conv = _load_conv(db, conversation_id)
    assert conv is not None
    await hub.broadcast_to_users(
        member_user_ids(db, conv.id),
        events.event_conversation_updated(conv.id),
    )
    return _conversation_out(db, conv, current)
