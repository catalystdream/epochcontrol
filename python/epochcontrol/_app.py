"""Open the menu-bar app when a run starts (PRD LIB13).

Best effort and never blocking: on a Mac with a screen session, `open -g` starts the app in
the background (no focus change) or does nothing if it is already running. Over SSH it does
this only if the same user is logged in at the Mac (locked screen included), so the app has a
menu bar to appear in. Any failure, including the app not being installed, is ignored.
"""

from __future__ import annotations

import os
import subprocess
import sys

BUNDLE_ID = "io.github.catalystdream.epochcontrol"
_tried = False


def console_is_mine() -> bool:
    """True if this user is the one logged in at the Mac's screen (owner of /dev/console)."""
    try:
        return os.stat("/dev/console").st_uid == os.getuid()
    except OSError:
        return False


def should_open(environ=os.environ, platform: str | None = None, console_mine=console_is_mine) -> bool:
    # Read at call time: a `sys.platform` default would be fixed at import.
    if (sys.platform if platform is None else platform) != "darwin":
        return False
    if environ.get("EPOCHCONTROL_NO_APP"):
        return False
    if environ.get("SSH_CONNECTION") or environ.get("SSH_TTY"):
        return console_mine()  # over SSH: only if you are also logged in at the Mac
    return True


def open_app() -> None:
    """Start the app once per process, in the background. Never raises."""
    global _tried
    if _tried or not should_open():
        return
    _tried = True
    try:
        _spawn(["open", "-g", "-b", BUNDLE_ID])
    except Exception:
        pass


def _spawn(args: list[str]) -> None:
    """Start a process and do not wait for it."""
    subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, close_fds=True)
