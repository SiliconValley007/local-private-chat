"""Half-finished uploads, kept on disk so a large send can be continued.

A 500 MB attachment cannot depend on a single HTTP request surviving from start
to finish. The phone leaves the foreground, the tunnel blinks, the train enters a
cutting: any of these end the request, and if the only answer is to send the file
again from byte zero then a file that size never arrives at all.

So the bytes land in a partial file next to a small metadata record. The sender
can ask how much of it we hold and carry on from exactly there. Nothing here
touches the database: a session becomes a message only when it is finished, in
one step, so an abandoned upload leaves no half-message behind.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

#: Session ids are generated here and never taken from the caller unchecked;
#: they end up in a path, so anything but plain hex is refused.
ID_RE = re.compile(r"^[0-9a-f]{32}$")

PARTIAL_DIR_NAME = ".partial"
DATA_NAME = "data"
META_NAME = "meta.json"


class UploadSessionError(Exception):
    """Base class for the ways continuing an upload can fail."""


class UnknownSession(UploadSessionError):
    """No such session: never created, already finished, or expired."""


class OffsetMismatch(UploadSessionError):
    """The sender's idea of how much we hold disagrees with ours."""

    def __init__(self, expected: int) -> None:
        super().__init__(f"Expected offset {expected}.")
        self.expected = expected


class SessionTooLarge(UploadSessionError):
    """The bytes sent so far passed the size the session was opened for."""


@dataclass(frozen=True)
class UploadSession:
    """One upload in progress, as recorded on disk."""

    upload_id: str
    conversation_id: int
    user_id: int
    msg_type: str
    filename: str
    mime: str | None
    declared_size: int
    duration_ms: int | None
    created_at: datetime
    received: int

    @property
    def complete(self) -> bool:
        return self.received == self.declared_size

    @property
    def remaining(self) -> int:
        return max(0, self.declared_size - self.received)


def partial_root(media_root: Path) -> Path:
    """Where partial uploads live: inside media, hidden from conversation ids."""
    return media_root / PARTIAL_DIR_NAME


def session_dir(media_root: Path, upload_id: str) -> Path:
    if not ID_RE.match(upload_id or ""):
        raise UnknownSession(upload_id)
    return partial_root(media_root) / upload_id


def data_path(media_root: Path, upload_id: str) -> Path:
    return session_dir(media_root, upload_id) / DATA_NAME


def new_upload_id() -> str:
    return uuid.uuid4().hex


def create_session(
    media_root: Path,
    *,
    conversation_id: int,
    user_id: int,
    msg_type: str,
    filename: str,
    mime: str | None,
    declared_size: int,
    duration_ms: int | None = None,
    now: datetime | None = None,
    upload_id: str | None = None,
) -> UploadSession:
    """Open an empty session and record what is expected to fill it."""

    ident = upload_id or new_upload_id()
    created = now or datetime.now(timezone.utc)
    directory = session_dir(media_root, ident)
    directory.mkdir(parents=True, exist_ok=True)
    meta = {
        "upload_id": ident,
        "conversation_id": conversation_id,
        "user_id": user_id,
        "type": msg_type,
        "filename": filename,
        "mime": mime,
        "size": declared_size,
        "duration_ms": duration_ms,
        "created_at": created.isoformat(),
    }
    (directory / META_NAME).write_text(json.dumps(meta), encoding="utf-8")
    (directory / DATA_NAME).touch()
    return UploadSession(
        upload_id=ident,
        conversation_id=conversation_id,
        user_id=user_id,
        msg_type=msg_type,
        filename=filename,
        mime=mime,
        declared_size=declared_size,
        duration_ms=duration_ms,
        created_at=created,
        received=0,
    )


def read_session(media_root: Path, upload_id: str) -> UploadSession:
    """Load a session, or explain that there isn't one."""

    directory = session_dir(media_root, upload_id)
    meta_file = directory / META_NAME
    data_file = directory / DATA_NAME
    if not meta_file.is_file() or not data_file.is_file():
        raise UnknownSession(upload_id)
    try:
        meta = json.loads(meta_file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise UnknownSession(upload_id) from exc
    try:
        created = datetime.fromisoformat(str(meta["created_at"]))
        if created.tzinfo is None:
            created = created.replace(tzinfo=timezone.utc)
        return UploadSession(
            upload_id=upload_id,
            conversation_id=int(meta["conversation_id"]),
            user_id=int(meta["user_id"]),
            msg_type=str(meta["type"]),
            filename=str(meta["filename"]),
            mime=meta.get("mime"),
            declared_size=int(meta["size"]),
            duration_ms=meta.get("duration_ms"),
            created_at=created,
            received=data_file.stat().st_size,
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise UnknownSession(upload_id) from exc


def append_chunk(
    media_root: Path,
    upload_id: str,
    *,
    offset: int,
    chunk: bytes,
    max_bytes: int | None = None,
) -> UploadSession:
    """Add the next piece at ``offset``, refusing anything out of order.

    A sender that retries a piece it already sent, or that lost the reply to one,
    would otherwise duplicate or skip bytes and produce a corrupt file that looks
    like a successful upload. Insisting on the exact offset makes both cases a
    plain answer the client can resynchronise from.
    """

    session = read_session(media_root, upload_id)
    if offset != session.received:
        raise OffsetMismatch(session.received)
    ceiling = session.declared_size if max_bytes is None else min(
        session.declared_size, max_bytes
    )
    if session.received + len(chunk) > ceiling:
        raise SessionTooLarge()
    path = data_path(media_root, upload_id)
    with open(path, "ab") as out:
        out.write(chunk)
        out.flush()
        os.fsync(out.fileno())
    return read_session(media_root, upload_id)


def discard_session(media_root: Path, upload_id: str) -> None:
    """Remove a session and its bytes, whether finished, cancelled, or stale."""
    try:
        directory = session_dir(media_root, upload_id)
    except UnknownSession:
        return
    shutil.rmtree(directory, ignore_errors=True)


def is_stale(
    session_created_at: datetime, *, now: datetime, ttl_seconds: int
) -> bool:
    """True once a session has sat untouched long enough to be given up on."""
    return now - session_created_at >= timedelta(seconds=ttl_seconds)


def purge_stale(
    media_root: Path, *, now: datetime | None = None, ttl_seconds: int
) -> int:
    """Delete sessions past their time. Returns how many went.

    Called when a new session opens rather than on a timer: the cost is one
    directory listing on a path a sender is about to write to anyway, and it
    means a server that is never restarted still doesn't accumulate dead bytes.
    """

    root = partial_root(media_root)
    if not root.is_dir():
        return 0
    moment = now or datetime.now(timezone.utc)
    removed = 0
    for child in root.iterdir():
        if not child.is_dir():
            continue
        try:
            session = read_session(media_root, child.name)
        except UnknownSession:
            # Unreadable leftovers are exactly what this is for.
            shutil.rmtree(child, ignore_errors=True)
            removed += 1
            continue
        if is_stale(session.created_at, now=moment, ttl_seconds=ttl_seconds):
            shutil.rmtree(child, ignore_errors=True)
            removed += 1
    return removed


def sessions_for_user(media_root: Path, user_id: int) -> list[UploadSession]:
    """Every live session belonging to one user, newest first."""
    root = partial_root(media_root)
    if not root.is_dir():
        return []
    found: list[UploadSession] = []
    for child in sorted(root.iterdir()):
        if not child.is_dir():
            continue
        try:
            session = read_session(media_root, child.name)
        except UnknownSession:
            continue
        if session.user_id == user_id:
            found.append(session)
    found.sort(key=lambda s: s.created_at, reverse=True)
    return found
