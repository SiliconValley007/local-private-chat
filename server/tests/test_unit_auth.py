"""Unit tests for auth helpers and schemas."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.auth import create_access_token, decode_access_token, hash_password, verify_password
from app.schemas import RegisterRequest


def test_password_hash_roundtrip():
    hashed = hash_password("secret12")
    assert hashed != "secret12"
    assert verify_password("secret12", hashed)
    assert not verify_password("wrongpass", hashed)


def test_jwt_roundtrip():
    token = create_access_token(42, "alice")
    payload = decode_access_token(token)
    assert payload is not None
    assert payload["sub"] == "42"
    assert payload["username"] == "alice"


def test_jwt_invalid_returns_none():
    assert decode_access_token("not.a.jwt") is None


def test_register_schema_rejects_bad_username():
    with pytest.raises(ValidationError):
        RegisterRequest(username="ab", password="secret12")  # too short
    with pytest.raises(ValidationError):
        RegisterRequest(username="bad name!", password="secret12")
    with pytest.raises(ValidationError):
        RegisterRequest(username="alice", password="123")  # password too short


def test_register_schema_accepts_valid():
    req = RegisterRequest(username="alice_01", password="secret12", display_name="Alice")
    assert req.username == "alice_01"
