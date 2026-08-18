"""Pure call-log outcome and payload helpers (server authoritative)."""

from __future__ import annotations

import json
from datetime import datetime
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from app.call_sessions import CallSessionRecord


def call_log_client_id(call_id: str) -> str:
    return f"call:{call_id}"


def call_log_outcome(
    terminal_event: str,
    *,
    was_ringing: bool,
    was_active: bool,
) -> str:
    """Map a terminal signaling event to a persisted call-log outcome."""
    if was_active or terminal_event == "call.end":
        return "answered"
    mapping = {
        "call.reject": "rejected",
        "call.busy": "busy",
        "call.cancel": "cancelled",
        "call.timeout": "missed" if was_ringing else "unreachable",
    }
    return mapping.get(terminal_event, "missed")


def should_include_ended_by(outcome: str) -> bool:
    """Only connected calls name who hung up."""
    return outcome == "answered"


def connected_duration_secs(
    record: CallSessionRecord,
    *,
    ended_at: datetime | None = None,
) -> int | None:
    start = record.active_at
    if start is None:
        return None
    from app.models import utcnow

    end = ended_at or utcnow()
    secs = int((end - start).total_seconds())
    return max(0, secs)


def build_call_log_body(
    record: CallSessionRecord,
    *,
    outcome: str,
    duration_secs: int | None,
    ended_by_user_id: int | None,
) -> str:
    payload: dict = {
        "media": record.media,
        "outcome": outcome,
        "duration_secs": duration_secs,
        "call_id": record.call_id,
    }
    if should_include_ended_by(outcome) and ended_by_user_id is not None:
        payload["ended_by_user_id"] = ended_by_user_id
    return json.dumps(payload, separators=(",", ":"))
