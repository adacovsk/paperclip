"""An external read that got no answer, and the guard that contains one.

The sweep makes hundreds of API calls and dozens of `gh`/`git` subprocess calls.
A slow or restarting server, an unauthenticated `gh`, or a `git` that timed out
under host load is not a fact about the item being worked on, and when one such
failure escaped, the whole sweep died there: every step after it (missed-wake
toggles, routine re-fires, sentinel routing, hold releases, promotion) waited for
the next fire, and a failure that repeats on every fire kept all of them dark
until someone noticed. So one such failure costs that item (or that step) and
the sweep carries on.

A timed-out *write* may still have applied server-side. Nothing here retries it:
the item is left unrecorded, and the next sweep re-reads its state from the
server before acting, which is the re-read a half-applied write needs.

Containing a failure is not the same as reading it as an empty answer. A step
whose input failed to load is skipped, never run on an empty stand-in: "gh
failed" is not "there are no open PRs", and acting on the second closes,
re-dispatches or deletes things that are still live.
"""

from __future__ import annotations

import subprocess
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


def subprocess_words(exc: subprocess.SubprocessError) -> str:
    """`gh pr list exited 1: <first stderr line>` -- enough to tell auth from a timeout."""
    cmd = getattr(exc, "cmd", None)
    what = " ".join(cmd[:3]) if isinstance(cmd, (list, tuple)) else str(cmd or "subprocess")
    if isinstance(exc, subprocess.TimeoutExpired):
        return f"{what} timed out after {exc.timeout:g}s"
    if isinstance(exc, subprocess.CalledProcessError):
        stderr = exc.stderr.decode(errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        first = next((line.strip() for line in stderr.splitlines() if line.strip()), "")
        return f"{what} exited {exc.returncode}" + (f": {first}" if first else "")
    return f"{what}: {exc}"


class skip_unreachable:  # noqa: N801 - used as a statement: `with skip_unreachable(...)`
    """Contain an external failure to the block it was raised in, and say so.

    Contained: `ApiUnreachable` (the API gave no answer) and any
    `subprocess.SubprocessError` (a `gh`/`git` call that exited non-zero under
    `check=True`, or timed out). The block's own `continue`/`break` pass through
    unchanged; any other exception propagates, since it is a bug, not an outage.
    """

    def __init__(self, what: str):
        self.what = what
        self.skipped = False

    def __enter__(self) -> "skip_unreachable":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc_type is None:
            return False
        if issubclass(exc_type, ApiUnreachable):
            said = f"API unreachable ({exc})"
        elif issubclass(exc_type, subprocess.SubprocessError):
            said = subprocess_words(exc)
        else:
            return False
        self.skipped = True
        print(f"{self.what}: {said}; left for the next sweep", flush=True)
        return True
