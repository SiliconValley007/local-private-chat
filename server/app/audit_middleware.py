"""Catch-all so no state-changing request goes unrecorded.

Every endpoint that matters writes its own detailed entry, with the message text
before and after. This exists for the ones that do not: a request that changes
something and describes itself to nobody still leaves a line saying who called
what, from where, and what the server answered.

Read-only requests are ignored — the log is about what was done, and one person
scrolling a chat would otherwise bury everything else.
"""

from __future__ import annotations

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

import app.db as db_module
from app import audit
from app.auth import decode_access_token

#: Methods that can change something.
WRITING_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})

#: Paths whose own entries are better than anything this could add, or which
#: would flood the log with one line per poll.
SKIP_PREFIXES = ("/api/admin/audit",)


def should_record(method: str, path: str, status_code: int, described: int) -> bool:
    """Is a catch-all entry warranted for this request?"""
    if method.upper() not in WRITING_METHODS:
        return False
    if described:
        return False
    if any(path.startswith(prefix) for prefix in SKIP_PREFIXES):
        return False
    # A request that was refused changed nothing, but an attempt to do something
    # forbidden is worth a line; a malformed one is not.
    return status_code < 500 and status_code not in {404, 422}


class AuditRequestMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        tokens = audit.begin_request(_client_ip(request))
        try:
            response = await call_next(request)
        except Exception:
            audit.end_request(tokens)
            raise
        described = audit.end_request(tokens)
        path = request.url.path
        if should_record(request.method, path, response.status_code, described):
            _write_fallback(request, path, response.status_code)
        return response


def _client_ip(request: Request) -> str | None:
    client = request.client
    return client.host if client is not None else None


def _write_fallback(request: Request, path: str, status_code: int) -> None:
    session_factory = getattr(db_module, "SessionLocal", None)
    if session_factory is None:
        return
    user_id, username = _actor_from_header(request.headers.get("authorization"))
    db = session_factory()
    try:
        audit.record(
            db,
            action=f"request.{request.method.lower()}",
            summary=f"{username or 'an unsigned-in caller'} called {request.method} {path}",
            actor_user_id=user_id,
            actor_username=username,
            details={"path": path, "status": status_code},
            ip=_client_ip(request),
        )
    finally:
        db.close()


def _actor_from_header(header: str | None) -> tuple[int | None, str | None]:
    """Names the caller from their bearer token, without touching the database."""
    if not header or not header.lower().startswith("bearer "):
        return None, None
    payload = decode_access_token(header.split(" ", 1)[1].strip())
    if not payload:
        return None, None
    try:
        user_id = int(payload.get("sub"))
    except (TypeError, ValueError):
        user_id = None
    username = payload.get("username")
    return user_id, username if isinstance(username, str) else None
