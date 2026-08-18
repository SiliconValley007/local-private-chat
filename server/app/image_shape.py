"""Pixel dimensions of stored media, read straight from file headers.

The chat transcript has to reserve a row's height *before* the picture in it has
been decoded. Without a size to reserve, a preview opens at a guessed shape and
then resizes once the bytes land, which shoves everything above it — a photo
scrolling into view is enough to make the whole list jump.

Sizes are parsed here rather than probed with an image library, because the
server ships with no imaging dependency and a header is a few dozen bytes: this
reads the first block of a file, not the picture.
"""

from __future__ import annotations

import struct
from pathlib import Path

from app import config

# Every format but JPEG declares its size in the opening bytes.
_FIRST_READ_BYTES = 16 * 1024

# JPEG keeps its frame header behind whatever Exif and colour profiles came
# first, so a second, larger read is allowed before giving up on one.
_MAX_HEADER_BYTES = 128 * 1024

# Exif orientations that swap the two axes. Decoders (including Flutter's) apply
# them, so a portrait photo stored as landscape has to be reported upright.
_TRANSPOSED_ORIENTATIONS = frozenset({5, 6, 7, 8})

# Keyed by (path, mtime, size): stored media never changes under its name, and
# the stat guards the case of a file replaced during a test or a restore.
_cache: dict[tuple[str, int, int], tuple[int, int] | None] = {}
_CACHE_LIMIT = 4096


def media_pixel_size(relative_path: str | None) -> tuple[int, int] | None:
    """Width and height of one file under MEDIA_ROOT, or None if unreadable."""

    if not relative_path:
        return None
    root = config.MEDIA_ROOT.resolve()
    full = (root / relative_path).resolve()
    try:
        full.relative_to(root)
        stat = full.stat()
    except (ValueError, OSError):
        return None

    key = (str(full), stat.st_mtime_ns, stat.st_size)
    if key in _cache:
        return _cache[key]
    size = _read_size(full)
    if len(_cache) >= _CACHE_LIMIT:
        _cache.clear()
    _cache[key] = size
    return size


def _read_size(path: Path) -> tuple[int, int] | None:
    try:
        with path.open("rb") as handle:
            head = handle.read(_FIRST_READ_BYTES)
            size = size_from_header(head)
            if size is None and len(head) == _FIRST_READ_BYTES:
                head += handle.read(_MAX_HEADER_BYTES - _FIRST_READ_BYTES)
                size = size_from_header(head)
    except OSError:
        return None
    return size


def size_from_header(head: bytes) -> tuple[int, int] | None:
    """Width and height from the opening bytes of an image, if recognised."""

    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return _png_size(head)
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return _gif_size(head)
    if head.startswith(b"RIFF") and head[8:12] == b"WEBP":
        return _webp_size(head)
    if head.startswith(b"\xff\xd8\xff"):
        return _jpeg_size(head)
    if head.startswith(b"BM"):
        return _bmp_size(head)
    return None


def _positive(width: int, height: int) -> tuple[int, int] | None:
    return (width, height) if width > 0 and height > 0 else None


def _png_size(head: bytes) -> tuple[int, int] | None:
    if len(head) < 24 or head[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", head[16:24])
    return _positive(width, height)


def _gif_size(head: bytes) -> tuple[int, int] | None:
    if len(head) < 10:
        return None
    width, height = struct.unpack("<HH", head[6:10])
    return _positive(width, height)


def _bmp_size(head: bytes) -> tuple[int, int] | None:
    if len(head) < 26:
        return None
    width, height = struct.unpack("<ii", head[18:26])
    # A negative height only means the rows are stored top-down.
    return _positive(width, abs(height))


def _webp_size(head: bytes) -> tuple[int, int] | None:
    chunk = head[12:16]
    if chunk == b"VP8X" and len(head) >= 30:
        width = int.from_bytes(head[24:27], "little") + 1
        height = int.from_bytes(head[27:30], "little") + 1
        return _positive(width, height)
    if chunk == b"VP8 " and len(head) >= 30 and head[23:26] == b"\x9d\x01\x2a":
        width = int.from_bytes(head[26:28], "little") & 0x3FFF
        height = int.from_bytes(head[28:30], "little") & 0x3FFF
        return _positive(width, height)
    if chunk == b"VP8L" and len(head) >= 25 and head[20] == 0x2F:
        bits = int.from_bytes(head[21:25], "little")
        width = (bits & 0x3FFF) + 1
        height = ((bits >> 14) & 0x3FFF) + 1
        return _positive(width, height)
    return None


def _jpeg_size(head: bytes) -> tuple[int, int] | None:
    """Walk JPEG segments to the frame header, noting Exif orientation on the way."""

    orientation: int | None = None
    at = 2
    end = len(head)
    while at + 4 <= end:
        if head[at] != 0xFF:
            at += 1
            continue
        marker = head[at + 1]
        # Fill bytes and standalone markers carry no length to skip.
        if marker in (0xFF, 0x01) or 0xD0 <= marker <= 0xD8:
            at += 1 if marker == 0xFF else 2
            continue
        if marker in (0xD9, 0xDA):
            return None
        length = int.from_bytes(head[at + 2 : at + 4], "big")
        if length < 2:
            return None
        payload = head[at + 4 : at + 2 + length]
        if marker == 0xE1 and orientation is None:
            orientation = _exif_orientation(payload)
        # Start-of-frame markers hold the size. C4/C8/CC are tables, not frames.
        elif 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if len(payload) < 5:
                return None
            height = int.from_bytes(payload[1:3], "big")
            width = int.from_bytes(payload[3:5], "big")
            if orientation in _TRANSPOSED_ORIENTATIONS:
                width, height = height, width
            return _positive(width, height)
        at += 2 + length
    return None


def _exif_orientation(payload: bytes) -> int | None:
    if not payload.startswith(b"Exif\x00\x00"):
        return None
    tiff = payload[6:]
    if tiff[:2] == b"II":
        endian = "little"
    elif tiff[:2] == b"MM":
        endian = "big"
    else:
        return None
    try:
        offset = int.from_bytes(tiff[4:8], endian)
        count = int.from_bytes(tiff[offset : offset + 2], endian)
        for index in range(count):
            entry = offset + 2 + index * 12
            if int.from_bytes(tiff[entry : entry + 2], endian) == 0x0112:
                return int.from_bytes(tiff[entry + 8 : entry + 10], endian)
    except (IndexError, ValueError):
        return None
    return None
