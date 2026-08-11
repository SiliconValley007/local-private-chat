"""Encrypted backup storage (ciphertext only — server cannot read chats)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db import get_db
from app.deps import get_current_user
from app.models import EncryptedBackup, User, utcnow

router = APIRouter(prefix="/api/backup", tags=["backup"])


class BackupPayload(BaseModel):
    ciphertext_b64: str = Field(min_length=16)
    salt_b64: str = Field(min_length=8)
    nonce_b64: str = Field(min_length=8)


class BackupResponse(BaseModel):
    ciphertext_b64: str
    salt_b64: str
    nonce_b64: str
    updated_at: str


@router.put("")
def put_backup(
    body: BackupPayload,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> dict:
    row = db.get(EncryptedBackup, current.id)
    if row is None:
        row = EncryptedBackup(user_id=current.id, ciphertext_b64="", salt_b64="", nonce_b64="")
        db.add(row)
    row.ciphertext_b64 = body.ciphertext_b64
    row.salt_b64 = body.salt_b64
    row.nonce_b64 = body.nonce_b64
    row.updated_at = utcnow()
    db.commit()
    return {"ok": True, "updated_at": row.updated_at.isoformat()}


@router.get("", response_model=BackupResponse)
def get_backup(
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> BackupResponse:
    row = db.get(EncryptedBackup, current.id)
    if row is None:
        raise HTTPException(
            status_code=404,
            detail="No backup was found for this account yet.",
        )
    return BackupResponse(
        ciphertext_b64=row.ciphertext_b64,
        salt_b64=row.salt_b64,
        nonce_b64=row.nonce_b64,
        updated_at=row.updated_at.isoformat(),
    )
