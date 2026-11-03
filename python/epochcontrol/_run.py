"""One run: its folder, status, heartbeat and the commands it receives."""

from __future__ import annotations

import os
import secrets
import socket
import sys
import threading
import warnings
from datetime import datetime
from pathlib import Path

from . import _io, _proc
from ._clock import SystemClock
from ._paths import runs_dir
from ._timing import Timer

SCHEMA = 1
POLL_S = 0.25        # read control.json at most this often from inside the loop
PAUSE_POLL_S = 0.5   # while paused (PRD CTL1)
HEARTBEAT_S = 1.0


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


class Run:
    """Writes the run folder and applies pause, resume and stop.

    Every file operation goes through ``_safe``: a failure warns once and switches
    writing off, but never raises into the training loop (PRD SAFE1).
    """

    def __init__(self, name: str, total: int | None = None, *, source: str = "library",
                 clock=None, home: Path | None = None, heartbeat: bool = True,
                 heartbeat_s: float = HEARTBEAT_S, poll_s: float = POLL_S):
        from . import __version__

        self.name = name
        self.total = total
        self.clock = clock or SystemClock()
        self.timer = Timer(self.clock)
        self.done = 0
        self.state = "running"
        self.last_seq = 0
        self.error: dict | None = None
        self._pause_wanted = False
        self._stop_wanted = False
        self._poll_s = poll_s
        self._last_poll: float | None = None
        self._ok = True
        self._lock = threading.Lock()
        self._stop_beat = threading.Event()
        self._beat: threading.Thread | None = None

        wall = self.clock.wall()
        self.run_id = datetime.fromtimestamp(wall).strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(2)
        self.pid = os.getpid()
        self.pid_start = _proc.start_time(self.pid)
        self.dir = Path(home or runs_dir()) / self.run_id
        script = Path(sys.argv[0]).name if sys.argv and sys.argv[0] else None

        self._safe(self._make_dir)
        self._safe(_io.write_json, self.dir / "meta.json", {
            "schema": SCHEMA, "run_id": self.run_id, "name": name, "pid": self.pid,
            "pid_start": self.pid_start, "host": socket.gethostname(), "started_at": _iso(wall),
            "total_epochs": total, "source": source, "framework": None,
            "library_version": __version__, "pause_mode": "cooperative", "tags": [],
            "run_dir": None, "script": script,
        })
        self.event("started")
        self.write_status()
        if heartbeat and self._ok:
            self._beat = threading.Thread(target=self._beat_loop, args=(heartbeat_s,),
                                          name="epochcontrol-heartbeat", daemon=True)
            self._beat.start()

    # -- files ---------------------------------------------------------------------

    def _make_dir(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)

    def _safe(self, fn, *args) -> None:
        if not self._ok:
            return
        try:
            fn(*args)
        except Exception as e:  # never break training
            self._ok = False
            warnings.warn(f"epochcontrol: cannot write the run folder ({e}); "
                          "training continues without monitoring", RuntimeWarning, stacklevel=3)

    def event(self, kind: str, by: str = "library", **extra) -> None:
        self._safe(_io.append_jsonl, self.dir / "events.jsonl",
                   {"t": self.clock.wall(), "type": kind, "by": by, **extra})

    def write_status(self) -> None:
        with self._lock:
            slept = self.timer.tick()
            if slept:
                self.event("slept", duration_s=slept)
            timing = self.timer.snapshot()
            eta = None
            if self.total and self.done and self.state in ("running", "paused"):
                eta = timing["active_s"] / self.done * max(0, self.total - self.done)
            self._safe(_io.write_json, self.dir / "status.json", {
                "schema": SCHEMA, "run_id": self.run_id, "state": self.state,
                "epoch": self.done, "total_epochs": self.total, "step": None, "total_steps": None,
                "best": None, "patience": None, "timing": timing, "eta_s": eta,
                "heartbeat": _iso(self.clock.wall()), "pid": self.pid, "pid_start": self.pid_start,
                "last_seq": self.last_seq, "error": self.error,
            })

    def _beat_loop(self, every: float) -> None:
        while not self._stop_beat.wait(every):
            self.write_status()

    # -- control -------------------------------------------------------------------

    def poll(self, force: bool = False) -> None:
        """Apply a new command from control.json. Each seq is applied once (PRD CTL5)."""
        now = self.clock.monotonic()
        if not force and self._last_poll is not None and now - self._last_poll < self._poll_s:
            return
        self._last_poll = now
        c = _io.read_json(self.dir / "control.json") if self._ok else None
        if not isinstance(c, dict) or not isinstance(c.get("seq"), int) or c["seq"] <= self.last_seq:
            return
        self.last_seq = c["seq"]
        cmd = c.get("command")
        if cmd == "pause":
            self._pause_wanted = True
        elif cmd == "resume":
            self._pause_wanted = False
        elif cmd == "stop":
            self._stop_wanted = True
            self._pause_wanted = False
        self.event("command", by=c.get("by", "cli"), detail=str(cmd))

    def should_stop(self) -> bool:
        return self._stop_wanted

    def wait_if_paused(self) -> None:
        """Block while a pause is in force; returns at once otherwise."""
        if not self._pause_wanted or self._stop_wanted:
            return
        self.timer.pause()
        self.state = "paused"
        self.event("paused")
        self.write_status()
        while self._pause_wanted and not self._stop_wanted:
            self.clock.sleep(PAUSE_POLL_S)
            self.poll(force=True)
        self.timer.resume()
        self.state = "stopping" if self._stop_wanted else "running"
        self.event("resumed")
        self.write_status()

    def step_done(self) -> None:
        self.done += 1

    def finish(self, state: str = "finished") -> None:
        if self.state in ("finished", "stopped", "failed"):
            return
        self._stop_beat.set()
        if self._beat is not None:
            self._beat.join(timeout=2)
        self.timer.resume()
        self.state = state
        self.event(state)
        self.write_status()
