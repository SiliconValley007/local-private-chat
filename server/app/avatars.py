"""User avatar storage, validation, and safe path resolution."""

from __future__ import annotations

import mimetypes
import uuid
import zlib
from pathlib import Path

import aiofiles
from fastapi import HTTPException, UploadFile

from app.config import MEDIA_ROOT

AVATAR_DIR = "avatars"
MAX_AVATAR_BYTES = 5 * 1024 * 1024

ALLOWED_MIMES = frozenset(
    {
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp",
    }
)
ALLOWED_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png", ".gif", ".webp"})

# Sent by clients that stream a file without sniffing it (every upload from the
# Flutter app arrives this way). It says nothing either way, so the file name and
# the magic bytes decide instead of rejecting the upload outright.
GENERIC_MIMES = frozenset({"", "application/octet-stream", "binary/octet-stream"})

# Conservative magic-byte checks for the allowed formats.
_MAGIC_CHECKS: tuple[tuple[bytes, int], ...] = (
    (b"\xff\xd8\xff", 0),  # JPEG
    (b"\x89PNG\r\n\x1a\n", 0),  # PNG
    (b"GIF87a", 0),  # GIF
    (b"GIF89a", 0),  # GIF
    (b"RIFF", 0),  # WebP (RIFF....WEBP checked below)
)


def avatar_version_for(user) -> int | None:
    """Cache-busting token for avatar URLs.

    Derived from the stored file name (a fresh uuid on every upload) rather than
    a timestamp: two uploads within the same second used to produce identical
    whole-second versions, so clients kept serving the stale cached image. The
    path is stable while the avatar is unchanged, so the token is stable too.
    """
    if not user.avatar_path:
        return None
    return zlib.crc32(user.avatar_path.encode("utf-8")) & 0xFFFFFFFF


def has_avatar(user) -> bool:
    return bool(user.avatar_path)


def _avatars_root() -> Path:
    return (MEDIA_ROOT / AVATAR_DIR).resolve()


def avatar_rel_path(user_id: int, stored_name: str) -> str:
    return f"{AVATAR_DIR}/{user_id}/{stored_name}"


def resolve_avatar_file(rel_path: str) -> Path:
    """Resolve a stored avatar path and reject traversal outside avatars/."""
    full = (MEDIA_ROOT / rel_path).resolve()
    root = _avatars_root()
    if not str(full).startswith(str(root)):
        raise HTTPException(status_code=400, detail="Avatar is not available.")
    return full


def extension_for(filename: str, content_type: str | None) -> str:
    ext = Path(filename or "").suffix.lower()
    if ext in ALLOWED_EXTENSIONS:
        return ext
    mime = (content_type or "").split(";", 1)[0].strip().lower()
    mapping = {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/gif": ".gif",
        "image/webp": ".webp",
    }
    return mapping.get(mime, "")


def validate_image_header(header: bytes, ext: str) -> None:
    if ext == ".webp":
        if len(header) < 12 or header[:4] != b"RIFF" or header[8:12] != b"WEBP":
            raise HTTPException(status_code=400, detail="That image format is not supported.")
        return
    for magic, offset in _MAGIC_CHECKS:
        if magic == b"RIFF":
            continue
        if header[offset : offset + len(magic)] == magic:
            return
    raise HTTPException(status_code=400, detail="That image format is not supported.")


def validate_upload_metadata(filename: str, content_type: str | None) -> str:
    """Choose the stored extension, rejecting anything that cannot be an image.

    The declared MIME type is a hint, not proof. Dart's http client labels every
    streamed file ``application/octet-stream``, so insisting on ``image/*`` here
    turned away perfectly good photos. Anything that still looks like an image
    by name or by declared type is allowed through to
    :func:`validate_image_header`, which reads the magic bytes and is the check
    that actually keeps non-images out.
    """
    mime = (content_type or "").split(";", 1)[0].strip().lower()
    if mime not in ALLOWED_MIMES and mime not in GENERIC_MIMES:
        raise HTTPException(status_code=400, detail="That image format is not supported.")
    ext = extension_for(filename, mime)
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="That image format is not supported.")
    return ext


async def stream_avatar_to_disk(
    upload: UploadFile,
    dest_path: Path,
    *,
    max_bytes: int = MAX_AVATAR_BYTES,
) -> tuple[int, bytes]:
    """Stream upload to disk with a size cap; return size and header bytes."""
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    size = 0
    header = b""
    try:
        async with aiofiles.open(dest_path, "wb") as out:
            while True:
                chunk = await upload.read(64 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > max_bytes:
                    raise HTTPException(
                        status_code=413,
                        detail="Profile pictures must be 5 MB or smaller.",
                    )
                if len(header) < 16:
                    header += chunk[: 16 - len(header)]
                await out.write(chunk)
    except HTTPException:
        if dest_path.is_file():
            dest_path.unlink(missing_ok=True)
        raise
    except Exception:
        if dest_path.is_file():
            dest_path.unlink(missing_ok=True)
        raise
    return size, header


def new_stored_name(ext: str) -> str:
    return f"{uuid.uuid4().hex}{ext}"


def delete_avatar_file(rel_path: str | None) -> None:
    if not rel_path:
        return
    try:
        full = resolve_avatar_file(rel_path)
    except HTTPException:
        return
    if full.is_file():
        full.unlink(missing_ok=True)


def avatar_media_type(rel_path: str) -> str:
    guessed, _ = mimetypes.guess_type(rel_path)
    if guessed in ALLOWED_MIMES:
        return guessed
    return "application/octet-stream"
