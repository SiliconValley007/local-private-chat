"""Unit tests for the admin password-reset CLI."""

from __future__ import annotations

from reset_password import list_users, main, reset_user


def test_list_users_empty(capsys):
    assert list_users() == 0
    out = capsys.readouterr().out
    assert "No users" in out


def test_reset_password_roundtrip(client, capsys):
    # Register through the API so the same DB fixtures apply.
    client.post(
        "/api/auth/register",
        json={"username": "alice", "password": "secret12", "display_name": "Alice"},
    )
    assert list_users() == 0
    listed = capsys.readouterr().out
    assert "alice" in listed

    assert reset_user("alice", "brand-new-pass") == 0
    assert "Password reset for @alice" in capsys.readouterr().out

    old = client.post("/api/auth/login", json={"username": "alice", "password": "secret12"})
    assert old.status_code == 401
    fresh = client.post(
        "/api/auth/login", json={"username": "alice", "password": "brand-new-pass"}
    )
    assert fresh.status_code == 200


def test_reset_unknown_user(capsys):
    assert reset_user("nobody", "secret12") == 1
    err = capsys.readouterr().err
    assert "No user named" in err


def test_main_list_mode(capsys):
    code = main([])
    assert code == 0
    out = capsys.readouterr().out
    assert ("No users" in out) or ("USERNAME" in out)