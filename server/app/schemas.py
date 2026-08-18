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
    #: Stable install id from the phone. Used later to pin the admin device;
    #: optional so older clients still sign up.
    device_id: str | None = Field(default=None, max_length=80)

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

    @field_validator("device_id")
    @classmethod
    def validate_device_id(cls, v: str | None) -> str | None:
        if v is None:
            return None
        cleaned = v.strip()
        return cleaned or None


class LoginRequest(BaseModel):
    username: str
    password: str
    device_id: str | None = Field(default=None, max_length=80)

    @field_validator("device_id")
    @classmethod
    def validate_device_id(cls, v: str | None) -> str | None:
        if v is None:
            return None
        cleaned = v.strip()
        return cleaned or None


class ChangePasswordRequest(BaseModel):
    """Signed-in user changing their own password (must know the current one)."""

    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=6, max_length=128)


class UserOut(BaseModel):
    id: int
    username: str
    display_name: str
    last_seen_at: UtcDatetime | None = None
    is_online: bool = False
    has_avatar: bool = False
    avatar_version: int | None = None
    mood: str | None = None

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
    has_avatar: bool = False
    avatar_version: int | None = None


class MessagePreview(BaseModel):
    id: int
    type: str
    body: str | None
    sender_id: int
    created_at: UtcDatetime
    # Lets the chat list show "invoice.pdf" instead of a generic "File".
    media_name: str | None = None
    # Viewer-relative ticks for the sender's latest message: 0 sent, 1 delivered,
    # 2 read. Omitted when the latest message is from someone else.
    receipt_level: int | None = None


class ConversationOut(BaseModel):
    id: int
    type: str
    title: str | None
    peer: UserOut | None = None
    last_message: MessagePreview | None = None
    unread_count: int = 0
    updated_at: UtcDatetime
    members: list[MemberOut] = Field(default_factory=list)
    wallpaper_version: int | None = None
    wallpaper_dim: float | None = None
    has_wallpaper: bool = False
    disappear_after_seconds: int | None = None
    anniversary_on: str | None = None
    streak_days: int = 0


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


class ReactionAggOut(BaseModel):
    emoji: str
    count: int
    reacted_by_me: bool = False
    user_ids: list[int] = Field(default_factory=list)


class MessageOut(BaseModel):
    id: int
    conversation_id: int
    sender_id: int
    type: str
    body: str | None
    media_name: str | None = None
    media_size: int | None = None
    media_mime: str | None = None
    media_duration_ms: int | None = None
    # Pixel size of the preview, so a chat row can reserve its height before the
    # picture has been fetched and decoded.
    media_width: int | None = None
    media_height: int | None = None
    client_id: str | None = None
    created_at: UtcDatetime
    edited_at: UtcDatetime | None = None
    deleted_at: UtcDatetime | None = None
    expires_at: UtcDatetime | None = None
    reply_to: QuotedMessage | None = None
    receipts: list[ReceiptOut] = Field(default_factory=list)
    reactions: list[ReactionAggOut] = Field(default_factory=list)
    # Present on starred-list responses so the client can page the list.
    star_id: int | None = None

    model_config = {"from_attributes": True}


class NudgeOut(BaseModel):
    nudge_id: str
    conversation_id: int
    sender_id: int
    sender_name: str
    sender_username: str
    variant: str
    at: UtcDatetime


class ReactionRequest(BaseModel):
    emoji: str = Field(min_length=1, max_length=16)


_DISAPPEARING_ALLOWED = frozenset({86400, 604800, 7776000})


class DisappearingRequest(BaseModel):
    disappear_after_seconds: int | None = None

    @field_validator("disappear_after_seconds")
    @classmethod
    def validate_disappearing(cls, v: int | None) -> int | None:
        if v is not None and v not in _DISAPPEARING_ALLOWED:
            raise ValueError("Invalid disappearing timer.")
        return v


