"""WebSocket endpoint for realtime events."""

from __future__ import annotations

import json

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app import audit
from app.auth import decode_access_token
from app import db as db_module
from app.call_sessions import call_registry
from app.doodle_validation import DOODLE_EVENT_TYPES, validate_doodle_event
from app.fcm import send_call_incoming_push
from app.models import Conversation, DeviceToken, MessageReceipt, User, utcnow
from app.realtime import events
from app.realtime.hub import hub
from app.rate_limit import doodle_limiter
from app.services import (
    finalize_call_log,
    get_membership,
    load_message,
    member_user_ids,
    notify_shared_contacts,
    send_chat_nudge,
)

router = APIRouter()

UNAUTHORIZED_CLOSE_CODE = 4401

CALL_EVENTS = frozenset(
    {
        "call.invite",
        "call.offer",
        "call.answer",
        "call.ice",
        "call.reject",
        "call.end",
        "call.busy",
        "call.ringing",
        "call.cancel",
    }
)
E2E_EVENTS = frozenset({"e2e.hello", "e2e.reply", "e2e.need_key"})


from app.sessions import token_version_matches


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
    user = db.get(User, user_id)
    if user is None:
        return None
    if not token_version_matches(user, payload):
        return None
    return user


def _dm_peer_id(db: Session, conversation_id: int, user_id: int) -> int | None:
    conv = db.get(Conversation, conversation_id)
    if conv is None or conv.type != "dm":
        return None
    members = member_user_ids(db, conversation_id)
    if user_id not in members or len(members) != 2:
        return None
    others = members - {user_id}
    return next(iter(others)) if others else None


async def _notify_call_timeouts(db: Session) -> None:
    for record in call_registry.purge_expired():
        await finalize_call_log(
            db,
            record,
            terminal_event="call.timeout",
            ended_by_user_id=None,
        )
        relay = {
            "conversation_id": record.conversation_id,
            "call_id": record.call_id,
            "from_user_id": record.caller_id,
            "media": record.media,
            "reason": "timeout",
        }
        await hub.send_to_user(
            record.caller_id,
            events.event_call_relay("call.timeout", relay),
        )
        await hub.send_to_user(
            record.callee_id,
            events.event_call_relay("call.end", relay),
        )


async def _deliver_pending_calls(db: Session, user: User) -> None:
    """Replay unanswered invites when the callee reconnects."""
    for record in call_registry.pending_for_user(user.id):
        if get_membership(db, record.conversation_id, user.id) is None:
            continue
        invite = {
            "conversation_id": record.conversation_id,
            "call_id": record.call_id,
            "from_user_id": record.caller_id,
            "media": record.media,
        }
        caller = db.get(User, record.caller_id)
        if caller is not None:
            invite["caller_username"] = caller.username
            invite["caller_name"] = caller.display_name
        await hub.send_to_user(user.id, events.event_call_relay("call.invite", invite))
        if record.offer_sdp:
            offer = {
                "conversation_id": record.conversation_id,
                "call_id": record.call_id,
                "from_user_id": record.caller_id,
                "sdp": record.offer_sdp,
                "sdp_type": record.offer_sdp_type or "offer",
            }
            await hub.send_to_user(user.id, events.event_call_relay("call.offer", offer))


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: str | None = None) -> None:
    db = db_module.SessionLocal()
    try:
        user = _user_from_token(db, token)
        if user is None:
            await websocket.accept()
            await websocket.close(code=UNAUTHORIZED_CLOSE_CODE)
            return

        await hub.connect(user.id, websocket)
        user.last_seen_at = None
        db.commit()
        await notify_shared_contacts(db, user.id, online=True, last_seen_at=None)
        await _notify_call_timeouts(db)
        await _deliver_pending_calls(db, user)

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
    members = member_user_ids(db, conversation_id)
    targets = members - {user.id}
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


async def _handle_chat_nudge(db: Session, user: User, data: dict) -> None:
    conversation_id = data.get("conversation_id")
    if not isinstance(conversation_id, int):
        return
    variant = data.get("variant", "wave")
    if not isinstance(variant, str):
        variant = "wave"
    nudge_id = data.get("nudge_id")
    if not isinstance(nudge_id, str) or not nudge_id:
        nudge_id = None
    await send_chat_nudge(
        db, user, conversation_id, variant=variant, nudge_id=nudge_id
    )


