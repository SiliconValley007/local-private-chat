"""Conversation wallpaper storage, validation, and safe path resolution."""

from __future__ import annotations

import mimetypes
import uuid
import zlib
from pathlib import Path

import aiofiles
from fastapi import HTTPException, UploadFile

from app.config import MEDIA_ROOT

WALLPAPER_DIR = "wallpapers"
MAX_WALLPAPER_BYTES = 3 * 1024 * 1024

ALLOWED_MIMES = frozenset(
    {
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp",
    }
)
ALLOWED_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png", ".gif", ".webp"})

GENERIC_MIMES = frozenset({"", "application/octet-stream", "binary/octet-stream"})

_MAGIC_CHECKS: tuple[tuple[bytes, int], ...] = (
    (b"\xff\xd8\xff", 0),
    (b"\x89PNG\r\n\x1a\n", 0),
    (b"GIF87a", 0),
    (b"GIF89a", 0),
    (b"RIFF", 0),
)


def wallpaper_version_for(conversation) -> int | None:
    if not conversation.wallpaper_path:
        return None
    return zlib.crc32(conversation.wallpaper_path.encode("utf-8")) & 0xFFFFFFFF


def has_wallpaper(conversation) -> bool:
    return bool(conversation.wallpaper_path)


def _wallpapers_root() -> Path:
    return (MEDIA_ROOT / WALLPAPER_DIR).resolve()


def wallpaper_rel_path(conversation_id: int, stored_name: str) -> str:
    return f"{WALLPAPER_DIR}/{conversation_id}/{stored_name}"


def resolve_wallpaper_file(rel_path: str) -> Path:
    full = (MEDIA_ROOT / rel_path).resolve()
    root = _wallpapers_root()
    if not str(full).startswith(str(root)):
        raise HTTPException(status_code=400, detail="Wallpaper is not available.")
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
    mime = (content_type or "").split(";", 1)[0].strip().lower()
    if mime not in ALLOWED_MIMES and mime not in GENERIC_MIMES:
        raise HTTPException(status_code=400, detail="That image format is not supported.")
    ext = extension_for(filename, mime)
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="That image format is not supported.")
    return ext


async def stream_wallpaper_to_disk(
    upload: UploadFile,
    dest_path: Path,
    *,
    max_bytes: int = MAX_WALLPAPER_BYTES,
) -> tuple[int, bytes]:
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
                        detail="Wallpaper images must be 3 MB or smaller.",
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


def delete_wallpaper_file(rel_path: str | None) -> None:
    if not rel_path:
        return
    try:
        full = resolve_wallpaper_file(rel_path)
    except HTTPException:
        return
    if full.is_file():
        full.unlink(missing_ok=True)


def wallpaper_media_type(rel_path: str) -> str:
    guessed, _ = mimetypes.guess_type(rel_path)
    if guessed in ALLOWED_MIMES:
        return guessed
    return "application/octet-stream"
