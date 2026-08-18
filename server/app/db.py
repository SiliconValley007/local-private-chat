"""SQLAlchemy engine and session helpers."""

from __future__ import annotations

from collections.abc import Generator

from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import NullPool

from app.base import Base
from app.config import DATABASE_URL, LOW_MEMORY, SQLITE_CACHE_KB, ensure_dirs

__all__ = ["Base", "SessionLocal", "engine", "get_db", "init_db"]


ensure_dirs()

# NullPool on a phone: no idle SQLite connections sitting around between
# requests. A home chat server has a handful of clients, so the cost of opening
# a connection per checkout is cheaper than holding page caches for each one.
_engine_kwargs: dict = {
    "connect_args": {"check_same_thread": False, "timeout": 30},
}
if LOW_MEMORY:
    _engine_kwargs["poolclass"] = NullPool

engine = create_engine(DATABASE_URL, **_engine_kwargs)


@event.listens_for(engine, "connect")
def _set_sqlite_pragma(dbapi_connection, _connection_record) -> None:
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
    # WAL lets a WebSocket write and a REST read overlap without blocking.
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA synchronous=NORMAL")
    # Negative cache_size is kilobytes; keeps SQLite from eating phone RAM.
    cursor.execute(f"PRAGMA cache_size=-{SQLITE_CACHE_KB}")
    cursor.execute("PRAGMA temp_store=FILE")
    if LOW_MEMORY:
        cursor.execute("PRAGMA mmap_size=0")
    cursor.close()


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db() -> Generator[Session, None, None]:
    """Yield a request-scoped SQLAlchemy session."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db() -> None:
    """Create tables, importing models here because they depend on Base."""
    # pylint: disable=import-outside-toplevel,unused-import
    from app import models  # noqa: F401

    Base.metadata.create_all(bind=engine)
    _add_missing_columns()
    _add_missing_indexes()


# Columns added after the first release. ``create_all`` only creates missing
# tables, so an existing database on a phone needs them added explicitly.
_ADDED_COLUMNS: tuple[tuple[str, str, str], ...] = (
    ("messages", "reply_to_message_id", "INTEGER"),
    ("messages", "edited_at", "DATETIME"),
    ("messages", "deleted_at", "DATETIME"),
    ("messages", "expires_at", "DATETIME"),
    ("messages", "media_thumb_path", "TEXT"),
    ("messages", "media_duration_ms", "INTEGER"),
    ("users", "avatar_path", "TEXT"),
    ("users", "avatar_updated_at", "DATETIME"),
    ("users", "mood", "TEXT"),
    ("conversations", "wallpaper_path", "TEXT"),
    ("conversations", "wallpaper_dim", "REAL"),
    ("conversations", "wallpaper_set_by", "INTEGER"),
    ("conversations", "wallpaper_set_at", "DATETIME"),
    ("conversations", "disappear_after_seconds", "INTEGER"),
    ("conversations", "anniversary_on", "TEXT"),
    ("users", "token_version", "INTEGER NOT NULL DEFAULT 0"),
)


def _add_missing_columns() -> None:
    """Bring an existing SQLite file up to date, without touching its data."""
    with engine.begin() as conn:
        for table, column, column_type in _ADDED_COLUMNS:
            existing = {
                row[1] for row in conn.exec_driver_sql(f"PRAGMA table_info({table})")
            }
            if existing and column not in existing:
                conn.exec_driver_sql(
                    f"ALTER TABLE {table} ADD COLUMN {column} {column_type}"
                )


def _add_missing_indexes() -> None:
    """Add safe partial indexes that cannot disturb legacy message retries."""
    with engine.begin() as conn:
        # Call logs are server-authored from signaling. Two terminal frames can
        # arrive on different sockets at almost the same time, so the database
        # is the final idempotency boundary rather than a race-prone read first.
        # Older client-authored call rows have no ``call:`` client id and are
        # intentionally outside this index.
        conn.exec_driver_sql(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_call_log_client_id
            ON messages(conversation_id, client_id)
            WHERE type = 'call'
              AND client_id IS NOT NULL
              AND client_id LIKE 'call:%'
            """
        )
