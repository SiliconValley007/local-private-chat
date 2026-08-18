"""FastAPI application entry."""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.compression import CompressJsonMiddleware
from app.config import ensure_dirs
from app.db import init_db
from app.errors import install_error_handlers
from app.routers import (
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
from app.fcm import init_firebase


@asynccontextmanager
async def lifespan(_app: FastAPI):
    ensure_dirs()
    init_db()
    init_firebase()
    yield


app = FastAPI(title="Local Chat", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Shrinks the JSON the app fetches most often — the inbox and message pages —
# so chatting works on a link with very little bandwidth to spare.
app.add_middleware(CompressJsonMiddleware)

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
app.include_router(ws_router)


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "service": "local-chat"}
