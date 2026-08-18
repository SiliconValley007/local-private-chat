"""Realtime connection hub."""

from __future__ import annotations

import asyncio
from collections import defaultdict

from fastapi import WebSocket


class ConnectionHub:
    """Tracks live WebSocket connections per user id."""

    def __init__(self) -> None:
        self._connections: dict[int, set[WebSocket]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def connect(self, user_id: int, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._connections[user_id].add(websocket)

    async def disconnect(self, user_id: int, websocket: WebSocket) -> None:
        async with self._lock:
            sockets = self._connections.get(user_id)
            if not sockets:
                return
            sockets.discard(websocket)
            if not sockets:
                del self._connections[user_id]

    async def disconnect_user(self, user_id: int, *, code: int = 4401) -> int:
        """Force-close every live socket for [user_id]. Returns how many closed.

        Used when an admin (or a password reset) kills a session: the next REST
        call already fails on token_version, but a phone with an open websocket
        would otherwise keep chatting until it happened to reconnect.
        """
        async with self._lock:
            sockets = list(self._connections.get(user_id, set()))
            self._connections.pop(user_id, None)
        closed = 0
        for ws in sockets:
            try:
                await ws.close(code=code)
                closed += 1
            except Exception:  # pylint: disable=broad-exception-caught
                pass
        return closed

    def reset(self) -> None:
        """Drop all tracked sockets (used by tests between cases)."""
        self._connections.clear()

    def is_online(self, user_id: int) -> bool:
        return bool(self._connections.get(user_id))

    def online_user_ids(self) -> set[int]:
        return set(self._connections.keys())

    async def send_to_user(self, user_id: int, event: dict) -> list[WebSocket]:
        """Send event to all sockets for user. Returns sockets that received it."""
        sockets = list(self._connections.get(user_id, set()))
        delivered: list[WebSocket] = []
        dead: list[WebSocket] = []
        for ws in sockets:
            try:
                await ws.send_json(event)
                delivered.append(ws)
            except Exception:  # pylint: disable=broad-exception-caught
                # Any send failure means the socket is gone; prune it below.
                dead.append(ws)
        for ws in dead:
            await self.disconnect(user_id, ws)
        return delivered

    async def broadcast_to_users(self, user_ids: set[int] | list[int], event: dict) -> set[int]:
        """Broadcast to users; return user_ids that had at least one successful send."""
        reached: set[int] = set()
        for uid in set(user_ids):
            delivered = await self.send_to_user(uid, event)
            if delivered:
                reached.add(uid)
        return reached


hub = ConnectionHub()
