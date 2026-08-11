"""End-to-end checks that error bodies are always a readable sentence."""

from __future__ import annotations

from tests.conftest import auth_header, register


def _detail(response) -> str:
    body = response.json()
    assert isinstance(body["detail"], str), "detail must be a sentence, not a structure"
    return body["detail"]


def test_short_username_returns_readable_sentence(client):
    res = client.post(
        "/api/auth/register",
        json={"username": "DD", "password": "secret12", "display_name": "Debjeet"},
    )
    assert res.status_code == 422
    detail = _detail(res)
    assert detail.startswith("Username must be 3 to 40 characters")
    for noise in ("value_error", "loc", "ctx", "[", "{"):
        assert noise not in detail


def test_short_password_returns_readable_sentence(client):
    res = client.post(
        "/api/auth/register",
        json={"username": "validname", "password": "123"},
    )
    assert res.status_code == 422
    assert _detail(res) == "Password must be at least 6 characters."


def test_missing_field_returns_readable_sentence(client):
    res = client.post("/api/auth/register", json={"username": "validname"})
    assert res.status_code == 422
    assert _detail(res) == "Password is required."


def test_duplicate_username_explains_what_to_do(client):
    register(client, "takenuser")
    res = client.post(
        "/api/auth/register",
        json={"username": "takenuser", "password": "secret12"},
    )
    assert res.status_code == 409
    assert _detail(res) == "That username is already taken. Please pick another one."


def test_wrong_password_does_not_reveal_which_part_failed(client):
    register(client, "realuser")
    res = client.post(
        "/api/auth/login",
        json={"username": "realuser", "password": "wrongpass"},
    )
    assert res.status_code == 401
    assert _detail(res) == "Incorrect username or password. Please try again."


def test_missing_token_asks_the_user_to_sign_in(client):
    res = client.get("/api/conversations")
    assert res.status_code == 401
    assert "sign in" in _detail(res).lower()


def test_garbage_token_reports_expired_session(client):
    res = client.get("/api/conversations", headers=auth_header("not-a-real-token"))
    assert res.status_code == 401
    assert _detail(res) == "Your session has expired. Please sign in again."


def test_unknown_username_lookup_is_readable(client):
    token = register(client, "searcher")["token"]
    res = client.get("/api/users/by-username/ghostuser", headers=auth_header(token))
    assert res.status_code == 404
    assert _detail(res) == "No one with that username is on this server."


def test_dm_with_self_is_readable(client):
    data = register(client, "loner")
    res = client.post(
        "/api/conversations/dm",
        headers=auth_header(data["token"]),
        json={"user_id": data["user"]["id"]},
    )
    assert res.status_code == 400
    assert _detail(res) == "You can't start a chat with yourself."


def test_non_member_gets_readable_refusal(client):
    owner = register(client, "owner")
    outsider = register(client, "outsider")
    group = client.post(
        "/api/conversations/groups",
        headers=auth_header(owner["token"]),
        json={"title": "Private", "member_ids": []},
    )
    assert group.status_code == 200
    res = client.get(
        f"/api/conversations/{group.json()['id']}/messages",
        headers=auth_header(outsider["token"]),
    )
    assert res.status_code == 403
    assert _detail(res) == "You're not part of this chat anymore."


def test_empty_message_body_is_readable(client):
    owner = register(client, "writer")
    group = client.post(
        "/api/conversations/groups",
        headers=auth_header(owner["token"]),
        json={"title": "Notes", "member_ids": []},
    )
    res = client.post(
        f"/api/conversations/{group.json()['id']}/messages",
        headers=auth_header(owner["token"]),
        json={"type": "text", "body": ""},
    )
    assert res.status_code == 422
    assert _detail(res) == "Message cannot be empty."