class WallpaperDimRequest(BaseModel):
    dim: float = Field(ge=0.0, le=0.8)


class AnniversaryRequest(BaseModel):
    anniversary_on: str | None = None

    @field_validator("anniversary_on")
    @classmethod
    def validate_anniversary(cls, v: str | None) -> str | None:
        if v is None:
            return None
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", v):
            raise ValueError("anniversary_on must be YYYY-MM-DD.")
        return v


class MoodRequest(BaseModel):
    mood: str | None = Field(default=None, max_length=40)


class DisplayNameRequest(BaseModel):
    display_name: str = Field(min_length=1, max_length=80)

    @field_validator("display_name")
    @classmethod
    def validate_display_name(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Display name cannot be blank.")
        return v


class CallLogRequest(BaseModel):
    media: str = Field(default="audio", max_length=16)
    outcome: str = Field(min_length=1, max_length=32)
    duration_secs: int | None = Field(default=None, ge=0)


class DeliveredRequest(BaseModel):
    message_id: int


class SharedItemOut(BaseModel):
    """One row in the conversation Media / Docs / Links gallery.

    Lightweight on purpose — the gallery never needs receipts or reply quotes.
    ``kind`` is the tab the row belongs to; ``url`` is set only for links.
    """

    message_id: int
    kind: str  # media | docs | links
    type: str
    media_name: str | None = None
    media_size: int | None = None
    media_mime: str | None = None
    media_duration_ms: int | None = None
    body: str | None = None
    url: str | None = None
    created_at: UtcDatetime
    sender_id: int


class OwnedMediaOut(BaseModel):
    """One attachment the signed-in user can reclaim from server storage."""

    message_id: int
    conversation_id: int
    conversation_title: str
    type: str
    media_name: str | None = None
    media_size: int
    media_mime: str | None = None
    created_at: UtcDatetime


class DeleteOwnedMediaRequest(BaseModel):
    message_ids: list[int] = Field(min_length=1, max_length=500)


class DeleteOwnedMediaOut(BaseModel):
    deleted: int
    reclaimed_bytes: int


class AdminStatusOut(BaseModel):
    """Whether this account may read the activity log, and who else may."""

    admin_username: str | None = None
    is_admin: bool = False
    #: True when this account may appoint the admin — nobody holds the role yet,
    #: or this account already does.
    can_claim: bool = False
    #: Set on the server itself, so the app must not offer to change it.
    locked_by_server: bool = False
    my_username: str
    #: A trusted admin device pin is stored on the server.
    admin_device_pinned: bool = False
    #: This request's X-Device-Id matches the pin.
    this_device_trusted: bool = False
    #: Admin account with no pin yet — the app should offer "Trust this phone".
    needs_device_trust: bool = False


class SetAdminRequest(BaseModel):
    username: str = Field(min_length=1, max_length=40)


class SetAdminDeviceRequest(BaseModel):
    """Trust the caller's device, or clear the pin so any admin install works."""

    clear: bool = False


class OnlineUserOut(BaseModel):
    id: int
    username: str
    display_name: str
    is_online: bool = True


class ForceLogoutOut(BaseModel):
    user_id: int
    username: str
    token_version: int
    sockets_closed: int = 0


class AuditEventOut(BaseModel):
    """One entry in the activity log."""

    id: int
    at: UtcDatetime
    action: str
    category: str
    actor_user_id: int | None = None
    actor_username: str | None = None
    conversation_id: int | None = None
    message_id: int | None = None
    target_user_id: int | None = None
    summary: str
    #: The text as it stood before an edit or a deletion, and what replaced it.
    #: Direct-message text arrives sealed by the sender's phone, so these hold
    #: the sealed token rather than anything the server could read.
    before_text: str | None = None
    after_text: str | None = None
    details: dict | None = None
    ip: str | None = None


class AuditSummaryOut(BaseModel):
    total: int
    last_day: int
    edits: int
    deletions: int
    oldest_at: UtcDatetime | None = None
