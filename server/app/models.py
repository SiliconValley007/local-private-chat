"""SQLAlchemy models."""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import (
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.base import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(40), unique=True, nullable=False, index=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    display_name: Mapped[str] = mapped_column(String(80), nullable=False)
    avatar_path: Mapped[str | None] = mapped_column(String(512), nullable=True)
    avatar_updated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    mood: Mapped[str | None] = mapped_column(String(40), nullable=True)
    #: Bumped to invalidate every outstanding JWT for this account. Logout is
    #: otherwise local-only; without this a stolen token lives until expiry.
    token_version: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    memberships: Mapped[list[ConversationMember]] = relationship(back_populates="user")
    messages: Mapped[list[Message]] = relationship(back_populates="sender")


class Conversation(Base):
    __tablename__ = "conversations"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    type: Mapped[str] = mapped_column(String(16), nullable=False)  # dm | group
    title: Mapped[str | None] = mapped_column(String(120), nullable=True)
    dm_key: Mapped[str | None] = mapped_column(String(64), unique=True, nullable=True, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    created_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"), nullable=True)
    wallpaper_path: Mapped[str | None] = mapped_column(String(512), nullable=True)
    wallpaper_dim: Mapped[float] = mapped_column(Float, default=0.25)
    wallpaper_set_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"), nullable=True)
    wallpaper_set_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    disappear_after_seconds: Mapped[int | None] = mapped_column(Integer, nullable=True)
    anniversary_on: Mapped[str | None] = mapped_column(String(10), nullable=True)

    members: Mapped[list[ConversationMember]] = relationship(
        back_populates="conversation", cascade="all, delete-orphan"
    )
    messages: Mapped[list[Message]] = relationship(
        back_populates="conversation", cascade="all, delete-orphan"
    )


class ConversationMember(Base):
    __tablename__ = "conversation_members"
    __table_args__ = (UniqueConstraint("conversation_id", "user_id", name="uq_conv_user"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    conversation_id: Mapped[int] = mapped_column(ForeignKey("conversations.id"), nullable=False)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    role: Mapped[str] = mapped_column(String(16), default="member")  # member | admin
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    conversation: Mapped[Conversation] = relationship(back_populates="members")
    user: Mapped[User] = relationship(back_populates="memberships")


class ConversationDay(Base):
    """One row per chat, per person, per UTC day they said something.

    The couple streak is counted from these rows instead of from the transcript,
    so deleting a message or letting a disappearing timer clear the day cannot
    take back a day that genuinely happened. Nothing removes rows from here.
    """

    __tablename__ = "conversation_days"
    __table_args__ = (
        UniqueConstraint("conversation_id", "user_id", "day", name="uq_conv_user_day"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    conversation_id: Mapped[int] = mapped_column(
        ForeignKey("conversations.id"), nullable=False, index=True
    )
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    # A UTC calendar day as YYYY-MM-DD: one shared clock for both phones.
    day: Mapped[str] = mapped_column(String(10), nullable=False)


class Message(Base):
    __tablename__ = "messages"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    conversation_id: Mapped[int] = mapped_column(
        ForeignKey("conversations.id"), nullable=False, index=True
    )
    sender_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    type: Mapped[str] = mapped_column(String(16), nullable=False, default="text")
    body: Mapped[str | None] = mapped_column(Text, nullable=True)
    media_path: Mapped[str | None] = mapped_column(String(512), nullable=True)
    media_thumb_path: Mapped[str | None] = mapped_column(String(512), nullable=True)
    media_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    media_size: Mapped[int | None] = mapped_column(Integer, nullable=True)
    media_mime: Mapped[str | None] = mapped_column(String(128), nullable=True)
    # Video length in milliseconds, captured on the client at upload time so the
    # chat tile can show a duration badge without opening the file.
    media_duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    client_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, index=True
    )
    # Set when this message quotes an earlier one in the same conversation.
    reply_to_message_id: Mapped[int | None] = mapped_column(
        ForeignKey("messages.id", ondelete="SET NULL"), nullable=True
    )
    edited_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    # Soft delete — body is cleared, but the row stays so replies keep their place.
    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    conversation: Mapped[Conversation] = relationship(back_populates="messages")
    sender: Mapped[User] = relationship(back_populates="messages")
    # join_depth stops a chain of replies from loading the whole thread.
    reply_to: Mapped[Message | None] = relationship(
        "Message",
        remote_side="Message.id",
        foreign_keys="Message.reply_to_message_id",
        lazy="joined",
        join_depth=1,
    )
    receipts: Mapped[list[MessageReceipt]] = relationship(
        back_populates="message", cascade="all, delete-orphan"
    )
    reactions: Mapped[list[MessageReaction]] = relationship(
        back_populates="message", cascade="all, delete-orphan"
    )


class MessageHide(Base):
    __tablename__ = "message_hides"
    __table_args__ = (UniqueConstraint("user_id", "message_id", name="uq_hide_user_msg"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id"), nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    message: Mapped[Message] = relationship()


class MessageReaction(Base):
    __tablename__ = "message_reactions"
    __table_args__ = (UniqueConstraint("message_id", "user_id", name="uq_react_msg_user"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id"), nullable=False, index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    emoji: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    message: Mapped[Message] = relationship(back_populates="reactions")
    user: Mapped[User] = relationship()


class MessageReceipt(Base):
    __tablename__ = "message_receipts"
    __table_args__ = (UniqueConstraint("message_id", "user_id", name="uq_msg_user"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id"), nullable=False, index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    message: Mapped[Message] = relationship(back_populates="receipts")


class MessagePin(Base):
    """A message sticky-pinned at the top of a conversation (Telegram-style)."""

    __tablename__ = "message_pins"
    __table_args__ = (
        UniqueConstraint("conversation_id", "message_id", name="uq_pin_conv_msg"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    conversation_id: Mapped[int] = mapped_column(
        ForeignKey("conversations.id"), nullable=False, index=True
    )
    message_id: Mapped[int] = mapped_column(
        ForeignKey("messages.id"), nullable=False, index=True
    )
    pinned_by: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    pinned_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    message: Mapped[Message] = relationship()
    conversation: Mapped[Conversation] = relationship()
    pinner: Mapped[User] = relationship()


class MessageStar(Base):
    """A private, per-user bookmark (WhatsApp-style starred messages)."""

    __tablename__ = "message_stars"
    __table_args__ = (
        UniqueConstraint("user_id", "message_id", name="uq_star_user_msg"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id"), nullable=False, index=True)
    starred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    message: Mapped[Message] = relationship()
    user: Mapped[User] = relationship()


class NudgeEvent(Base):
    """Persisted chat nudge — kept out of the normal message transcript."""

    __tablename__ = "nudge_events"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    conversation_id: Mapped[int] = mapped_column(
        ForeignKey("conversations.id"), nullable=False, index=True
    )
    sender_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"), nullable=False, index=True
    )
    variant: Mapped[str] = mapped_column(String(16), nullable=False, default="wave")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, index=True
    )

    conversation: Mapped[Conversation] = relationship()
    sender: Mapped[User] = relationship()


class DeviceToken(Base):
    """FCM registration tokens for data-only push (no message bodies)."""

    __tablename__ = "device_tokens"
    __table_args__ = (UniqueConstraint("token", name="uq_device_token"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    token: Mapped[str] = mapped_column(String(512), nullable=False)
    platform: Mapped[str] = mapped_column(String(32), default="android")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    user: Mapped[User] = relationship()


class AuditEvent(Base):
    """One thing somebody did, written down so it cannot be argued with later.

    Deliberately free of foreign keys. Deleting a message, or a whole account,
    must not take its history with it — that is the entire point of the table.
    Message text is kept as it was found: ``before_text`` holds what was there
    before an edit or a deletion, ``after_text`` what replaced it.
    """

    __tablename__ = "audit_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, index=True
    )
    action: Mapped[str] = mapped_column(String(48), nullable=False, index=True)
    actor_user_id: Mapped[int | None] = mapped_column(Integer, nullable=True, index=True)
    # Kept alongside the id so a log entry still names its author after the
    # account is gone.
    actor_username: Mapped[str | None] = mapped_column(String(40), nullable=True)
    conversation_id: Mapped[int | None] = mapped_column(Integer, nullable=True, index=True)
    message_id: Mapped[int | None] = mapped_column(Integer, nullable=True, index=True)
    target_user_id: Mapped[int | None] = mapped_column(Integer, nullable=True)
    summary: Mapped[str] = mapped_column(String(400), nullable=False, default="")
    before_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    after_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    #: JSON object with whatever else the action had to say.
    details: Mapped[str | None] = mapped_column(Text, nullable=True)
    ip: Mapped[str | None] = mapped_column(String(64), nullable=True)


class ServerSetting(Base):
    """Server-wide settings that outlive a restart, keyed by name."""

    __tablename__ = "server_settings"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text, nullable=False, default="")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_by: Mapped[int | None] = mapped_column(Integer, nullable=True)


class EncryptedBackup(Base):
    """Client-side encrypted backup blob (server never sees plaintext)."""

    __tablename__ = "encrypted_backups"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), primary_key=True)
    ciphertext_b64: Mapped[str] = mapped_column(Text, nullable=False)
    salt_b64: Mapped[str] = mapped_column(String(128), nullable=False)
    nonce_b64: Mapped[str] = mapped_column(String(128), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
