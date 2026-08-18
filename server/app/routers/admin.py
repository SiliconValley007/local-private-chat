"""Admin-only view of the activity log, force-logout, and device trust."""

from __future__ import annotations

import json
from datetime import timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, HTTPException, Query, status
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app import admin as admin_rules
from app import audit
from app.db import get_db
from app.deps import get_current_user
from app.models import AuditEvent, User, utcnow
from app.realtime.hub import hub
from app.schemas import (
    AdminStatusOut,
    AuditEventOut,
    AuditSummaryOut,
    ForceLogoutOut,
    OnlineUserOut,
    SetAdminDeviceRequest,
    SetAdminRequest,
)
from app.sessions import bump_token_version

router = APIRouter(prefix="/api/admin", tags=["admin"])

#: One screenful at a time, with the same before_id cursor the rest of the API
#: uses, so a long history is walked rather than loaded.
DEFAULT_PAGE = 50
MAX_PAGE = 200


def _device_id(
    x_device_id: Annotated[str | None, Header(alias="X-Device-Id")] = None,
) -> str | None:
    cleaned = (x_device_id or "").strip()
    return cleaned or None


@router.get("/status", response_model=AdminStatusOut)
def admin_status(
    current: Annotated[User, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
    device_id: Annotated[str | None, Depends(_device_id)],
) -> AdminStatusOut:
    """Who the admin is, and whether this account can be or appoint one.

    Answered for any signed-in account, because the app has to know whether to
    offer the activity log at all before it can ask for it.
    """

    return AdminStatusOut(**admin_rules.status_fields(db, current, device_id=device_id))


@router.put("/username", response_model=AdminStatusOut)
def set_admin(
    payload: SetAdminRequest,
    current: Annotated[User, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
    device_id: Annotated[str | None, Depends(_device_id)],
) -> AdminStatusOut:
    """Appoints the admin account. Only an unclaimed role, or the admin, may."""
    if not admin_rules.may_claim(db, current):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "The server's admin was set on the server itself and cannot be "
                "changed from the app."
                if admin_rules.admin_is_locked()
                else admin_rules.NOT_ADMIN_DETAIL
            ),
        )
    previous = admin_rules.stored_admin_username(db)
    appointed = admin_rules.set_admin_username(
        db, username=payload.username, actor=current
    )
    audit.record(
        db,
        action="admin.designated",
        summary=f"{current.username} made {appointed} the server admin",
        actor=current,
        before_text=previous,
        after_text=appointed,
    )
    return AdminStatusOut(**admin_rules.status_fields(db, current, device_id=device_id))


@router.put("/device", response_model=AdminStatusOut)
def set_admin_device(
    payload: SetAdminDeviceRequest,
    current: Annotated[User, Depends(admin_rules.require_admin)],
    db: Annotated[Session, Depends(get_db)],
    device_id: Annotated[str | None, Depends(_device_id)],
) -> AdminStatusOut:
    """Trust this phone for the activity log, or clear the pin entirely.

    Clearing without a replacement means any install of the admin account can
    open the log again until one of them re-trusts itself.
    """
    if payload.clear:
        previous = admin_rules.stored_admin_device_id(db)
        admin_rules.set_admin_device_id(db, device_id=None, actor=current)
        audit.record(
            db,
            action="admin.device_cleared",
            summary=f"{current.username} cleared the trusted admin device",
            actor=current,
            before_text=previous,
        )
    else:
        if not device_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="This phone has no device id to trust.",
            )
        previous = admin_rules.stored_admin_device_id(db)
        if previous and previous != device_id:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=admin_rules.WRONG_DEVICE_DETAIL,
            )
        admin_rules.set_admin_device_id(db, device_id=device_id, actor=current)
        audit.record(
            db,
            action="admin.device_trusted",
            summary=f"{current.username} trusted this phone for the activity log",
            actor=current,
            before_text=previous,
            after_text=device_id[-8:],
        )
    return AdminStatusOut(**admin_rules.status_fields(db, current, device_id=device_id))


@router.get("/online", response_model=list[OnlineUserOut])
def list_online_users(
    _admin: Annotated[User, Depends(admin_rules.require_admin_for_audit)],
    db: Annotated[Session, Depends(get_db)],
) -> list[OnlineUserOut]:
    """Who is connected right now, for the force-logout picker."""
    online_ids = sorted(hub.online_user_ids())
    if not online_ids:
        return []
    users = list(db.scalars(select(User).where(User.id.in_(online_ids))).all())
    by_id = {u.id: u for u in users}
    return [
        OnlineUserOut(
            id=uid,
            username=by_id[uid].username if uid in by_id else f"user-{uid}",
            display_name=by_id[uid].display_name if uid in by_id else "",
            is_online=True,
        )
        for uid in online_ids
        if uid in by_id
    ]


