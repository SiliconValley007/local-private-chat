"""Integration tests for replying to (quoting) a message."""

from __future__ import annotations

from tests.conftest import auth_header, register


def _dm(client, a, b):
    res = client.post(
        "/api/conversations/dm",
        headers=auth_header(a["token"]),
        json={"user_id": b["user"]["id"]},
    )
    return res.json()["id"]


def test_reply_embeds_the_quoted_message(client):
    a = register(client, "alice", display_name="Alice")
    b = register(client, "bob", display_name="Bob")
    ha, hb = auth_header(a["token"]), auth_header(b["token"])
    conv_id = _dm(client, a, b)

    original = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "Where are you?"},
    ).json()

    reply = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=hb,
        json={
            "type": "text",
            "body": "On my way",
            "reply_to_message_id": original["id"],
        },
    )
    assert reply.status_code == 200
    quoted = reply.json()["reply_to"]
    assert quoted is not None
    assert quoted["id"] == original["id"]
    assert quoted["sender_id"] == a["user"]["id"]
    assert quoted["body"] == "Where are you?"
    assert quoted["type"] == "text"


def test_reply_survives_in_history(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])
    conv_id = _dm(client, a, b)

    first = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "first"},
    ).json()
    client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "second", "reply_to_message_id": first["id"]},
    )

    history = client.get(
        f"/api/conversations/{conv_id}/messages", headers=auth_header(b["token"])
    ).json()
    replied = next(m for m in history if m["body"] == "second")
    assert replied["reply_to"]["id"] == first["id"]
    assert replied["reply_to"]["body"] == "first"

    plain = next(m for m in history if m["body"] == "first")
    assert plain["reply_to"] is None


def test_cannot_reply_to_message_from_another_conversation(client):
    a = register(client, "alice")
    b = register(client, "bob")
    c = register(client, "carol")
    ha = auth_header(a["token"])

    conv_ab = _dm(client, a, b)
    conv_ac = _dm(client, a, c)

    stray = client.post(
        f"/api/conversations/{conv_ac}/messages",
        headers=ha,
        json={"type": "text", "body": "private to carol"},
    ).json()

    denied = client.post(
        f"/api/conversations/{conv_ab}/messages",
        headers=ha,
        json={
            "type": "text",
            "body": "leak?",
            "reply_to_message_id": stray["id"],
        },
    )
    assert denied.status_code == 400


def test_reply_to_missing_message_is_rejected(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])
    conv_id = _dm(client, a, b)

    res = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "hi", "reply_to_message_id": 999999},
    )
    assert res.status_code == 400
