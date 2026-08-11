"""SQLAlchemy engine and session helpers."""

from __future__ import annotations

from collections.abc import Generator

from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from app.base import Base
from app.config import DATABASE_URL, ensure_dirs

__all__ = ["Base", "SessionLocal", "engine", "get_db", "init_db"]


ensure_dirs()

engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False},
)

# SQLite foreign keys
@event.listens_for(engine, "connect")
def _set_sqlite_pragma(dbapi_connection, _connection_record) -> None:
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
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


# Columns added after the first release. ``create_all`` only creates missing
# tables, so an existing database on a phone needs them added explicitly.
_ADDED_COLUMNS: tuple[tuple[str, str, str], ...] = (
    ("messages", "reply_to_message_id", "INTEGER"),
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
