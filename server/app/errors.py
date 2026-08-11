"""Turn framework errors into plain sentences the chat app can show as-is.

FastAPI's default 422 body is a list of machine-readable dicts. Rendering that in
a phone UI produces noise like ``{type: value_error, loc: [body, username], ...}``,
so every error response here is normalised to ``{"detail": "<one sentence>"}``.
"""

from __future__ import annotations

import logging
from collections.abc import Mapping, Sequence
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("localchat.errors")

# Human labels for request fields, so messages read like "Group name is required."
FIELD_LABELS = {
    "body": "Message",
    "caption": "Caption",
    "ciphertext_b64": "Backup data",
    "client_id": "Message id",
    "display_name": "Display name",
    "file": "File",
    "member_ids": "Members",
    "message_id": "Message",
    "nonce_b64": "Backup data",
    "password": "Password",
    "platform": "Platform",
    "salt_b64": "Backup data",
    "title": "Group name",
    "token": "Device token",
    "type": "Type",
    "user_id": "User",
    "username": "Username",
}

STATUS_FALLBACKS = {
    400: "That request wasn't valid. Please check what you entered and try again.",
    401: "Your session has expired. Please sign in again.",
    403: "You don't have access to that.",
    404: "We couldn't find what you were looking for.",
    405: "That action isn't supported.",
    409: "That conflicts with something that already exists.",
    413: "That file is too large to send.",
    422: "Some of the details you entered aren't valid.",
    429: "Too many attempts. Please wait a moment and try again.",
    500: "Something went wrong on the server. Please try again.",
    503: "The server is busy right now. Please try again in a moment.",
}


LOCATION_KINDS = ("body", "query", "path", "header", "cookie")


def _field_label(loc: Sequence[Any]) -> str:
    """Best human name for the field a validation error points at.

    Pydantic's ``loc`` starts with where the value came from, e.g.
    ``("body", "username")``. Only that first entry is dropped, otherwise a field
    genuinely named ``body`` (the message text) would lose its own label.
    """
    parts = list(loc)
    if parts and isinstance(parts[0], str) and parts[0] in LOCATION_KINDS:
        parts = parts[1:]
    for part in reversed(parts):
        if isinstance(part, str):
            return FIELD_LABELS.get(part, part.replace("_", " ").capitalize())
    return "That value"


def _plural(count: Any, singular: str) -> str:
    """'1 character' / '6 characters', so messages don't read like a stack trace."""
    return f"{count} {singular}" if count == 1 else f"{count} {singular}s"


def _as_sentence(text: str) -> str:
    text = text.strip()
    if not text:
        return text
    if not text.endswith((".", "!", "?")):
        text += "."
    return text[0].upper() + text[1:]


UNREADABLE_REQUEST = (
    "The app sent a request the server couldn't read. "
    "Please update the app on both phones and try again."
)

# Error kinds whose message depends only on the field name.
SIMPLE_MESSAGES = {
    "missing": "{label} is required.",
    "int_parsing": "{label} must be a number.",
    "int_type": "{label} must be a number.",
    "float_parsing": "{label} must be a number.",
    "float_type": "{label} must be a number.",
    "decimal_parsing": "{label} must be a number.",
    "string_type": "{label} must be text.",
    "str_type": "{label} must be text.",
    "bool_parsing": "{label} must be yes or no.",
    "bool_type": "{label} must be yes or no.",
    "json_invalid": UNREADABLE_REQUEST,
    "model_type": UNREADABLE_REQUEST,
    "dict_type": UNREADABLE_REQUEST,
}

LENGTH_UNITS = {
    "string_too_short": "character",
    "string_too_long": "character",
    "too_short": "item",
    "too_long": "item",
}


def _describe_length(kind: str, label: str, ctx: Mapping[str, Any]) -> str:
    """Sentence for the min/max length family of pydantic errors."""
    unit = LENGTH_UNITS[kind]
    if kind in ("string_too_short", "too_short"):
        least = ctx.get("min_length", 1)
        if least == 1:
            return f"{label} cannot be empty."
        return f"{label} must be at least {_plural(least, unit)}."
    most = ctx.get("max_length")
    if most is None:
        return f"{label} is too long."
    return f"{label} can be at most {_plural(most, unit)}."


def _strip_pydantic_prefix(msg: str) -> str:
    """Drop the wrapper pydantic adds to messages raised by custom validators."""
    for prefix in ("Value error, ", "Assertion failed, "):
        if msg.startswith(prefix):
            return msg[len(prefix) :]
    return msg


def _describe(error: Mapping[str, Any]) -> str:
    """Render one pydantic error dict as a sentence for end users."""
    kind = str(error.get("type", ""))
    label = _field_label(error.get("loc") or ())

    template = SIMPLE_MESSAGES.get(kind)
    if template:
        return template.format(label=label)
    if kind in LENGTH_UNITS:
        return _describe_length(kind, label, error.get("ctx") or {})

    msg = _strip_pydantic_prefix(str(error.get("msg", "")).strip())
    if not msg:
        return f"{label} isn't valid."
    # Custom validators usually name the field already; don't repeat it.
    if label.lower() in msg.lower():
        return _as_sentence(msg)
    return _as_sentence(f"{label}: {msg}")


def humanize_validation_errors(errors: Sequence[Mapping[str, Any]]) -> str:
    """Join all validation problems into one short, readable message."""
    sentences: list[str] = []
    for error in errors:
        sentence = _describe(error)
        if sentence and sentence not in sentences:
            sentences.append(sentence)
    if not sentences:
        return STATUS_FALLBACKS[422]
    return " ".join(sentences[:3])


def friendly_detail(status_code: int, detail: Any) -> str:
    """Normalise any exception detail into a single readable sentence."""
    if isinstance(detail, str) and detail.strip():
        return _as_sentence(detail)
    if isinstance(detail, Sequence) and not isinstance(detail, (str, bytes)):
        dict_errors = [item for item in detail if isinstance(item, Mapping) and "loc" in item]
        if dict_errors:
            return humanize_validation_errors(dict_errors)
    return STATUS_FALLBACKS.get(status_code, STATUS_FALLBACKS[500])


def install_error_handlers(app: FastAPI) -> None:
    """Make every error response a ``{"detail": "<sentence>"}`` payload."""

    @app.exception_handler(RequestValidationError)
    async def _on_validation_error(_request: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content={"detail": humanize_validation_errors(exc.errors())},
        )

    @app.exception_handler(StarletteHTTPException)
    async def _on_http_error(_request: Request, exc: StarletteHTTPException) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"detail": friendly_detail(exc.status_code, exc.detail)},
            headers=getattr(exc, "headers", None),
        )

    @app.exception_handler(Exception)
    async def _on_unexpected_error(request: Request, exc: Exception) -> JSONResponse:
        # The real cause stays in the server log; clients get a calm sentence.
        log.exception("Unhandled error on %s %s", request.method, request.url.path, exc_info=exc)
        return JSONResponse(status_code=500, content={"detail": STATUS_FALLBACKS[500]})
