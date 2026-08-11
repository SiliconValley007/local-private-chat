"""Unit tests for the push payload that wakes a closed app."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from app import fcm


class _FakeUnregistered(Exception):
    """Stands in for messaging.UnregisteredError."""


@pytest.fixture(name="sent")
def sent_fixture(monkeypatch):
    """Capture the messages handed to firebase-admin instead of sending them."""
    captured: list[SimpleNamespace] = []

    def fake_send(message):
        if message.token == "dead-token":
            raise _FakeUnregistered("not registered")
        captured.append(message)
        return "projects/x/messages/1"

    # Every firebase-admin builder just records its keyword arguments.
    fake_messaging = SimpleNamespace(
        Message=SimpleNamespace,
        Notification=SimpleNamespace,
        AndroidConfig=SimpleNamespace,
        AndroidNotification=SimpleNamespace,
        send=fake_send,
    )
    monkeypatch.setattr(fcm, "messaging", fake_messaging)
    monkeypatch.setattr(fcm, "init_firebase", lambda: True)
    monkeypatch.setattr(fcm, "UNREGISTERED_ERRORS", (_FakeUnregistered,))
    return captured


def test_push_is_high_priority_data_so_phone_can_apply_local_name(sent):
    result = fcm.send_message_push(
        ["token-a"],
        data={
            "conversation_id": 7,
            "message_id": 42,
            "sender_username": "faye",
        },
    )

    assert result.sent == 1
    assert result.invalid_tokens == []
    message = sent[0]
    # A notification block is drawn directly by Android and cannot consult the
    # private nickname stored on the receiving phone.
    assert not hasattr(message, "notification")
    assert message.android.priority == "high"
    assert message.android.ttl.total_seconds() == 12 * 60 * 60


def test_push_never_includes_message_content(sent):
    fcm.send_message_push(
        ["token-a"],
        data={
            "conversation_id": 7,
            "message_id": 42,
            "sender_name": "Faye",
            "sender_username": "faye",
        },
    )

    payload = sent[0].data
    assert set(payload) == {
        "conversation_id",
        "message_id",
        "sender_name",
        "sender_username",
    }
    # FCM requires strings, and nothing resembling a chat body may appear.
    assert all(isinstance(value, str) for value in payload.values())
    assert "body" not in payload


def test_dead_tokens_are_reported_for_cleanup(sent):
    result = fcm.send_message_push(
        ["token-a", "dead-token"],
        data={"conversation_id": 1},
    )

    assert result.sent == 1
    assert result.invalid_tokens == ["dead-token"]
    assert len(sent) == 1


def test_push_is_skipped_when_firebase_is_not_configured(monkeypatch):
    monkeypatch.setattr(fcm, "init_firebase", lambda: False)
    result = fcm.send_message_push(["token-a"], data={})
    assert result == fcm.PushResult(0, [])
