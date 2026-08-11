"""Timestamps must leave the server tagged as UTC.

SQLite hands back naive datetimes, and a naive ISO string is read as *local*
time by clients, which made an 11:23 IST message show up as 05:53.
"""

from datetime import datetime, timedelta, timezone

from app.realtime.events import event_presence, event_receipt
from app.schemas import MessageOut, UserOut, to_utc_iso


def test_naive_datetime_is_labelled_utc():
    assert to_utc_iso(datetime(2026, 8, 11, 5, 53, 12)) == "2026-08-11T05:53:12Z"


def test_aware_datetime_is_converted_to_utc():
    ist = timezone(timedelta(hours=5, minutes=30))
    assert to_utc_iso(datetime(2026, 8, 11, 11, 23, 12, tzinfo=ist)) == "2026-08-11T05:53:12Z"


def test_message_json_carries_the_utc_marker():
    payload = MessageOut(
        id=1,
        conversation_id=1,
        sender_id=1,
        type="text",
        body="hi",
        created_at=datetime(2026, 8, 11, 5, 53, 12),
    ).model_dump(mode="json")
    assert payload["created_at"] == "2026-08-11T05:53:12Z"


def test_last_seen_json_carries_the_utc_marker():
    payload = UserOut(
        id=1,
        username="faye",
        display_name="Faye",
        last_seen_at=datetime(2026, 8, 11, 5, 53, 12),
    ).model_dump(mode="json")
    assert payload["last_seen_at"] == "2026-08-11T05:53:12Z"


def test_missing_last_seen_stays_null():
    payload = UserOut(id=1, username="faye", display_name="Faye").model_dump(mode="json")
    assert payload["last_seen_at"] is None


def test_websocket_events_carry_the_utc_marker():
    at = datetime(2026, 8, 11, 5, 53, 12)
    receipt = event_receipt("read", message_id=1, conversation_id=2, user_id=3, at=at)
    presence = event_presence(user_id=3, online=False, last_seen_at=at)
    assert receipt["at"] == "2026-08-11T05:53:12Z"
    assert presence["last_seen_at"] == "2026-08-11T05:53:12Z"


def test_websocket_events_allow_no_timestamp():
    receipt = event_receipt("delivered", message_id=1, conversation_id=2, user_id=3, at=None)
    presence = event_presence(user_id=3, online=True, last_seen_at=None)
    assert receipt["at"] is None
    assert presence["last_seen_at"] is None
