"""Unit tests for turning framework errors into user-facing sentences."""

from __future__ import annotations

from app.errors import friendly_detail, humanize_validation_errors


def test_custom_validator_message_is_used_as_is():
    errors = [
        {
            "type": "value_error",
            "loc": ["body", "username"],
            "msg": (
                "Value error, Username must be 3 to 40 characters, using only "
                "letters, numbers, underscores or hyphens"
            ),
            "input": "DD",
            "ctx": {"error": {}},
        }
    ]
    message = humanize_validation_errors(errors)
    assert message.startswith("Username must be 3 to 40 characters")
    # None of pydantic's machinery may leak into the UI.
    for noise in ("value_error", "loc", "ctx", "{", "}", "Value error,"):
        assert noise not in message


def test_missing_and_short_fields_read_naturally():
    errors = [
        {"type": "missing", "loc": ["body", "username"], "msg": "Field required"},
        {
            "type": "string_too_short",
            "loc": ["body", "password"],
            "msg": "String should have at least 6 characters",
            "ctx": {"min_length": 6},
        },
    ]
    message = humanize_validation_errors(errors)
    assert "Username is required." in message
    assert "Password must be at least 6 characters." in message


def test_unknown_field_gets_readable_label():
    errors = [{"type": "int_parsing", "loc": ["body", "member_ids"], "msg": "bad int"}]
    assert humanize_validation_errors(errors) == "Members must be a number."


def test_field_named_body_keeps_its_own_label():
    """``loc`` is ("body", "body") for message text; the label must survive."""
    errors = [
        {
            "type": "string_too_short",
            "loc": ["body", "body"],
            "msg": "String should have at least 1 character",
            "ctx": {"min_length": 1},
        }
    ]
    assert humanize_validation_errors(errors) == "Message cannot be empty."


def test_counts_are_pluralised():
    errors = [
        {
            "type": "too_short",
            "loc": ["body", "member_ids"],
            "msg": "too short",
            "ctx": {"min_length": 2},
        }
    ]
    assert humanize_validation_errors(errors) == "Members must be at least 2 items."


def test_friendly_detail_passes_through_plain_strings():
    assert friendly_detail(409, "That username is already taken.") == (
        "That username is already taken."
    )


def test_friendly_detail_adds_sentence_punctuation():
    assert friendly_detail(400, "Type a message before sending") == (
        "Type a message before sending."
    )


def test_friendly_detail_falls_back_per_status():
    assert "sign in" in friendly_detail(401, None).lower()
    assert friendly_detail(500, None).endswith("Please try again.")


def test_friendly_detail_handles_raw_pydantic_list():
    detail = [{"type": "missing", "loc": ["body", "title"], "msg": "Field required"}]
    assert friendly_detail(422, detail) == "Group name is required."
