"""A Paperclip API call that got no answer, and the guard that contains one.

The sweep makes hundreds of API calls. One that ran past the client timeout used
to raise `TimeoutError` uncaught, and the whole sweep died there: every sentinel
not yet routed and every candidate not yet promoted waited for the next fire, and
a fire that died on its first steps never reached the rest at all. A slow or
restarting server is not a fact about the item being worked on, so one such call
now costs that item (or that step) and the sweep carries on.

A timed-out *write* may still have applied server-side. Nothing here retries it:
the item is left unrecorded, and the next sweep re-reads its state from the
server before acting, which is the re-read a half-applied write needs.
"""

from __future__ import annotations

import urllib.error


class ApiUnreachable(Exception):
    """The request got no HTTP answer: timeout, refused or dropped connection."""


def transport_failure(exc: BaseException) -> bool:
    """Whether `exc` means no answer came back, as opposed to an answer that refused.

    `HTTPError` is a `URLError`, but it is the server's answer, so callers that
    handle a refusal keep seeing it unchanged.
    """
    if isinstance(exc, urllib.error.HTTPError):
        return False
    return isinstance(exc, (urllib.error.URLError, TimeoutError, ConnectionError))


class skip_unreachable:  # noqa: N801 - used as a statement: `with skip_unreachable(...)`
    """Contain an `ApiUnreachable` to the block it was raised in, and say so.

    The block's own `continue`/`break` pass through unchanged; any other
    exception propagates.
    """

    def __init__(self, what: str):
        self.what = what
        self.skipped = False

    def __enter__(self) -> "skip_unreachable":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc_type is not None and issubclass(exc_type, ApiUnreachable):
            self.skipped = True
            print(f"{self.what}: API unreachable ({exc}); left for the next sweep", flush=True)
            return True
        return False
