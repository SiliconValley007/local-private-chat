"""Application configuration — paths, JWT, host/port."""

from __future__ import annotations

import os
import secrets
import sys
from pathlib import Path


def resolve_app_dir(
    *,
    module_file: str | Path = __file__,
    executable: str | Path | None = None,
    frozen: bool | None = None,
) -> Path:
    """Return the durable server folder in source and PyInstaller builds."""
    is_frozen = getattr(sys, "frozen", False) if frozen is None else frozen
    if is_frozen:
        binary = executable if executable is not None else sys.executable
        return Path(binary).resolve().parent
    return Path(module_file).resolve().parent.parent


# Source: server/. Frozen Windows build: folder containing LocalChatServer.exe.
# `_internal` is replaceable application code and must never hold user data.
APP_DIR = resolve_app_dir()
MEDIA_ROOT = APP_DIR / "media"
DATA_DIR = APP_DIR / "data"
DATABASE_PATH = DATA_DIR / "chat.db"
DATABASE_URL = f"sqlite:///{DATABASE_PATH.as_posix()}"

HOST = os.environ.get("LOCALCHAT_HOST", "0.0.0.0")  # all interfaces: LAN + Tailscale
PORT = int(os.environ.get("LOCALCHAT_PORT", "8000"))
ACCESS_TOKEN_EXPIRE_DAYS = int(os.environ.get("LOCALCHAT_TOKEN_DAYS", "30"))
JWT_ALGORITHM = "HS256"


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


# Termux / phone servers set LOCALCHAT_LOW_MEMORY=1 so SQLite, uploads, and
# uvicorn stay inside a few hundred MB of free RAM.
LOW_MEMORY = _truthy(os.environ.get("LOCALCHAT_LOW_MEMORY"))

# Negative PRAGMA cache_size is kilobytes. 2 MB on a phone, 8 MB elsewhere.
SQLITE_CACHE_KB = int(
    os.environ.get("LOCALCHAT_SQLITE_CACHE_KB", "2048" if LOW_MEMORY else "8192")
)

# Caps a single chat attachment. Uploads are streamed to disk in
# UPLOAD_CHUNK_BYTES pieces and never held in memory, so RAM is not what this
# protects — free space is, and MEDIA_DISK_FLOOR_BYTES does that far more
# precisely. The old 25 MB phone default silently refused ordinary phone video:
# two minutes from a modern camera is a few hundred megabytes.
MAX_MEDIA_BYTES = int(
    os.environ.get(
        "LOCALCHAT_MAX_MEDIA_MB",
        "512" if LOW_MEMORY else "1024",
    )
) * 1024 * 1024

# Space kept clear on the media volume whatever the cap says, so one large
# attachment can never leave the host with no room for the database, a log, or
# the next message.
MEDIA_DISK_FLOOR_BYTES = int(
    os.environ.get("LOCALCHAT_MEDIA_DISK_FLOOR_MB", "1024")
) * 1024 * 1024

# Smaller chunks keep the peak buffer tiny while streaming to disk.
UPLOAD_CHUNK_BYTES = int(
    os.environ.get(
        "LOCALCHAT_UPLOAD_CHUNK_KB",
        "64" if LOW_MEMORY else "256",
    )
) * 1024

# Size of the pieces a phone sends a large attachment in, so an interrupted
# send continues from the last piece instead of starting again. Big enough that
# a 500 MB file is a few hundred requests, small enough that losing one costs
# little.
RESUMABLE_CHUNK_BYTES = int(
    os.environ.get(
        "LOCALCHAT_RESUMABLE_CHUNK_KB",
        "2048" if LOW_MEMORY else "4096",
    )
) * 1024

# How long a half-finished upload is kept so it can be continued. Long enough
# to survive a night with no signal; short enough that abandoned bytes are not
# left on a phone-sized disk for good.
UPLOAD_SESSION_TTL_SECONDS = int(
    os.environ.get("LOCALCHAT_UPLOAD_SESSION_TTL_HOURS", "24")
) * 3600

#: Below this, ordinary browsing starts getting 503s instead of thumbnails.
MIN_SAFE_CONCURRENCY = 32


