"""Authenticated information about the machine hosting Local Chat."""

from __future__ import annotations

import shutil
from typing import Annotated

from fastapi import APIRouter, Depends

from app import config
from app.deps import get_current_user
from app.models import User

router = APIRouter(prefix="/api/system", tags=["system"])


@router.get("/storage")
def server_storage(
    _current: Annotated[User, Depends(get_current_user)],
) -> dict[str, int]:
    """Return space on the volume where uploaded media is stored.

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
