"""Process start time: with the pid it proves a process is the same one (PRD CTL6)."""

from __future__ import annotations

import os
import subprocess
import time


def start_time(pid: int | None = None) -> float:
    """Seconds since the epoch at which the process started; 0.0 if unknown."""
    pid = pid or os.getpid()
    try:
        import psutil  # optional extra

        return float(psutil.Process(pid).create_time())
    except Exception:
        pass
    try:  # Linux
        with open(f"/proc/{pid}/stat") as f:
            ticks = int(f.read().rsplit(")", 1)[1].split()[19])
        with open("/proc/stat") as f:
            btime = next(int(l.split()[1]) for l in f if l.startswith("btime"))
        return btime + ticks / os.sysconf("SC_CLK_TCK")
    except Exception:
        pass
    try:  # macOS and other BSDs: whole seconds only
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True,
                             text=True, env={**os.environ, "LC_ALL": "C"}, timeout=5).stdout.strip()
        return time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y"))
    except Exception:
        return 0.0
