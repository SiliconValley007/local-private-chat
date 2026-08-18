"""REST helpers for call delivery when the WebSocket is not yet up."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.call_sessions import call_registry
from app.db import get_db
from app.deps import get_current_user
from app.models import User
from app.realtime import events
from app.realtime.hub import hub
from app.services import get_membership, member_user_ids

router = APIRouter(prefix="/api/calls", tags=["calls"])


class RingingRequest(BaseModel):
    call_id: str = Field(min_length=1, max_length=64)


@router.get("/pending")
async def list_pending_calls(
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> dict:
    """Return unanswered invites for this user (callee recovery after app open)."""
    pending = call_registry.pending_for_user(current.id)
    visible: list[dict] = []
    for record in pending:
        if get_membership(db, record.conversation_id, current.id) is None:
            continue
        payload = record.to_pending_dict()
        caller = db.get(User, record.caller_id)
        if caller is not None:
            payload["caller_name"] = caller.display_name
            payload["caller_username"] = caller.username
        visible.append(payload)
    return {"calls": visible}


@router.post("/ringing")
async def acknowledge_ringing(
    body: RingingRequest,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
) -> dict:
    """Callee confirms the invite was displayed (REST path for background wake-ups)."""
    record = call_registry.get(body.call_id)
    if record is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Call not found.")
    if get_membership(db, record.conversation_id, current.id) is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not a member.")
    updated = call_registry.mark_ringing(body.call_id, current.id)
    if updated is None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Cannot ring.")
    relay = {
        "conversation_id": updated.conversation_id,
        "call_id": updated.call_id,
        "from_user_id": current.id,
        "media": updated.media,
    }
    await hub.send_to_user(
        updated.caller_id,
        events.event_call_relay("call.ringing", relay),
    )
    return {"ok": True}