@router.post("/users/{user_id}/force-logout", response_model=ForceLogoutOut)
async def force_logout_user(
    user_id: int,
    admin: Annotated[User, Depends(admin_rules.require_admin_for_audit)],
    db: Annotated[Session, Depends(get_db)],
) -> ForceLogoutOut:
    """Invalidate every JWT for [user_id] and close their live sockets."""
    target = db.get(User, user_id)
    if target is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="That account is no longer on this server.",
        )
    if target.id == admin.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You cannot force-logout your own signed-in session from here.",
        )
    version = bump_token_version(db, target)
    closed = await hub.disconnect_user(target.id)
    audit.record(
        db,
        action="admin.force_logout",
        summary=f"{admin.username} signed @{target.username} out of every device",
        actor=admin,
        target_user_id=target.id,
        details={"token_version": version, "sockets_closed": closed},
    )
    return ForceLogoutOut(
        user_id=target.id,
        username=target.username,
        token_version=version,
        sockets_closed=closed,
    )


@router.get("/audit", response_model=list[AuditEventOut])
def list_audit_events(
    _admin: Annotated[User, Depends(admin_rules.require_admin_for_audit)],
    db: Annotated[Session, Depends(get_db)],
    before_id: int | None = None,
    limit: int = Query(DEFAULT_PAGE, ge=1, le=MAX_PAGE),
    category: str | None = None,
    action: str | None = None,
    actor: str | None = None,
    conversation_id: int | None = None,
    message_id: int | None = None,
    q: str | None = None,
) -> list[AuditEventOut]:
    """Newest first, filtered the same way the app's chips and search box are."""
    stmt = select(AuditEvent).order_by(AuditEvent.id.desc()).limit(limit)
    if before_id:
        stmt = stmt.where(AuditEvent.id < before_id)
    if action:
        stmt = stmt.where(AuditEvent.action == action)
    if category and category != "all":
        wanted = audit.actions_in(category)
        stmt = stmt.where(AuditEvent.action.in_(wanted or ["__none__"]))
    if actor:
        stmt = stmt.where(func.lower(AuditEvent.actor_username) == actor.casefold())
    if conversation_id:
        stmt = stmt.where(AuditEvent.conversation_id == conversation_id)
    if message_id:
        stmt = stmt.where(AuditEvent.message_id == message_id)
    if q:
        needle = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                AuditEvent.summary.ilike(needle),
                AuditEvent.before_text.ilike(needle),
                AuditEvent.after_text.ilike(needle),
                AuditEvent.details.ilike(needle),
                AuditEvent.actor_username.ilike(needle),
            )
        )
    return [_event_out(row) for row in db.scalars(stmt).all()]


@router.get("/audit/summary", response_model=AuditSummaryOut)
def audit_summary(
    _admin: Annotated[User, Depends(admin_rules.require_admin_for_audit)],
    db: Annotated[Session, Depends(get_db)],
) -> AuditSummaryOut:
    """Counts for the header of the log screen."""
    total = db.scalar(select(func.count()).select_from(AuditEvent)) or 0
    since = utcnow() - timedelta(days=1)
    today = (
        db.scalar(
            select(func.count()).select_from(AuditEvent).where(AuditEvent.at >= since)
        )
        or 0
    )
    edits = _count_in(db, "edits")
    deletions = _count_in(db, "deletions")
    oldest = db.scalar(select(func.min(AuditEvent.at)))
    return AuditSummaryOut(
        total=total,
        last_day=today,
        edits=edits,
        deletions=deletions,
        oldest_at=oldest,
    )


def _count_in(db: Session, category: str) -> int:
    wanted = audit.actions_in(category)
    if not wanted:
        return 0
    return (
        db.scalar(
            select(func.count())
            .select_from(AuditEvent)
            .where(AuditEvent.action.in_(wanted))
        )
        or 0
    )


def _event_out(row: AuditEvent) -> AuditEventOut:
    return AuditEventOut(
        id=row.id,
        at=row.at,
        action=row.action,
        category=audit.category_for(row.action),
        actor_user_id=row.actor_user_id,
        actor_username=row.actor_username,
        conversation_id=row.conversation_id,
        message_id=row.message_id,
        target_user_id=row.target_user_id,
        summary=row.summary,
        before_text=row.before_text,
        after_text=row.after_text,
        details=_details(row.details),
        ip=row.ip,
    )


def _details(raw: str | None) -> dict[str, Any] | None:
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        return {"raw": raw}
    return parsed if isinstance(parsed, dict) else {"value": parsed}
