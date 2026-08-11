"""Device token registration for FCM."""

from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_current_user
from app.models import DeviceToken, User, utcnow

router = APIRouter(prefix="/api/devices", tags=["devices"])


class RegisterDeviceRequest(BaseModel):
    token: str = Field(min_length=10, max_length=512)
    platform: str = "android"


@router.post("")
def register_device(
    body: RegisterDeviceRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> dict:
    existing = db.scalar(select(DeviceToken).where(DeviceToken.token == body.token))
    if existing:
        existing.user_id = current.id
        existing.platform = body.platform[:32]
        existing.updated_at = utcnow()
    else:
        db.add(
            DeviceToken(
                user_id=current.id,
                token=body.token,
                platform=body.platform[:32],
            )
        )
    db.commit()
    return {"ok": True}


@router.delete("")
def unregister_device(
    body: RegisterDeviceRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> dict:
    row = db.scalar(
        select(DeviceToken).where(
            DeviceToken.token == body.token,
            DeviceToken.user_id == current.id,
        )
    )
    if row:
        db.delete(row)
        db.commit()
    return {"ok": True}
