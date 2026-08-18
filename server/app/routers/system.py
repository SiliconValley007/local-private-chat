"""Authenticated information about the machine hosting Local Chat."""

from __future__ import annotations

import shutil
from typing import Annotated

from fastapi import APIRouter, Depends

from app import config, host_info
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