def concurrency_limit(env_value: str | None, *, low_memory: bool) -> int:
    """Resolve uvicorn's ``limit_concurrency``; 0 means no limit.

    This is a safety valve, not a queue: uvicorn answers 503 and drops anything
    past the limit. One screen legitimately opens dozens of sockets at once (the
    request itself, a thumbnail per row, avatars, the health poll, the
    WebSocket), so a low value shows up as missing media and transcripts that
    never load. An explicit override is honoured as given; the default only has
    to stay clear of a normal burst.
    """

    if env_value and env_value.strip():
        try:
            return max(0, int(env_value))
        except ValueError:
            pass
    return 64 if low_memory else 0


MAX_CONCURRENCY = concurrency_limit(
    os.environ.get("LOCALCHAT_MAX_CONCURRENCY"), low_memory=LOW_MEMORY
)

# Low-memory mode silences the access log; set LOCALCHAT_ACCESS_LOG=1 to get it
# back while diagnosing what the app actually requested and what it got.
ACCESS_LOG = _truthy(os.environ.get("LOCALCHAT_ACCESS_LOG"))


def _load_jwt_secret() -> str:
    """Resolve JWT secret: env LOCALCHAT_JWT_SECRET, else jwt_secret.txt, else generate+persist."""
    env = os.environ.get("LOCALCHAT_JWT_SECRET")
    if env:
        return env
    secret_path = APP_DIR / "jwt_secret.txt"
    if secret_path.is_file():
        text = secret_path.read_text(encoding="utf-8").strip()
        if text:
            return text
    secret = secrets.token_urlsafe(48)
    secret_path.write_text(secret + "\n", encoding="utf-8")
    return secret


JWT_SECRET = _load_jwt_secret()


def _env_or_file(name: str, file_values: dict[str, str]) -> str:
    return (os.environ.get(name) or file_values.get(name) or "").strip()


def load_tailscale_oauth_file(path: Path) -> dict[str, str]:
    """Parse KEY=VALUE lines from a file next to the server (no export syntax)."""
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key:
            out[key] = value
    return out


# Tailscale Admin API (OAuth). Empty means membership is not enforced — LAN
# servers keep working. When set, the server polls the tailnet and binds
# authenticated 100.x callers to a Tailscale identity.
#
# Values come from process environment first, else tailscale-oauth.env beside
# the EXE / server folder (same idea as jwt_secret.txt). Never put secrets in
# the release ZIP; copy the example file and fill it in on the host.
TAILSCALE_OAUTH_PATH = APP_DIR / "tailscale-oauth.env"
_TAILSCALE_FILE = load_tailscale_oauth_file(TAILSCALE_OAUTH_PATH)
TAILSCALE_OAUTH_CLIENT_ID = _env_or_file(
    "TAILSCALE_OAUTH_CLIENT_ID", _TAILSCALE_FILE
)
TAILSCALE_OAUTH_CLIENT_SECRET = _env_or_file(
    "TAILSCALE_OAUTH_CLIENT_SECRET", _TAILSCALE_FILE
)
TAILSCALE_TAILNET = _env_or_file("TAILSCALE_TAILNET", _TAILSCALE_FILE)
TAILSCALE_POLL_SECONDS = int(
    os.environ.get("TAILSCALE_POLL_SECONDS")
    or _TAILSCALE_FILE.get("TAILSCALE_POLL_SECONDS")
    or "60"
)
TAILSCALE_STALE_AFTER_SECONDS = int(
    os.environ.get("TAILSCALE_STALE_AFTER_SECONDS")
    or _TAILSCALE_FILE.get("TAILSCALE_STALE_AFTER_SECONDS")
    or "180"
)
#: How long an already-verified account keeps working while the server cannot
#: reach api.tailscale.com at all.
#:
#: A server running on a phone loses public DNS regularly — dozing, changing
#: networks, a tailnet up but no internet. Pausing every chat seconds after such
#: a blip is a worse failure than it prevents, because reaching this server at
#: all already requires being on the tailnet: Tailscale itself refuses everyone
#: else at the network layer. So an account whose device was confirmed while the
#: snapshot was fresh keeps working through an outage this long, then stops.
#: Accounts that were never confirmed are refused throughout.
TAILSCALE_GRACE_SECONDS = int(
    os.environ.get("TAILSCALE_GRACE_SECONDS")
    or _TAILSCALE_FILE.get("TAILSCALE_GRACE_SECONDS")
    or "86400"
)


def ensure_dirs() -> None:
    MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
