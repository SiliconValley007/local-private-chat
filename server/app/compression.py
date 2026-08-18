"""Response compression for the JSON API only."""

from __future__ import annotations

from starlette.middleware.gzip import GZipMiddleware
from starlette.types import ASGIApp, Receive, Scope, Send

# Attachments, avatars and wallpapers are photos, videos, and audio: already
# compressed formats. Running them through gzip costs the phone's CPU and saves
# nothing, so they are handed straight to the client untouched.
SKIP_SUBSTRINGS = ("/media", "/avatar", "/wallpaper")


class CompressJsonMiddleware:
    """Gzip text responses, leave already-compressed binaries alone.

    Chat is mostly JSON, and JSON compresses by roughly three quarters. On a
    weak or metered link that is the single biggest saving available, and it
    costs nothing to decode: Dart's HTTP client advertises gzip and unwraps it
    without any client-side change.
    """

    def __init__(self, app: ASGIApp, minimum_size: int = 700) -> None:
        self.app = app
        self._gzip = GZipMiddleware(app, minimum_size=minimum_size)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        path = scope.get("path", "")
        if any(part in path for part in SKIP_SUBSTRINGS):
            await self.app(scope, receive, send)
            return
        await self._gzip(scope, receive, send)
