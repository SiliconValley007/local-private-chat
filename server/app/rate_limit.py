"""In-memory rate limiters for ephemeral realtime actions."""

from __future__ import annotations

import time
from collections import defaultdict


class NudgeRateLimiter:
    """Per sender+conversation cooldown plus a global per-sender cap."""

    PER_CONV_SECONDS = 5
    GLOBAL_PER_MINUTE = 3
    WINDOW_SECONDS = 60

    def __init__(self) -> None:
        self._last_conv: dict[tuple[int, int], float] = {}
        self._global_times: dict[int, list[float]] = defaultdict(list)

    def reset(self) -> None:
        """Clear all counters (used between tests)."""
        self._last_conv.clear()
        self._global_times.clear()

    def check(self, sender_id: int, conversation_id: int, now: float | None = None) -> bool:
        """Return True when the nudge is allowed and record it."""
        ts = time.monotonic() if now is None else now
        key = (sender_id, conversation_id)
        last = self._last_conv.get(key)
        if last is not None and ts - last < self.PER_CONV_SECONDS:
            return False

        times = self._global_times[sender_id]
        cutoff = ts - self.WINDOW_SECONDS
        times[:] = [t for t in times if t > cutoff]
        if len(times) >= self.GLOBAL_PER_MINUTE:
            return False

        self._last_conv[key] = ts
        times.append(ts)
        return True


nudge_limiter = NudgeRateLimiter()


class DoodleRateLimiter:
    """Per sender+conversation caps for ephemeral doodle relay events."""

    BEGIN_COOLDOWN_SECONDS = 2
    STROKE_WINDOW_SECONDS = 10
    STROKE_MAX_PER_WINDOW = 30
    CONTROL_WINDOW_SECONDS = 10
    CONTROL_MAX_PER_WINDOW = 20

    def __init__(self) -> None:
        self._last_begin: dict[tuple[int, int], float] = {}
        self._stroke_times: dict[tuple[int, int], list[float]] = defaultdict(list)
        self._control_times: dict[tuple[int, int], list[float]] = defaultdict(list)

    def reset(self) -> None:
        self._last_begin.clear()
        self._stroke_times.clear()
        self._control_times.clear()

    def _prune(self, times: list[float], cutoff: float) -> None:
        times[:] = [t for t in times if t > cutoff]

    def check(self, sender_id: int, conversation_id: int, event_type: str, now: float | None = None) -> bool:
        ts = time.monotonic() if now is None else now
        key = (sender_id, conversation_id)

        if event_type == "chat.doodle.begin":
            last = self._last_begin.get(key)
            if last is not None and ts - last < self.BEGIN_COOLDOWN_SECONDS:
                return False
            self._last_begin[key] = ts
            return True

        if event_type == "chat.doodle.stroke":
            times = self._stroke_times[key]
            cutoff = ts - self.STROKE_WINDOW_SECONDS
            self._prune(times, cutoff)
            if len(times) >= self.STROKE_MAX_PER_WINDOW:
                return False
            times.append(ts)
            return True

        if event_type in {"chat.doodle.undo", "chat.doodle.clear", "chat.doodle.end"}:
            times = self._control_times[key]
            cutoff = ts - self.CONTROL_WINDOW_SECONDS
            self._prune(times, cutoff)
            if len(times) >= self.CONTROL_MAX_PER_WINDOW:
                return False
            times.append(ts)
            return True

        return False


doodle_limiter = DoodleRateLimiter()
