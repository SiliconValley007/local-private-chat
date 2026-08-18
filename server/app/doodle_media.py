"""Validate persistent doodle PNG uploads (type=doodle messages)."""

from __future__ import annotations

from fastapi import HTTPException

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_DOODLE_BYTES = 2 * 1024 * 1024
MAX_DOODLE_EDGE = 2048

ALLOWED_DOODLE_MIMES = frozenset(
    {
        "image/png",
        "",
        "application/octet-stream",
        "binary/octet-stream",
    }
)


def parse_png_dimensions(header: bytes) -> tuple[int, int]:
    """Read width/height from the PNG IHDR chunk."""
    if len(header) < 24 or header[:8] != PNG_SIGNATURE:
        raise HTTPException(
            status_code=400,
            detail="Drawings must be transparent PNG images.",
        )
    width = int.from_bytes(header[16:20], "big")
    height = int.from_bytes(header[20:24], "big")
    return width, height


def validate_doodle_upload(
    *,
    header: bytes,
    size: int,
    content_type: str | None,
    filename: str,
) -> None:
    """Strict PNG checks for doodle messages."""
    mime = (content_type or "").split(";", 1)[0].strip().lower()
    if mime not in ALLOWED_DOODLE_MIMES:
        raise HTTPException(
            status_code=400,
            detail="Drawings must be PNG images.",
        )
    name = (filename or "").lower()
    if name and not name.endswith(".png"):
        raise HTTPException(
            status_code=400,
            detail="Drawings must use a .png file name.",
        )
    if size <= 0:
        raise HTTPException(status_code=400, detail="The drawing file is empty.")
    if size > MAX_DOODLE_BYTES:
        raise HTTPException(
            status_code=413,
            detail="Drawings must be 2 MB or smaller.",
        )
    if not header.startswith(PNG_SIGNATURE):
        raise HTTPException(
            status_code=400,
            detail="Drawings must be transparent PNG images.",
        )
    width, height = parse_png_dimensions(header)
    if width <= 0 or height <= 0:
        raise HTTPException(status_code=400, detail="The drawing image is invalid.")
    if width > MAX_DOODLE_EDGE or height > MAX_DOODLE_EDGE:
        raise HTTPException(
            status_code=400,
            detail=f"Drawings must be at most {MAX_DOODLE_EDGE}px on each side.",
        )
