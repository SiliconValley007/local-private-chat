"""How large an attachment this server will accept right now.

Two separate things decide that, and they fail very differently:

* A configured cap, which is a policy — "no single file bigger than this".
* The free space left on the volume, which is a fact. A phone server that fills
  its own disk stops being a chat server at all, so a floor is kept clear rather
  than letting one video consume the last free byte.

The app asks for this before it starts sending, because the alternative is what
users actually hit: a two-minute upload of a 322 MB clip that is refused after
the first few megabytes, with nothing on screen to explain why.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class UploadAllowance:
    """The largest upload that may be accepted, and why it is capped there."""

    limit_bytes: int
    #: True when free space, not the configured cap, is the binding constraint.
    disk_bound: bool
    free_bytes: int

    @property
    def out_of_space(self) -> bool:
        return self.limit_bytes <= 0


def upload_allowance(
    *,
    max_bytes: int,
    free_bytes: int,
    floor_bytes: int,
) -> UploadAllowance:
    """Resolve the effective limit from the cap and the space actually left."""
    room = free_bytes - floor_bytes
    if room <= 0:
        return UploadAllowance(limit_bytes=0, disk_bound=True, free_bytes=free_bytes)
    if room < max_bytes:
        return UploadAllowance(
            limit_bytes=room, disk_bound=True, free_bytes=free_bytes
        )
    return UploadAllowance(
        limit_bytes=max_bytes, disk_bound=False, free_bytes=free_bytes
    )


def megabytes(value: int) -> int:
    """Whole megabytes, for messages people read."""
    return max(0, value) // (1024 * 1024)


def format_size(value: int) -> str:
    """A size in the unit that keeps it readable, never a rounded-down zero."""
    size = float(max(0, value))
    for unit in ("B", "KB", "MB"):
        if size < 1024 or unit == "MB":
            break
        size /= 1024
    if unit == "MB" and size >= 1024:
        return f"{size / 1024:.1f} GB"
    digits = 0 if size >= 10 or unit == "B" else 1
    return f"{size:.{digits}f} {unit}"


def too_large_detail(allowance: UploadAllowance, *, is_doodle: bool = False) -> str:
    """One sentence saying what the limit is and which limit it was."""
    if is_doodle:
        return "Drawings must be 2 MB or smaller."
    if allowance.out_of_space:
        return (
            "The server has no room left for attachments. Free some space on it "
            "and try again."
        )
    if allowance.disk_bound:
        return (
            f"The server only has room for {format_size(allowance.limit_bytes)} "
            "right now. Free some space on it, or send a smaller file."
        )
    return f"Attachments must be {format_size(allowance.limit_bytes)} or smaller."
