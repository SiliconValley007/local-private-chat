"""Application configuration — paths, JWT, host/port."""

from __future__ import annotations

import os
import secrets
from pathlib import Path

# server/ directory (parent of app/)
APP_DIR = Path(__file__).resolve().parent.parent
MEDIA_ROOT = APP_DIR / "media"
DATA_DIR = APP_DIR / "data"
DATABASE_PATH = DATA_DIR / "chat.db"
DATABASE_URL = f"sqlite:///{DATABASE_PATH.as_posix()}"

HOST = os.environ.get("LOCALCHAT_HOST", "0.0.0.0")  # all interfaces: LAN + Tailscale
PORT = int(os.environ.get("LOCALCHAT_PORT", "8000"))
ACCESS_TOKEN_EXPIRE_DAYS = int(os.environ.get("LOCALCHAT_TOKEN_DAYS", "30"))
JWT_ALGORITHM = "HS256"


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


def ensure_dirs() -> None:
    MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
