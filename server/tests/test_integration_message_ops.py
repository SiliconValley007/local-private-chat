"""Edit, soft-delete, and search messages."""

from __future__ import annotations

from tests.conftest import auth_header, register


def _dm(client, a, b):
    res = client.post(
        "/api/conversations/dm",
        headers=auth_header(a["token"]),
        json={"user_id": b["user"]["id"]},
    )
    return res.json()["id"]


def test_edit_message_updates_body_and_edited_at(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])
    conv_id = _dm(client, a, b)

    msg = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "hello"},
    ).json()

    edited = client.patch(
        f"/api/messages/{msg['id']}",
        headers=ha,
        json={"body": "hello world"},
    )
    assert edited.status_code == 200
    assert edited.json()["body"] == "hello world"
    assert edited.json()["edited_at"] is not None

    history = client.get(
        f"/api/conversations/{conv_id}/messages",
        headers=auth_header(b["token"]),
    ).json()
    assert history[-1]["body"] == "hello world"
    assert history[-1]["edited_at"] is not None


def test_cannot_edit_someone_elses_message(client):
    a = register(client, "alice")
    b = register(client, "bob")
    conv_id = _dm(client, a, b)
    msg = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=auth_header(a["token"]),
        json={"type": "text", "body": "mine"},
    ).json()

    denied = client.patch(
        f"/api/messages/{msg['id']}",
        headers=auth_header(b["token"]),
        json={"body": "hijacked"},
    )
    assert denied.status_code == 403


def test_delete_leaves_tombstone(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])
    conv_id = _dm(client, a, b)
    msg = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "secret"},
    ).json()

    deleted = client.delete(f"/api/messages/{msg['id']}", headers=ha)
    assert deleted.status_code == 200
    assert deleted.json()["deleted_at"] is not None
    assert deleted.json()["body"] == "This message was deleted"

    history = client.get(
        f"/api/conversations/{conv_id}/messages",
        headers=auth_header(b["token"]),
    ).json()
    assert history[-1]["body"] == "This message was deleted"
    assert history[-1]["deleted_at"] is not None


def test_search_finds_text_across_chats(client):
    a = register(client, "alice")
    b = register(client, "bob")
    c = register(client, "carol")
    ha = auth_header(a["token"])
    ab = _dm(client, a, b)
    ac = _dm(client, a, c)

    client.post(
        f"/api/conversations/{ab}/messages",
        headers=ha,
        json={"type": "text", "body": "meeting at noon"},
    )
    client.post(
        f"/api/conversations/{ac}/messages",
        headers=ha,
        json={"type": "text", "body": "bring snacks"},
    )

    hits = client.get(
        "/api/messages/search",
        headers=ha,
        params={"q": "meeting"},
    )
    assert hits.status_code == 200
    bodies = [m["body"] for m in hits.json()]
    assert "meeting at noon" in bodies
    assert "bring snacks" not in bodies


def test_search_scoped_to_conversation(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])
    conv_id = _dm(client, a, b)
    client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "unique-zebra-phrase"},
    )
    hits = client.get(
        "/api/messages/search",
        headers=ha,
        params={"q": "zebra", "conversation_id": conv_id},
    )
    assert len(hits.json()) == 1
