"""Unit tests for ConnectionHub."""

from __future__ import annotations

import asyncio

from app.realtime.hub import ConnectionHub


class FakeWebSocket:
    def __init__(self, fail: bool = False):
        self.fail = fail
        self.accepted = False
        self.sent: list[dict] = []

    async def accept(self):
        self.accepted = True

    async def send_json(self, data):
        if self.fail:
            raise RuntimeError("broken")
        self.sent.append(data)


def test_hub_connect_disconnect_online():
    async def _run():
        h = ConnectionHub()
        ws = FakeWebSocket()
        await h.connect(1, ws)  # type: ignore[arg-type]
        assert h.is_online(1)
        assert 1 in h.online_user_ids()
        await h.disconnect(1, ws)  # type: ignore[arg-type]
        assert not h.is_online(1)

    asyncio.run(_run())


def test_hub_broadcast_and_dead_socket_cleanup():
    async def _run():
        h = ConnectionHub()
        good = FakeWebSocket()
        bad = FakeWebSocket(fail=True)
        await h.connect(1, good)  # type: ignore[arg-type]
        await h.connect(2, bad)  # type: ignore[arg-type]

        reached = await h.broadcast_to_users({1, 2}, {"type": "ping"})
        assert 1 in reached
        assert 2 not in reached
        assert good.sent == [{"type": "ping"}]
        assert not h.is_online(2)  # dead socket removed

    asyncio.run(_run())
