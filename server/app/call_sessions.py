"""In-memory pending call registry with bounded TTL.

Calls are DM-only and live only while ringing. Once a session ends or times
out it is removed so memory stays bounded.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum
from threading import Lock

from app.models import utcnow

# How long an unanswered invite may live before the server declares timeout.
CALL_TTL = timedelta(seconds=90)


class CallState(str, Enum):
    INVITED = "invited"
    RINGING = "ringing"
    ACTIVE = "active"
    ENDED = "ended"


@dataclass
class CallSessionRecord:
    call_id: str
    conversation_id: int
    caller_id: int
    callee_id: int
    media: str
    created_at: datetime = field(default_factory=utcnow)
    state: CallState = CallState.INVITED
    offer_sdp: str | None = None
    offer_sdp_type: str | None = None
    ended_reason: str | None = None
    active_at: datetime | None = None

    @property
    def was_ringing(self) -> bool:
        return self.state in (CallState.RINGING, CallState.ACTIVE) or (
            self.state == CallState.ENDED
            and self.ended_reason not in (None, "timeout")
            and self.active_at is not None
        )

    @property
    def was_active(self) -> bool:
        return self.active_at is not None

    def expired(self, now: datetime | None = None) -> bool:
        ref = now or utcnow()
        return ref - self.created_at > CALL_TTL

    def to_pending_dict(self) -> dict:
        payload: dict = {
            "call_id": self.call_id,
            "conversation_id": self.conversation_id,
            "caller_id": self.caller_id,
            "media": self.media,
            "state": self.state.value,
            "created_at": self.created_at.isoformat(),
        }
        if self.offer_sdp is not None:
            payload["offer_sdp"] = self.offer_sdp
            payload["offer_sdp_type"] = self.offer_sdp_type or "offer"
        return payload


class CallSessionRegistry:
    """Thread-safe store keyed by call_id."""

    def __init__(self) -> None:
        self._sessions: dict[str, CallSessionRecord] = {}
        self._lock = Lock()

    def reset(self) -> None:
        with self._lock:
            self._sessions.clear()

    def get(self, call_id: str) -> CallSessionRecord | None:
        with self._lock:
            return self._sessions.get(call_id)

    def upsert_invite(
        self,
        *,
        call_id: str,
        conversation_id: int,
        caller_id: int,
        callee_id: int,
        media: str,
    ) -> CallSessionRecord:
        with self._lock:
            existing = self._sessions.get(call_id)
            if existing is not None and existing.state != CallState.ENDED:
                return existing
            record = CallSessionRecord(
                call_id=call_id,
                conversation_id=conversation_id,
                caller_id=caller_id,
                callee_id=callee_id,
                media=media,
            )
            self._sessions[call_id] = record
            return record

    def store_offer(self, call_id: str, sdp: str, sdp_type: str) -> CallSessionRecord | None:
        with self._lock:
            record = self._sessions.get(call_id)
            if record is None or record.state == CallState.ENDED:
                return None
            record.offer_sdp = sdp
            record.offer_sdp_type = sdp_type
            return record

    def mark_ringing(self, call_id: str, user_id: int) -> CallSessionRecord | None:
        with self._lock:
            record = self._sessions.get(call_id)
            if record is None or record.state == CallState.ENDED:
                return None
            if user_id != record.callee_id:
                return None
            record.state = CallState.RINGING
            return record

    def mark_active(self, call_id: str) -> CallSessionRecord | None:
        with self._lock:
            record = self._sessions.get(call_id)
            if record is None or record.state == CallState.ENDED:
                return None
            record.state = CallState.ACTIVE
            record.active_at = utcnow()
            return record

    def end(self, call_id: str, reason: str) -> CallSessionRecord | None:
        with self._lock:
            record = self._sessions.pop(call_id, None)
            if record is None:
                return None
            record.state = CallState.ENDED
            record.ended_reason = reason
            return record

    def pending_for_user(self, user_id: int) -> list[CallSessionRecord]:
        now = utcnow()
        with self._lock:
            out: list[CallSessionRecord] = []
            for record in self._sessions.values():
                if record.expired(now):
                    continue
                if record.callee_id == user_id and record.state in (
                    CallState.INVITED,
                    CallState.RINGING,
                ):
                    out.append(record)
            out.sort(key=lambda r: r.created_at)
            return out

    def purge_expired(self) -> list[CallSessionRecord]:
        now = utcnow()
        expired: list[CallSessionRecord] = []
        with self._lock:
            dead_ids = [
                call_id
                for call_id, record in self._sessions.items()
                if record.expired(now)
            ]
            for call_id in dead_ids:
                record = self._sessions.pop(call_id)
                record.state = CallState.ENDED
                record.ended_reason = "timeout"
                expired.append(record)
        return expired


call_registry = CallSessionRegistry()
