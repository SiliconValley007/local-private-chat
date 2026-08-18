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


@asynccontextmanager
async def lifespan(_app: FastAPI):
    ensure_dirs()
    init_db()
    # Firebase stays lazy: init_firebase() runs on the first push so Termux
    # installs without firebase-admin never pay for the grpc import.

    async def housekeeping() -> None:
        while True:
            await asyncio.sleep(60)
            call_registry.purge_expired()
            nudge_limiter.prune_stale()
            doodle_limiter.prune_stale()

    task = asyncio.create_task(housekeeping())
    try:
        yield
    finally:
        task.cancel()
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
