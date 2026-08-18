"""The couple streak: consecutive days both people in a chat said something.

The count used to be derived from the messages still sitting in the table, which
made it as fragile as the transcript itself. Deleting a message for everyone, or
letting a disappearing timer clear the day's chat, erased days the two people had
plainly spoken on — the streak silently fell to zero and there was no way to earn
those days back.

A day someone spoke is a fact, so it is written down once as a fact and never
recomputed from messages again. The ledger holds one tiny row per chat, per
person, per UTC day; nothing in the app deletes from it.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models import Conversation, ConversationDay, Message, utcnow

__all__ = ["day_of", "record_spoken_day", "streak_days", "backfill_spoken_days"]


def day_of(moment: datetime) -> str:
    """The UTC calendar day of [moment], as ``YYYY-MM-DD``."""
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).date().isoformat()


def record_spoken_day(
    db: Session,
    *,
    conversation_id: int,
    user_id: int,
    when: datetime | None = None,
) -> None:
    """Notes that this person spoke in this chat today. Safe to call repeatedly.

    The write is deliberately forgiving: a streak is a nicety, and no send should
    ever fail because two messages raced to claim the same day.
    """
    day = day_of(when or utcnow())
    already = db.scalar(
        select(ConversationDay.id).where(
            ConversationDay.conversation_id == conversation_id,
            ConversationDay.user_id == user_id,
            ConversationDay.day == day,
        )
    )
    if already is not None:
        return
    savepoint = db.begin_nested()
    try:
        db.add(
            ConversationDay(
                conversation_id=conversation_id,
                user_id=user_id,
                day=day,
            )
        )
        savepoint.commit()
    except IntegrityError:
        savepoint.rollback()


def streak_days(db: Session, conversation: Conversation, *, today: date | None = None) -> int:
    """Consecutive days, ending today or yesterday, where everyone spoke.

    Yesterday counts as the anchor on purpose. Days are UTC — one shared clock
    for both phones — so for most of the world the day rolls over mid-evening or
    mid-morning. Anchoring only on today would blank out a live streak for hours
    every day, which is exactly how a working feature comes to look broken.
    """
    if conversation.type != "dm":
        return 0
    member_ids = {m.user_id for m in conversation.members}
    if len(member_ids) < 2:
        return 0

    spoke_on = _spoken_days(db, conversation.id)
    current = today or datetime.now(timezone.utc).date()
    if not member_ids <= spoke_on.get(current.isoformat(), set()):
        current -= timedelta(days=1)

    streak = 0
    while member_ids <= spoke_on.get(current.isoformat(), set()):
        streak += 1
        current -= timedelta(days=1)
    return streak


def _spoken_days(db: Session, conversation_id: int) -> dict[str, set[int]]:
    rows = db.execute(
        select(ConversationDay.day, ConversationDay.user_id).where(
            ConversationDay.conversation_id == conversation_id
        )
    ).all()
    by_day: dict[str, set[int]] = defaultdict(set)
    for day, user_id in rows:
        by_day[day].add(user_id)
    return by_day


def backfill_spoken_days(db: Session) -> int:
    """Seeds the ledger from the messages a database already holds.

    Runs once, on the first start after upgrading, so streaks people already had
    survive the move rather than restarting from zero. Only days that still have
    a message can be recovered; from here on the ledger stands on its own.
    """
    if db.scalar(select(ConversationDay.id).limit(1)) is not None:
        return 0
    dm_ids = set(
        db.scalars(select(Conversation.id).where(Conversation.type == "dm")).all()
    )
    if not dm_ids:
        return 0
    rows = db.execute(
        select(Message.conversation_id, Message.sender_id, Message.created_at).where(
            Message.conversation_id.in_(dm_ids)
        )
    ).all()
    seen: set[tuple[int, int, str]] = set()
    for conversation_id, sender_id, created_at in rows:
        if created_at is None:
            continue
        seen.add((conversation_id, sender_id, day_of(created_at)))
    for conversation_id, sender_id, day in sorted(seen):
        db.add(
            ConversationDay(
                conversation_id=conversation_id,
                user_id=sender_id,
                day=day,
            )
        )
    db.commit()
    return len(seen)
