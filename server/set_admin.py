#!/usr/bin/env python3
"""Operator break-glass for Local Chat admin identity (run on the server host).

Usage (from the server/ folder, with the venv active):

    python set_admin.py                     # show current admin + device pin
    python set_admin.py DDas                # make @DDas the admin
    python set_admin.py DDas --clear-device  # also drop the trusted-device pin
    python set_admin.py --clear-device       # keep admin, clear device pin only
    python set_admin.py --bump-all          # sign every account out everywhere

Environment ``LOCALCHAT_ADMIN_USERNAME`` still wins over the database when set;
this tool cannot override that — stop the server, unset the env, then run again.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Allow `python set_admin.py` from server/ without installing the package.
# pylint: disable=wrong-import-position,import-outside-toplevel
sys.path.insert(0, str(Path(__file__).resolve().parent))

from sqlalchemy import select  # noqa: E402

from app.models import ServerSetting, User, utcnow  # noqa: E402


def show_status() -> int:
    from app import admin as admin_rules
    from app import db as db_module

    db_module.init_db()
    with db_module.SessionLocal() as db:
        env = admin_rules.env_admin_username()
        stored = admin_rules.stored_admin_username(db)
        device = admin_rules.stored_admin_device_id(db)
        print(f"Environment admin : {env or '(none)'}")
        print(f"Stored admin      : {stored or '(none)'}")
        print(f"Effective admin   : {admin_rules.admin_username(db) or '(none)'}")
        print(f"Trusted device    : {device or '(none)'}")
        if env:
            print()
            print(
                "LOCALCHAT_ADMIN_USERNAME is set — the app cannot change the "
                "admin, and this tool will not rewrite the env either."
            )
    return 0


def set_admin(username: str | None, *, clear_device: bool, bump_all: bool) -> int:
    from app import admin as admin_rules
    from app import db as db_module
    from app.sessions import bump_token_version

    if admin_rules.admin_is_locked() and username:
        print(
            "LOCALCHAT_ADMIN_USERNAME is set on this process. Unset it and "
            "restart before changing the admin from the database.",
            file=sys.stderr,
        )
        return 2

    db_module.init_db()
    with db_module.SessionLocal() as db:
        if username:
            account = db.scalar(
                select(User).where(User.username == username.strip())
            )
            if account is None:
                # Case-insensitive fallback for operators typing from memory.
                from sqlalchemy import func

                account = db.scalar(
                    select(User).where(
                        func.lower(User.username) == username.strip().casefold()
                    )
                )
            if account is None:
                print(f"No user named {username!r}.", file=sys.stderr)
                return 1
            row = db.get(ServerSetting, admin_rules.ADMIN_USERNAME_KEY)
            if row is None:
                row = ServerSetting(key=admin_rules.ADMIN_USERNAME_KEY)
                db.add(row)
            row.value = account.username
            row.updated_at = utcnow()
            row.updated_by = None
            db.commit()
            print(f"Admin is now @{account.username} (id={account.id}).")

        if clear_device:
            pin = db.get(ServerSetting, admin_rules.ADMIN_DEVICE_KEY)
            if pin is not None:
                db.delete(pin)
                db.commit()
                print("Trusted admin device pin cleared.")
            else:
                print("No trusted admin device pin was set.")

        if bump_all:
            users = list(db.scalars(select(User)).all())
            for user in users:
                bump_token_version(db, user)
            print(f"Signed out {len(users)} account(s) on every device.")

    if username is None and not clear_device and not bump_all:
        return show_status()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Show or change the Local Chat admin (operator, on-server).",
    )
    parser.add_argument(
        "username",
        nargs="?",
        help="Username to appoint as admin. Omit to only show status / clear pin.",
    )
    parser.add_argument(
        "--clear-device",
        action="store_true",
        help="Remove the trusted-admin-device pin so any admin install can open the log.",
    )
    parser.add_argument(
        "--bump-all",
        action="store_true",
        help="Invalidate every outstanding login token on this server.",
    )
    args = parser.parse_args(argv)
    return set_admin(
        args.username,
        clear_device=args.clear_device,
        bump_all=args.bump_all,
    )


if __name__ == "__main__":
    raise SystemExit(main())
