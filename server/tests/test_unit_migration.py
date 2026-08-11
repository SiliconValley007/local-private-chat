"""The lightweight column migration must upgrade an existing database."""

from __future__ import annotations

from sqlalchemy import create_engine, text

import app.db as db_module


def test_missing_reply_column_is_added(tmp_path, monkeypatch):
    db_file = tmp_path / "legacy.db"
    engine = create_engine(f"sqlite:///{db_file.as_posix()}")

    # A messages table shaped like the first release, without reply_to_message_id.
    with engine.begin() as conn:
        conn.exec_driver_sql(
            "CREATE TABLE messages ("
            "id INTEGER PRIMARY KEY, conversation_id INTEGER, sender_id INTEGER, "
            "type TEXT, body TEXT)"
        )
        conn.exec_driver_sql(
            "INSERT INTO messages (id, conversation_id, sender_id, type, body) "
            "VALUES (1, 1, 1, 'text', 'hello')"
        )

    monkeypatch.setattr(db_module, "engine", engine)
    db_module._add_missing_columns()  # pylint: disable=protected-access

    with engine.connect() as conn:
        columns = {row[1] for row in conn.exec_driver_sql("PRAGMA table_info(messages)")}
        assert "reply_to_message_id" in columns
        # Existing rows are preserved and default the new column to NULL.
        row = conn.execute(
            text("SELECT body, reply_to_message_id FROM messages WHERE id = 1")
        ).one()
        assert row[0] == "hello"
        assert row[1] is None

    engine.dispose()


def test_migration_is_idempotent(tmp_path, monkeypatch):
    db_file = tmp_path / "current.db"
    engine = create_engine(f"sqlite:///{db_file.as_posix()}")
    with engine.begin() as conn:
        conn.exec_driver_sql(
            "CREATE TABLE messages (id INTEGER PRIMARY KEY, reply_to_message_id INTEGER)"
        )

    monkeypatch.setattr(db_module, "engine", engine)
    # Running twice must not raise (column already present).
    db_module._add_missing_columns()  # pylint: disable=protected-access
    db_module._add_missing_columns()  # pylint: disable=protected-access

    with engine.connect() as conn:
        columns = {row[1] for row in conn.exec_driver_sql("PRAGMA table_info(messages)")}
        assert "reply_to_message_id" in columns
    engine.dispose()