async def _handle_call_event(db: Session, user: User, data: dict) -> None:
    await _notify_call_timeouts(db)

    conversation_id = data.get("conversation_id")
    if not isinstance(conversation_id, int):
        return
    if get_membership(db, conversation_id, user.id) is None:
        return

    event_type = data.get("type")
    if event_type not in CALL_EVENTS:
        return

    call_id = data.get("call_id")
    if not isinstance(call_id, str) or not call_id:
        return

    peer_id = _dm_peer_id(db, conversation_id, user.id)
    if peer_id is None:
        return

    relay = {k: v for k, v in data.items() if k != "type"}
    relay["conversation_id"] = conversation_id
    relay["from_user_id"] = user.id

    if event_type == "call.invite":
        media = str(data.get("media", "audio"))
        call_registry.upsert_invite(
            call_id=call_id,
            conversation_id=conversation_id,
            caller_id=user.id,
            callee_id=peer_id,
            media=media,
        )
        audit.record(
            db,
            action="call.started",
            summary=f"{user.username} placed a {media} call in chat {conversation_id}",
            actor=user,
            conversation_id=conversation_id,
            target_user_id=peer_id,
            details={
                "call_id": call_id,
                "media": media,
                "caller_user_id": user.id,
                "caller_username": user.username,
                "callee_user_id": peer_id,
            },
        )
        invite_relay = {
            **relay,
            "caller_username": user.username,
            "caller_name": user.display_name,
        }
        await hub.send_to_user(peer_id, events.event_call_relay(event_type, invite_relay))
        if hub.is_online(peer_id):
            delivery_state = "websocket"
        else:
            tokens = db.scalars(
                select(DeviceToken.token).where(DeviceToken.user_id == peer_id)
            ).all()
            if tokens:
                result = send_call_incoming_push(
                    list(tokens),
                    conversation_id=conversation_id,
                    call_id=call_id,
                    caller_id=user.id,
                    caller_name=user.display_name,
                    caller_username=user.username,
                    media=media,
                )
                if result.invalid_tokens:
                    db.execute(
                        delete(DeviceToken).where(DeviceToken.token.in_(result.invalid_tokens))
                    )
                    db.commit()
                delivery_state = "push_attempted" if result.sent > 0 else "unreachable"
            else:
                delivery_state = "unreachable"
        await hub.send_to_user(
            user.id,
            events.event_call_relay(
                "call.delivery",
                {
                    "conversation_id": conversation_id,
                    "call_id": call_id,
                    "from_user_id": user.id,
                    "state": delivery_state,
                },
            ),
        )
        return

    if event_type == "call.offer":
        sdp = data.get("sdp")
        if isinstance(sdp, str):
            call_registry.store_offer(
                call_id,
                sdp,
                str(data.get("sdp_type", "offer")),
            )
        await hub.send_to_user(peer_id, events.event_call_relay(event_type, relay))
        return

    if event_type == "call.ringing":
        updated = call_registry.mark_ringing(call_id, user.id)
        if updated is None:
            return
        await hub.send_to_user(updated.caller_id, events.event_call_relay(event_type, relay))
        return

    if event_type == "call.answer":
        call_registry.mark_active(call_id)
        await hub.send_to_user(peer_id, events.event_call_relay(event_type, relay))
        return

    if event_type in {"call.reject", "call.busy", "call.cancel", "call.end"}:
        reason = {
            "call.reject": "rejected",
            "call.busy": "busy",
            "call.cancel": "cancelled",
            "call.end": "ended",
        }[event_type]
        record = call_registry.end(call_id, reason)
        if record is not None:
            ended_by = user.id if event_type == "call.end" else None
            await finalize_call_log(
                db,
                record,
                terminal_event=event_type,
                ended_by_user_id=ended_by,
            )
        await hub.send_to_user(peer_id, events.event_call_relay(event_type, relay))
        return

    # ICE and any future relay-only frames.
    await hub.send_to_user(peer_id, events.event_call_relay(event_type, relay))


async def _handle_e2e_event(db: Session, user: User, data: dict) -> None:
    conversation_id = data.get("conversation_id")
    if not isinstance(conversation_id, int):
        return
    peer_id = _dm_peer_id(db, conversation_id, user.id)
    if peer_id is None:
        return
    event_type = data.get("type")
    if event_type not in E2E_EVENTS:
        return
    relay = {k: v for k, v in data.items() if k != "type"}
    relay["conversation_id"] = conversation_id
    relay["from_user_id"] = user.id
    await hub.send_to_user(peer_id, events.event_call_relay(event_type, relay))


async def _handle_doodle_event(db: Session, user: User, data: dict) -> None:
    relay = validate_doodle_event(data)
    if relay is None:
        return
    conversation_id = relay["conversation_id"]
    if get_membership(db, conversation_id, user.id) is None:
        return
    if not doodle_limiter.check(user.id, conversation_id, relay["type"]):
        return
    members = member_user_ids(db, conversation_id)
    targets = members - {user.id}
    await hub.broadcast_to_users(
        targets,
        events.event_doodle_relay(relay, from_user_id=user.id),
    )


async def _handle_client_event(db: Session, user: User, data: dict) -> None:
    etype = data.get("type")
    if etype == "typing":
        await _handle_typing(db, user, data)
    elif etype == "ack.delivered":
        await _handle_ack_delivered(db, user, data)
    elif etype == "chat.nudge":
        await _handle_chat_nudge(db, user, data)
    elif etype in DOODLE_EVENT_TYPES:
        await _handle_doodle_event(db, user, data)
    elif etype in CALL_EVENTS:
        await _handle_call_event(db, user, data)
    elif etype in E2E_EVENTS:
        await _handle_e2e_event(db, user, data)
    elif etype == "ping":
        await hub.send_to_user(user.id, {"type": "pong"})
