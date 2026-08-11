"""Pytest fixtures — isolated SQLite DB + media root per test."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker

import app.db as db_module

# Importing models registers every ORM table on Base.metadata.
import app.models  # noqa: F401  # pylint: disable=unused-import
from app.db import Base
from app.main import app as fastapi_app
from app.realtime.hub import hub


@pytest.fixture()
def client(tmp_path, monkeypatch):
    db_file = tmp_path / "test.db"
    media_root = tmp_path / "media"
    media_root.mkdir()

    monkeypatch.setattr("app.config.MEDIA_ROOT", media_root)
    monkeypatch.setattr("app.routers.media.MEDIA_ROOT", media_root)

    engine = create_engine(
        f"sqlite:///{db_file.as_posix()}",
        connect_args={"check_same_thread": False},
    )

    @event.listens_for(engine, "connect")
    def _fk(dbapi_connection, _):
        cur = dbapi_connection.cursor()
        cur.execute("PRAGMA foreign_keys=ON")
        cur.close()

    session_factory = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    db_module.engine = engine
    db_module.SessionLocal = session_factory

    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)

    hub.reset()

    def override_get_db():
        db = session_factory()
        try:
            yield db
        finally:
            db.close()

    fastapi_app.dependency_overrides[db_module.get_db] = override_get_db

    with TestClient(fastapi_app) as test_client:
        yield test_client

    fastapi_app.dependency_overrides.clear()
    hub.reset()
    Base.metadata.drop_all(bind=engine)
    engine.dispose()


def register(
    test_client: TestClient,
    username: str,
    password: str = "secret12",
    display_name: str | None = None,
):
    """Register a user and return the auth payload."""
    payload = {"username": username, "password": password}
    if display_name is not None:
        payload["display_name"] = display_name
    res = test_client.post("/api/auth/register", json=payload)
    assert res.status_code == 200, res.text
    return res.json()


def auth_header(token: str) -> dict[str, str]:
    """Bearer header for authenticated requests."""
    return {"Authorization": f"Bearer {token}"}
