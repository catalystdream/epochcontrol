"""Where run folders live."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def runs_dir() -> Path:
    """The folder that holds one sub-folder per run.

    ``EPOCHCONTROL_HOME`` replaces the base folder if set; runs go in its ``runs/``.
    Otherwise: macOS ``~/Library/Application Support/EpochControl/runs``,
    elsewhere ``$XDG_DATA_HOME/epochcontrol/runs`` (default ``~/.local/share``).
    """
    home = os.environ.get("EPOCHCONTROL_HOME")
    if home:
        return Path(home).expanduser() / "runs"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "EpochControl" / "runs"
    data = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(data) / "epochcontrol" / "runs"
