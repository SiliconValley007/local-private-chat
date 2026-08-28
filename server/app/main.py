"""FastAPI application entry."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.audit_middleware import AuditRequestMiddleware
from app.call_sessions import call_registry
from app.compression import CompressJsonMiddleware
from app.config import LOW_MEMORY, ensure_dirs
from app.db import init_db
from app.errors import install_error_handlers
from app.rate_limit import doodle_limiter, nudge_limiter
from app.routers import (
    admin,
    auth,
    backup,
    calls,
    conversations,
    devices,
    media,
    messages,
    system,
    users,
)
from app.ws import router as ws_router


def _warn_when_no_admin() -> None:
    """A closed gate plus no admin means nobody can sign in; say so loudly."""
    from app.admin import admin_username
    from app.db import SessionLocal

    with SessionLocal() as db:
        if admin_username(db) is not None:
            return
    print(
        "  No admin account is appointed, so no one can sign in until the "
        "check above passes. Appoint one with 'python run.py set-admin <name>'."
    )


def _report_first_membership_check() -> None:
    from app.tailscale_membership import last_poll_error

    reason = last_poll_error()
    if not reason:
        print("  Tailnet membership verified.")
        return
    print(f"  Tailnet membership NOT verified: {reason}")
    print(
        "  Chat is paused for everyone except the admin. Run "
        "'python run.py tailscale-check' to fix it."
    )
    _warn_when_no_admin()


async def membership_poller() -> None:
    """Verify tailnet membership at once, then on the configured interval.

    The first check cannot wait for a housekeeping tick: while no snapshot
    exists the server fails closed, so a fresh start would otherwise refuse
    every sign-in for a full minute.
    """
    from app.config import TAILSCALE_POLL_SECONDS
    from app.tailscale_membership import membership_configured, poll_once

    if not membership_configured():
        return
    print("Tailnet membership: OAuth configured, checking with Tailscale...")
    first = True
    while True:
        try:
            await poll_once()
        except Exception:  # pylint: disable=broad-exception-caught
            pass
        if first:
            first = False
            _report_first_membership_check()
        await asyncio.sleep(max(15, TAILSCALE_POLL_SECONDS))


@asynccontextmanager
async def lifespan(_app: FastAPI):
    ensure_dirs()
    init_db()
    # Firebase stays lazy: init_firebase() runs on the first push so Termux
    # installs without firebase-admin never pay for the grpc import.

    async def housekeeping() -> None:
        from app.db import SessionLocal
        from app.media_retention import expire_due_media
        from app.upload_sessions import purge_stale
        from app.config import MEDIA_ROOT, UPLOAD_SESSION_TTL_SECONDS

        while True:
            await asyncio.sleep(60)
            call_registry.purge_expired()
            nudge_limiter.prune_stale()
            doodle_limiter.prune_stale()
            session = SessionLocal()
            try:
                await expire_due_media(session)
            except Exception:
                pass
            finally:
                session.close()
            try:
                purge_stale(MEDIA_ROOT, ttl_seconds=UPLOAD_SESSION_TTL_SECONDS)
            except Exception:
                pass

    tasks = [
        asyncio.create_task(housekeeping()),
        asyncio.create_task(membership_poller()),
    ]
    try:
        yield
    finally:
        for task in tasks:
            task.cancel()
        for task in tasks:
            try:
                await task
            except asyncio.CancelledError:
                pass


app = FastAPI(title="Local Chat", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Shrinks the JSON the app fetches most often — the inbox and message pages —
# so chatting works on a link with very little bandwidth to spare. On a phone
# server the threshold is higher: tiny responses are not worth the RAM spike
# of buffering them for gzip.
app.add_middleware(
    CompressJsonMiddleware,
    minimum_size=2048 if LOW_MEMORY else 700,
)

# Added last so it wraps outermost: it has to see the status code every other
# layer settled on, and hold the audit scope for the whole request.
app.add_middleware(AuditRequestMiddleware)

install_error_handlers(app)

app.include_router(auth.router)
app.include_router(users.router)
app.include_router(conversations.router)
app.include_router(messages.router)
app.include_router(media.router)
app.include_router(devices.router)
app.include_router(calls.router)
app.include_router(backup.router)
app.include_router(system.router)
app.include_router(admin.router)
app.include_router(ws_router)


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "service": "local-chat"}
