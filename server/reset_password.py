#!/usr/bin/env python3
"""Admin-only password reset for Local Chat (run on the server host).

Usage (from the server/ folder, with the venv active):

    python reset_password.py                  # list users
    python reset_password.py alice            # prompt for a new password
    python reset_password.py alice 'Temp123!' # set password without a prompt

This never prints the old password — it cannot be recovered. It only writes a
new bcrypt hash into data/chat.db. Chat history is untouched.
"""

from __future__ import annotations

import argparse
import getpass
import sys
from pathlib import Path

# Allow `python reset_password.py` from server/ without installing the package.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from sqlalchemy import select  # noqa: E402

from app.auth import hash_password  # noqa: E402
from app.models import User  # noqa: E402


def list_users() -> int:
    from app import db as db_module

    db_module.init_db()
    with db_module.SessionLocal() as db:
        rows = list(db.scalars(select(User).order_by(User.username)).all())
    if not rows:
        print("No users in the database yet.")
        return 0
    print(f"{'ID':>4}  {'USERNAME':<20}  DISPLAY NAME")
    print("-" * 50)
    for u in rows:
        print(f"{u.id:>4}  {u.username:<20}  {u.display_name}")
    print()
    print("Reset one of them with:")
    print("  python reset_password.py <username>")
    return 0


def reset_user(username: str, new_password: str | None) -> int:
    from app import db as db_module

    username = username.strip()
    if not username:
        print("Username is required.", file=sys.stderr)
        return 2

    if new_password is None:
        first = getpass.getpass(f"New password for @{username}: ")
        second = getpass.getpass("Confirm password: ")
        if first != second:
            print("Passwords do not match.", file=sys.stderr)
            return 2
        new_password = first

    if len(new_password) < 6:
        print("Password must be at least 6 characters.", file=sys.stderr)
        return 2
    if len(new_password) > 128:
        print("Password is too long (max 128 characters).", file=sys.stderr)
        return 2

    db_module.init_db()
    with db_module.SessionLocal() as db:
        user = db.scalar(select(User).where(User.username == username))
        if user is None:
            print(f"No user named {username!r}.", file=sys.stderr)
            print("Run without arguments to list usernames.", file=sys.stderr)
            return 1
        user.password_hash = hash_password(new_password)
        db.commit()
        print(f"Password reset for @{user.username} (id={user.id}).")
        print("They can sign in with the new password immediately — no restart needed.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="List users or reset a Local Chat login password (admin, on-server).",
    )
    parser.add_argument(
        "username",
        nargs="?",
        help="Username to reset. Omit to list all users.",
    )
    parser.add_argument(
        "password",
        nargs="?",
        help="New password. Omit to type it privately (recommended).",
    )
    args = parser.parse_args(argv)

    if args.username is None:
        return list_users()
    return reset_user(args.username, args.password)


if __name__ == "__main__":
    raise SystemExit(main())
