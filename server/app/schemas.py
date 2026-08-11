"""Pydantic request/response schemas."""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Annotated

from pydantic import BaseModel, Field, PlainSerializer, field_validator


USERNAME_PATTERN = r"^[A-Za-z0-9_-]{3,40}$"


def to_utc_iso(value: datetime) -> str:
    """ISO-8601 in UTC, always ending in ``Z``.

    Every timestamp is stored in UTC, but SQLite drops the tzinfo, so values read
    back are naive. Sending them with no zone marker made clients read them as
    local time and show UTC clock values (an 11:23 IST message appeared as 05:53).
    """
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


# Use instead of a bare ``datetime`` on anything sent to a client.
UtcDatetime = Annotated[datetime, PlainSerializer(to_utc_iso, return_type=str)]


class RegisterRequest(BaseModel):
    username: str
    password: str = Field(min_length=6, max_length=128)
    display_name: str | None = None

    @field_validator("username")
    @classmethod
    def validate_username(cls, v: str) -> str:
        v = v.strip()
        if not re.match(USERNAME_PATTERN, v):
            raise ValueError(
                "Username must be 3 to 40 characters, using only letters, "
                "numbers, underscores or hyphens"
            )
        return v


class LoginRequest(BaseModel):
    username: str
    password: str


class UserOut(BaseModel):
    id: int
    username: str
    display_name: str
    last_seen_at: UtcDatetime | None = None
    is_online: bool = False

    model_config = {"from_attributes": True}


class AuthResponse(BaseModel):
    token: str
    user: UserOut


class CreateDmRequest(BaseModel):
    user_id: int


class CreateGroupRequest(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    member_ids: list[int] = Field(default_factory=list)


class AddMembersRequest(BaseModel):
    member_ids: list[int] = Field(min_length=1)


class MemberOut(BaseModel):
    user_id: int
    username: str
    display_name: str
    role: str
    is_online: bool = False


class MessagePreview(BaseModel):
    id: int
    type: str
    body: str | None
    sender_id: int
    created_at: UtcDatetime
    # Lets the chat list show "invoice.pdf" instead of a generic "File".
    media_name: str | None = None


class ConversationOut(BaseModel):
    id: int
    type: str
    title: str | None
    peer: UserOut | None = None
    last_message: MessagePreview | None = None
    unread_count: int = 0
    updated_at: UtcDatetime
    members: list[MemberOut] = Field(default_factory=list)


class SendMessageRequest(BaseModel):
    type: str = "text"
    body: str = Field(min_length=1, max_length=8000)
    client_id: str | None = None
    reply_to_message_id: int | None = None


class EditMessageRequest(BaseModel):
    body: str = Field(min_length=1, max_length=8000)


class QuotedMessage(BaseModel):
    """Enough of a quoted message to draw the reply header on any client.

    Sent inline so a reply still renders when the original is older than the
    page of history the phone currently holds.
    """

    id: int
    sender_id: int
    type: str
    body: str | None = None
    media_name: str | None = None
    deleted: bool = False

    model_config = {"from_attributes": True}


class ReceiptOut(BaseModel):
    user_id: int
    delivered_at: UtcDatetime | None = None
    read_at: UtcDatetime | None = None


class MessageOut(BaseModel):
    id: int
    conversation_id: int
    sender_id: int
    type: str
    body: str | None
    media_name: str | None = None
    media_size: int | None = None
    media_mime: str | None = None
    client_id: str | None = None
    created_at: UtcDatetime
    edited_at: UtcDatetime | None = None
    deleted_at: UtcDatetime | None = None
    reply_to: QuotedMessage | None = None
    receipts: list[ReceiptOut] = Field(default_factory=list)

    model_config = {"from_attributes": True}


class DeliveredRequest(BaseModel):
    message_id: int
