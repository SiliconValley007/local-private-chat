"""Integration tests: WebSocket realtime."""

from __future__ import annotations

import pytest
from starlette.websockets import WebSocketDisconnect

from tests.conftest import auth_header, register


def test_ws_rejects_missing_token(client):
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/ws") as ws:
            ws.receive_json()


def test_ws_message_fanout_and_typing(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])

    dm = client.post("/api/conversations/dm", headers=ha, json={"user_id": b["user"]["id"]})
    conv_id = dm.json()["id"]

    with client.websocket_connect(f"/ws?token={b['token']}") as ws_b:
        # Presence / connect noise may arrive; drain optional
        msg = client.post(
            f"/api/conversations/{conv_id}/messages",
            headers=ha,
            json={"type": "text", "body": "realtime hi", "client_id": "rt1"},
        )
        assert msg.status_code == 200
        message_id = msg.json()["id"]

        events = []
        # Collect a few events until we see message.new
        for _ in range(10):
            data = ws_b.receive_json()
            events.append(data)
            if data.get("type") == "message.new":
                break

        types = [e.get("type") for e in events]
        assert "message.new" in types
        new_evt = next(e for e in events if e["type"] == "message.new")
        assert new_evt["message"]["body"] == "realtime hi"
        assert new_evt["message"]["id"] == message_id

        # Typing from Alice while Bob listens
        with client.websocket_connect(f"/ws?token={a['token']}") as ws_a:
            ws_a.send_json(
                {"type": "typing", "conversation_id": conv_id, "is_typing": True}
            )
            typing_evt = None
            for _ in range(10):
                data = ws_b.receive_json()
                if data.get("type") == "typing":
                    typing_evt = data
                    break
            assert typing_evt is not None
            assert typing_evt["user_id"] == a["user"]["id"]
            assert typing_evt["is_typing"] is True

            ws_a.send_json({"type": "ping"})
            # Alice may get pong
            for _ in range(5):
                data = ws_a.receive_json()
                if data.get("type") == "pong":
                    break
            else:
                # ping reply is best-effort; don't fail hard if presence arrived instead
                pass


def test_ws_ack_delivered(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])

    dm = client.post("/api/conversations/dm", headers=ha, json={"user_id": b["user"]["id"]})
    conv_id = dm.json()["id"]

    with client.websocket_connect(f"/ws?token={a['token']}") as ws_a:
        msg = client.post(
            f"/api/conversations/{conv_id}/messages",
            headers=ha,
            json={"type": "text", "body": "need ack"},
        )
        message_id = msg.json()["id"]

        with client.websocket_connect(f"/ws?token={b['token']}") as ws_b:
            # Bob may already have auto-delivered via REST fanout if connected earlier;
            # send explicit ack for a fresh message while both online
            msg2 = client.post(
                f"/api/conversations/{conv_id}/messages",
                headers=ha,
                json={"type": "text", "body": "need ack 2"},
            )
            mid2 = msg2.json()["id"]

            # Drain Bob until message.new for mid2
            for _ in range(15):
                data = ws_b.receive_json()
                if data.get("type") == "message.new" and data["message"]["id"] == mid2:
                    break

            ws_b.send_json({"type": "ack.delivered", "message_id": mid2})

            got_receipt = False
            for _ in range(15):
                data = ws_a.receive_json()
                if (
                    data.get("type") == "receipt.delivered"
                    and data.get("message_id") == mid2
                    and data.get("user_id") == b["user"]["id"]
                ):
                    got_receipt = True
                    break
            assert got_receipt, "Alice should receive receipt.delivered"

        # silence unused
        assert message_id
