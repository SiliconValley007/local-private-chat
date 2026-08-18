"""The server's own record of everything anybody did.

Chat apps let people rewrite the past: a message is edited, or deleted for
everyone, and what it said is gone. On a private server that is also the only
copy of what happened, so this module keeps a separate, append-only account of
each action — who, when, to which message, and for an edit or a deletion, the
text as it was before.

Two things keep it honest:

* Nothing here ever raises. An action is not failed because its log entry could
  not be written, but a failure is printed, never swallowed silently.
* Rows are never updated or deleted by any code path in this app. There is no
  edit endpoint, no delete endpoint, and no cascade from the tables it refers to
  (see :class:`app.models.AuditEvent`).

Whole-message privacy still applies: a direct message arrives already sealed by
the sender's phone, so what is written down is the sealed token. The app marks
those rows as such rather than pretending the server can read them.
"""

from __future__ import annotations

import json
from contextvars import ContextVar
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import (
    AuditEvent,
    Conversation,
    ConversationMember,
    Message,
    User,
)

#: Category each action belongs to, which is what the app's filter chips use.
#: "other" is the answer for anything not listed, so a new action still lands
#: somewhere sensible before it is named here.
CATEGORIES: tuple[str, ...] = (
    "messages",
    "edits",
    "deletions",
    "accounts",
    "settings",
    "calls",
    "reads",
    "other",
)

_ACTION_CATEGORY: dict[str, str] = {
    "message.sent": "messages",
    "message.edited": "edits",
    "message.deleted": "deletions",
    "message.hidden": "deletions",
    "message.expired": "deletions",
    "media.deleted": "deletions",
    "message.pinned": "messages",
    "message.unpinned": "messages",
    "message.starred": "messages",
    "message.unstarred": "messages",
    "message.reacted": "messages",
    "message.reaction_removed": "messages",
    "message.read": "reads",
    "chat.nudge": "messages",
    "account.registered": "accounts",
    "account.signed_in": "accounts",
    "account.password_changed": "accounts",
    "account.avatar_set": "accounts",
    "account.avatar_removed": "accounts",
    "account.mood_set": "accounts",
    "account.display_name_set": "accounts",
    "device.registered": "accounts",
    "device.removed": "accounts",
    "backup.saved": "accounts",
    "conversation.created": "settings",
    "conversation.members_added": "settings",
    "conversation.wallpaper_set": "settings",
    "conversation.wallpaper_cleared": "settings",
    "conversation.wallpaper_dimmed": "settings",
    "conversation.disappearing_set": "settings",
    "conversation.anniversary_set": "settings",
    "admin.designated": "settings",
    "admin.device_trusted": "settings",
    "admin.device_cleared": "settings",
    "admin.force_logout": "settings",
    "call.started": "calls",
    "call.ended": "calls",
}


def category_for(action: str) -> str:
    """Which filter an action answers to. Anything unnamed lands in "other"."""
    return _ACTION_CATEGORY.get(action, "other")


def actions_in(category: str) -> list[str]:
    """Every named action in one category, for filtering a query."""
    return [a for a, c in _ACTION_CATEGORY.items() if c == category]


#: Counts the entries written while serving the current request, so the
#: catch-all middleware only speaks up for a request nothing else described.
#:
#: A list rather than an int on purpose. The middleware that opens the scope
#: hands the request off to a child task, and a value rebound inside that task
#: would never be seen by the middleware again — so the count is kept in an
#: object both sides share and mutate.
_recorded: ContextVar[list[int] | None] = ContextVar("audit_recorded", default=None)
#: Caller address for the request being served, so service code deep in the
#: stack does not have to be handed a Request object it has no other use for.
_client_ip: ContextVar[str | None] = ContextVar("audit_client_ip", default=None)


def begin_request(ip: str | None) -> tuple[Any, Any]:
    """Starts a request's audit scope. Returns tokens for :func:`end_request`."""
    return _recorded.set([0]), _client_ip.set(ip)


def end_request(tokens: tuple[Any, Any]) -> int:
    """Ends the scope and reports how many entries the request produced."""
    counter = _recorded.get()
    written = counter[0] if counter else 0
    recorded_token, ip_token = tokens
    _recorded.reset(recorded_token)
    _client_ip.reset(ip_token)
    return written


def _note_written() -> None:
    counter = _recorded.get()
    if counter is not None:
        counter[0] += 1


