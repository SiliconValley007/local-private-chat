"""Safe filesystem operations for chat attachments."""

from __future__ import annotations

from app import config


def delete_media_file(relative_path: str | None) -> bool:
    """Delete one file under MEDIA_ROOT, refusing paths that escape it."""

    if not relative_path:
        return False
    root = config.MEDIA_ROOT.resolve()
    full = (root / relative_path).resolve()
    try:
        full.relative_to(root)
    except ValueError:
        return False
    try:
        full.unlink(missing_ok=True)
        return True
    except OSError:
        return False


def delete_message_files(media_path: str | None, thumb_path: str | None) -> None:
    delete_media_file(media_path)
    delete_media_file(thumb_path)
