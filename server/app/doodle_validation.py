"""Validate ephemeral chat.doodle WebSocket payloads (never persisted)."""

from __future__ import annotations

import json
import re
from typing import Any

DOODLE_EVENT_TYPES = frozenset(
    {
        "chat.doodle.begin",
        "chat.doodle.stroke",
        "chat.doodle.undo",
        "chat.doodle.clear",
        "chat.doodle.end",
    }
)

UUID_HEX_RE = re.compile(r"^[0-9a-f]{32}$")

MAX_COLOR_ID = 7
MIN_WIDTH_ID = 0
MAX_WIDTH_ID = 4
MAX_POINTS_PER_BATCH = 128
MAX_PAYLOAD_BYTES = 8192
END_REASONS = frozenset({"cancel", "send", "disconnect"})


def parse_uuid_hex(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    lowered = value.lower()
    if UUID_HEX_RE.match(lowered):
        return lowered
    return None


def validate_point(value: Any) -> tuple[float, float] | None:
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None
    x, y = value
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        return None
    xf, yf = float(x), float(y)
    if not (0.0 <= xf <= 1.0 and 0.0 <= yf <= 1.0):
        return None
    return xf, yf


def validate_points(value: Any) -> list[tuple[float, float]] | None:
    if not isinstance(value, list) or not value:
        return None
    if len(value) > MAX_POINTS_PER_BATCH:
        return None
    out: list[tuple[float, float]] = []
    for item in value:
        pt = validate_point(item)
        if pt is None:
            return None
        out.append(pt)
    return out


def payload_size(data: dict) -> int:
    return len(json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def validate_doodle_event(data: dict) -> dict | None:
    """Return a sanitized relay payload or None when invalid."""
    event_type = data.get("type")
    if event_type not in DOODLE_EVENT_TYPES:
        return None

    conversation_id = data.get("conversation_id")
    if not isinstance(conversation_id, int):
        return None

    session_id = parse_uuid_hex(data.get("session_id"))
    if session_id is None:
        return None

    relay: dict[str, Any] = {
        "type": event_type,
        "conversation_id": conversation_id,
        "session_id": session_id,
    }

    if event_type == "chat.doodle.begin":
        color_id = data.get("color_id")
        width_id = data.get("width_id")
        if not isinstance(color_id, int) or not (0 <= color_id <= MAX_COLOR_ID):
            return None
        if not isinstance(width_id, int) or not (MIN_WIDTH_ID <= width_id <= MAX_WIDTH_ID):
            return None
        relay["color_id"] = color_id
        relay["width_id"] = width_id
    elif event_type == "chat.doodle.stroke":
        stroke_id = parse_uuid_hex(data.get("stroke_id"))
        points = validate_points(data.get("points"))
        if stroke_id is None or points is None:
            return None
        relay["stroke_id"] = stroke_id
        relay["points"] = [[x, y] for x, y in points]
    elif event_type == "chat.doodle.end":
        reason = data.get("reason", "cancel")
        if not isinstance(reason, str) or reason not in END_REASONS:
            return None
        relay["reason"] = reason
    # undo/clear/end share session + conversation only.

    if payload_size(relay) > MAX_PAYLOAD_BYTES:
        return None
    return relay
