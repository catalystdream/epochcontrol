"""Open the menu-bar app when a run starts (PRD LIB13).

Best effort and never blocking: on a Mac with a screen session, `open -g` starts the app in
the background (no focus change) or does nothing if it is already running. Any failure,
including the app not being installed, is ignored.
"""

from __future__ import annotations

import os
import subprocess
import sys

BUNDLE_ID = "io.github.catalystdream.epochcontrol"
_tried = False


def should_open(environ=os.environ, platform: str = sys.platform) -> bool:
    if platform != "darwin":
        return False
    if environ.get("EPOCHCONTROL_NO_APP"):
        return False
    if environ.get("SSH_CONNECTION") or environ.get("SSH_TTY"):
        return False  # a remote shell: no screen to show the app on
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
