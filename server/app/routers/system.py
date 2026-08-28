"""Authenticated information about the machine hosting Local Chat."""

from __future__ import annotations

import shutil
from typing import Annotated

from fastapi import APIRouter, Depends

from sqlalchemy.orm import Session

from app import config, host_info
from app.db import get_db
from app.deps import get_current_user
from app.doodle_media import MAX_DOODLE_BYTES
from app.models import User
from app.routers.media import media_allowance

router = APIRouter(prefix="/api/system", tags=["system"])


def _storage() -> dict[str, int]:
    """Space on the volume where uploaded media is stored.

    ``disk_usage`` works on Windows, Linux, and Android/Termux. Measuring
    MEDIA_ROOT (rather than the process working directory) ensures the value
    describes the disk that will actually receive the next attachment.
    """

    usage = shutil.disk_usage(config.MEDIA_ROOT)
    return {
        "total_bytes": usage.total,
        "used_bytes": usage.used,
        "free_bytes": usage.free,
    }


@router.get("/storage")
def server_storage(
    _current: Annotated[User, Depends(get_current_user)],
) -> dict[str, int]:
    """Return space on the volume where uploaded media is stored."""

    return _storage()


@router.get("/limits")
def upload_limits(
    _current: Annotated[User, Depends(get_current_user)],
) -> dict[str, int | bool]:
    """What this server will accept as one attachment, right now.

    The app asks before it starts sending so an oversized file is refused in the
    moment, on the phone, with its real size named — rather than after minutes
    of uploading into a cap it could not see.
    """

    allowance = media_allowance()
    return {
        "max_media_bytes": allowance.limit_bytes,
        "configured_max_media_bytes": config.MAX_MEDIA_BYTES,
        "max_doodle_bytes": MAX_DOODLE_BYTES,
        "free_bytes": allowance.free_bytes,
        "disk_bound": allowance.disk_bound,
    }


@router.get("/media-policy")
def media_policy(
    db: Annotated[Session, Depends(get_db)],
    current: Annotated[User, Depends(get_current_user)],
) -> dict[str, int | None]:
    """How long attachments stay on this server unless someone keeps them."""
    from app.media_retention import load_policy

    policy = load_policy(db)
    return {
        "default_days": policy.default_days,
        "min_days": policy.min_days,
        "max_days": policy.max_days,
        "my_days": current.media_ttl_days,
    }


@router.get("/info")
def server_info(
    _current: Annotated[User, Depends(get_current_user)],
) -> dict[str, object]:
    """Health of the host serving this chat: RAM, disk, battery, uptime.

    The usual host is a spare Android phone under Termux, where the server dies
    quietly if RAM runs out or the battery drains. This is read on demand only —
    no polling — so checking it costs one request and a few small kernel reads.
    """

    return {
        "host": {**host_info.describe_host(), "low_memory": config.LOW_MEMORY},
        "memory": host_info.read_memory(),
        "storage": _storage(),
        "battery": host_info.read_battery(),
        "uptime": {
            "server_seconds": host_info.process_uptime_seconds(),
            "host_seconds": host_info.host_uptime_seconds(),
        },
    }