def record(
    db: Session,
    *,
    action: str,
    summary: str,
    actor: User | None = None,
    actor_user_id: int | None = None,
    actor_username: str | None = None,
    conversation_id: int | None = None,
    message_id: int | None = None,
    target_user_id: int | None = None,
    before_text: str | None = None,
    after_text: str | None = None,
    details: dict[str, Any] | None = None,
    ip: str | None = None,
) -> None:
    """Writes one entry. Never raises, never blocks the action it describes."""
    try:
        acting_id = actor.id if actor is not None else actor_user_id
        payload = dict(details) if details else {}
        if conversation_id is not None:
            # Written down now, while the membership is still true. A phone can
            # only name a chat it is in, and an account can leave or be removed,
            # so who the parties were has to come from here to be worth anything
            # later.
            for key, value in _chat_parties(db, conversation_id, acting_id).items():
                payload.setdefault(key, value)
        event = AuditEvent(
            action=action,
            summary=summary[:400],
            actor_user_id=acting_id,
            actor_username=(
                actor.username if actor is not None else actor_username
            ),
            conversation_id=conversation_id,
            message_id=message_id,
            target_user_id=target_user_id,
            before_text=before_text,
            after_text=after_text,
            details=json.dumps(payload, default=str) if payload else None,
            ip=ip if ip is not None else _client_ip.get(),
        )
        db.add(event)
        db.commit()
        _note_written()
    except Exception as exc:  # noqa: BLE001 - logging must not break the request
        db.rollback()
        print(f"AUDIT WRITE FAILED action={action}: {exc}")


def _chat_parties(
    db: Session,
    conversation_id: int,
    acting_user_id: int | None,
) -> dict[str, Any]:
    """Who was in the chat an action happened in, named from the server's own
    tables rather than guessed from whatever the reader's phone still holds.

    For a two-person chat the counterpart is unambiguous, so it is recorded as
    ``other_user_id``/``other_username`` — the person on the far side of the
    action, never the account that performed it. A chat with nobody else in it
    (notes to self) says so instead of naming the actor a second time, which is
    what made an entry read as though a message had been sent to somebody else.
    """
    try:
        conv = db.get(Conversation, conversation_id)
        if conv is None:
            return {}
        rows = db.execute(
            select(User.id, User.username)
            .join(ConversationMember, ConversationMember.user_id == User.id)
            .where(ConversationMember.conversation_id == conversation_id)
            .order_by(User.id)
        ).all()
        out: dict[str, Any] = {
            "chat_kind": conv.type,
            "chat_member_count": len(rows),
        }
        if conv.title:
            out["chat_title"] = conv.title
        others = [(uid, name) for uid, name in rows if uid != acting_user_id]
        if conv.type == "dm":
            if len(others) == 1:
                out["other_user_id"], out["other_username"] = others[0]
            elif not others:
                # Both sides of the chat are the same account.
                out["chat_is_self"] = True
        elif others:
            out["other_usernames"] = [name for _, name in others]
        return out
    except Exception as exc:  # noqa: BLE001 - context is a nicety, never a blocker
        print(f"AUDIT CHAT CONTEXT FAILED conversation={conversation_id}: {exc}")
        return {}


def snapshot(message: Message) -> dict[str, Any]:
    """The parts of a message worth keeping once the row itself may change."""
    return {
        "type": message.type,
        "conversation_id": message.conversation_id,
        "sender_id": message.sender_id,
        # Kept by name as well as by number: an account can be renamed or
        # deleted, and an entry that only holds "sender 1" stops being evidence
        # the moment the users table moves on.
        "sender_username": _sender_username(message),
        "created_at": _iso(message.created_at),
        "media_name": message.media_name,
        "media_mime": message.media_mime,
        "media_size": message.media_size,
        "reply_to_message_id": message.reply_to_message_id,
        "client_id": message.client_id,
    }


def _sender_username(message: Message) -> str | None:
    try:
        sender = message.sender
        return None if sender is None else sender.username
    except Exception:  # noqa: BLE001 - a detached row must not fail the log
        return None


def _iso(value: datetime | None) -> str | None:
    return None if value is None else value.isoformat()


def describe_message(message: Message) -> str:
    """A short, log-friendly name for a message: its kind, not its contents."""
    if message.type == "text":
        return "a text message"
    if message.media_name:
        return f"{message.type} “{message.media_name}”"
    return f"a {message.type} message"
