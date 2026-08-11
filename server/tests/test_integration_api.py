"""Integration tests: auth, users, DMs, groups, messages, receipts."""

from __future__ import annotations

from tests.conftest import auth_header, register


def test_health(client):
    res = client.get("/api/health")
    assert res.status_code == 200
    assert res.json()["ok"] is True


def test_register_login_me(client):
    data = register(client, "alice", display_name="Alice")
    assert data["user"]["username"] == "alice"
    assert data["token"]

    bad = client.post("/api/auth/login", json={"username": "alice", "password": "wrongpass"})
    assert bad.status_code == 401

    login = client.post("/api/auth/login", json={"username": "alice", "password": "secret12"})
    assert login.status_code == 200
    token = login.json()["token"]

    me = client.get("/api/auth/me", headers=auth_header(token))
    assert me.status_code == 200
    assert me.json()["username"] == "alice"


def test_duplicate_username_rejected(client):
    register(client, "alice")
    res = client.post(
        "/api/auth/register",
        json={"username": "alice", "password": "secret12"},
    )
    assert res.status_code == 409


def test_users_list_excludes_self(client):
    a = register(client, "alice")
    register(client, "bob")
    res = client.get("/api/users", headers=auth_header(a["token"]))
    assert res.status_code == 200
    names = {u["username"] for u in res.json()}
    assert names == {"bob"}


def test_dm_get_or_create_and_messages(client):
    a = register(client, "alice", display_name="Alice")
    b = register(client, "bob", display_name="Bob")
    ha, hb = auth_header(a["token"]), auth_header(b["token"])

    dm1 = client.post("/api/conversations/dm", headers=ha, json={"user_id": b["user"]["id"]})
    assert dm1.status_code == 200
    conv_id = dm1.json()["id"]
    assert dm1.json()["type"] == "dm"
    assert dm1.json()["peer"]["username"] == "bob"

    # Same pair returns same conversation
    dm2 = client.post("/api/conversations/dm", headers=hb, json={"user_id": a["user"]["id"]})
    assert dm2.json()["id"] == conv_id

    msg = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "Hello Bob", "client_id": "c1"},
    )
    assert msg.status_code == 200
    assert msg.json()["body"] == "Hello Bob"
    message_id = msg.json()["id"]

    # Idempotent client_id
    again = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "Hello Bob", "client_id": "c1"},
    )
    assert again.json()["id"] == message_id

    history = client.get(f"/api/conversations/{conv_id}/messages", headers=hb)
    assert history.status_code == 200
    assert len(history.json()) == 1
    assert history.json()[0]["body"] == "Hello Bob"

    # Delivered + read
    delivered = client.post(f"/api/messages/{message_id}/delivered", headers=hb)
    assert delivered.status_code == 200
    read = client.post(f"/api/conversations/{conv_id}/read", headers=hb)
    assert read.status_code == 200
    assert read.json()["marked"] >= 1

    history2 = client.get(f"/api/conversations/{conv_id}/messages", headers=ha)
    receipts = history2.json()[0]["receipts"]
    assert len(receipts) == 1
    assert receipts[0]["delivered_at"] is not None
    assert receipts[0]["read_at"] is not None


def test_non_member_cannot_read_messages(client):
    a = register(client, "alice")
    b = register(client, "bob")
    c = register(client, "carol")
    dm = client.post(
        "/api/conversations/dm",
        headers=auth_header(a["token"]),
        json={"user_id": b["user"]["id"]},
    )
    conv_id = dm.json()["id"]
    denied = client.get(
        f"/api/conversations/{conv_id}/messages",
        headers=auth_header(c["token"]),
    )
    assert denied.status_code == 403


def test_group_create_inbox_and_send(client):
    a = register(client, "alice")
    b = register(client, "bob")
    c = register(client, "carol")
    ha = auth_header(a["token"])

    grp = client.post(
        "/api/conversations/groups",
        headers=ha,
        json={"title": "Family", "member_ids": [b["user"]["id"], c["user"]["id"]]},
    )
    assert grp.status_code == 200
    assert grp.json()["type"] == "group"
    assert grp.json()["title"] == "Family"
    assert len(grp.json()["members"]) == 3
    conv_id = grp.json()["id"]

    msg = client.post(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        json={"type": "text", "body": "Hi group"},
    )
    assert msg.status_code == 200

    inbox_b = client.get("/api/conversations", headers=auth_header(b["token"]))
    assert inbox_b.status_code == 200
    ids = {row["id"] for row in inbox_b.json()}
    assert conv_id in ids
    family = next(row for row in inbox_b.json() if row["id"] == conv_id)
    assert family["unread_count"] >= 1


def test_add_group_members_admin_only(client):
    a = register(client, "alice")
    b = register(client, "bob")
    c = register(client, "carol")
    ha, hb = auth_header(a["token"]), auth_header(b["token"])

    grp = client.post(
        "/api/conversations/groups",
        headers=ha,
        json={"title": "Team", "member_ids": [b["user"]["id"]]},
    )
    conv_id = grp.json()["id"]

    # Non-admin cannot add
    denied = client.post(
        f"/api/conversations/{conv_id}/members",
        headers=hb,
        json={"member_ids": [c["user"]["id"]]},
    )
    assert denied.status_code == 403

    ok = client.post(
        f"/api/conversations/{conv_id}/members",
        headers=ha,
        json={"member_ids": [c["user"]["id"]]},
    )
    assert ok.status_code == 200
    assert len(ok.json()["members"]) == 3


def test_message_pagination(client):
    a = register(client, "alice")
    b = register(client, "bob")
    ha = auth_header(a["token"])
    dm = client.post("/api/conversations/dm", headers=ha, json={"user_id": b["user"]["id"]})
    conv_id = dm.json()["id"]

    ids = []
    for i in range(5):
        res = client.post(
            f"/api/conversations/{conv_id}/messages",
            headers=ha,
            json={"type": "text", "body": f"m{i}"},
        )
        ids.append(res.json()["id"])

    page = client.get(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        params={"limit": 2},
    )
    assert len(page.json()) == 2
    assert page.json()[0]["body"] == "m3"
    assert page.json()[1]["body"] == "m4"

    older = client.get(
        f"/api/conversations/{conv_id}/messages",
        headers=ha,
        params={"limit": 2, "before_id": page.json()[0]["id"]},
    )
    assert len(older.json()) == 2
    assert older.json()[0]["body"] == "m1"
    assert older.json()[1]["body"] == "m2"
