"""Optional Firebase Cloud Messaging (high-priority metadata-only pushes)."""

from __future__ import annotations

import logging
import os
from datetime import timedelta
from pathlib import Path
from typing import NamedTuple

try:  # firebase-admin is optional: chat works fully without push wake-ups.
    import firebase_admin
    from firebase_admin import credentials, exceptions as fb_exceptions, messaging
except ImportError:  # pragma: no cover - depends on the deployment
    firebase_admin = None
    credentials = None
    fb_exceptions = None
    messaging = None

logger = logging.getLogger(__name__)

# Errors that mean "this token is dead", so it can be deleted.
UNREGISTERED_ERRORS: tuple[type[Exception], ...] = (
    tuple(
        exc
        for exc in (
            getattr(messaging, "UnregisteredError", None),
            getattr(messaging, "SenderIdMismatchError", None),
            getattr(fb_exceptions, "NotFoundError", None),
        )
        if isinstance(exc, type)
    )
    or (LookupError,)  # placeholder that never matches a real FCM failure
)

_FCM_STATE = {"ready": False}


def _credentials_path() -> str | None:
    cred_path = os.environ.get("LOCALCHAT_FIREBASE_CREDENTIALS", "").strip()
    if not cred_path:
        default = Path(__file__).resolve().parent.parent / "firebase-service-account.json"
        if default.is_file():
            cred_path = str(default)
    if not cred_path or not Path(cred_path).is_file():
        return None
    return cred_path


def init_firebase() -> bool:
    """Initialize firebase-admin if a service account file is configured."""
    if _FCM_STATE["ready"]:
        return True

    if firebase_admin is None:
        logger.info("FCM disabled: firebase-admin not installed (push wake-ups skipped)")
        return False

    cred_path = _credentials_path()
    if cred_path is None:
        logger.info("FCM disabled: no firebase-service-account.json (push wake-ups skipped)")
        return False

    try:
        try:
            firebase_admin.get_app()
        except ValueError:
            firebase_admin.initialize_app(credentials.Certificate(cred_path))
        _FCM_STATE["ready"] = True
        logger.info("Firebase Admin initialized for FCM")
        return True
    except Exception:  # pylint: disable=broad-exception-caught
        # Push is best-effort; a bad key must never take the chat server down.
        logger.exception("Failed to initialize Firebase Admin")
        return False


class PushResult(NamedTuple):
    """Outcome of a push fan-out."""

    sent: int
    invalid_tokens: list[str]


def send_message_push(
    tokens: list[str],
    *,
    data: dict[str, str],
) -> PushResult:
    """Notify devices about a new message, without revealing its content.

    This is data-only so the receiving phone can replace the sender's server
    name with its private local nickname before posting the notification.
    Android cannot customize a notification-block message from device storage.

    Delivery remains high priority with a 12-hour TTL. The Flutter background
    handler is registered before ``runApp`` so Android can start it even when
    the UI isolate is gone. The message body never leaves the Tailscale network.
    """
    if not tokens or not init_firebase():
        return PushResult(0, [])

    # FCM requires every data value to be a string.
    payload = {str(k): str(v) for k, v in data.items()}
    sent = 0
    invalid: list[str] = []

    # Sent one at a time so a single bad token can't hide the others' errors.
    for token in tokens:
        message = messaging.Message(
            token=token,
            data=payload,
            android=messaging.AndroidConfig(
                priority="high",
                # Survive a phone that is asleep or briefly offline.
                ttl=timedelta(hours=12),
            ),
        )
        try:
            messaging.send(message)
            sent += 1
        except UNREGISTERED_ERRORS:
            # The app was uninstalled or the token rotated; stop using it.
            logger.info("Dropping stale FCM token")
            invalid.append(token)
        except Exception:  # pylint: disable=broad-exception-caught
            # One failed device must not block the remaining recipients.
            logger.warning("FCM send failed for a token", exc_info=True)
    return PushResult(sent, invalid)


def send_call_incoming_push(
    tokens: list[str],
    *,
    conversation_id: int,
    call_id: str,
    caller_id: int,
    caller_name: str,
    caller_username: str,
    media: str = "audio",
) -> PushResult:
    """Wake offline members for an incoming call (metadata only)."""
    return send_message_push(
        tokens,
        data={
            "type": "call.incoming",
            "conversation_id": str(conversation_id),
            "call_id": call_id,
            "caller_id": str(caller_id),
            "caller_name": caller_name,
            "caller_username": caller_username,
            "media": media,
        },
    )


def send_reaction_push(
    tokens: list[str],
    *,
    conversation_id: int,
    message_id: int,
    actor_id: int,
    actor_name: str,
) -> PushResult:
    """Notify offline members that someone reacted (metadata only)."""
    return send_message_push(
        tokens,
        data={
            "type": "reaction.updated",
            "conversation_id": str(conversation_id),
            "message_id": str(message_id),
            "actor_id": str(actor_id),
            "actor_name": actor_name,
        },
    )
