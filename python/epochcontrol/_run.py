"""One run: its folder, status, heartbeat and the commands it receives."""

from __future__ import annotations

import atexit
import os
import secrets
import socket
import sys
import threading
import warnings
import weakref
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Iterator

from . import _io, _proc
from ._clock import SystemClock
from ._paths import runs_dir
from ._timing import Timer

SCHEMA = 1
POLL_S = 0.25        # read control.json at most this often from inside the loop
PAUSE_POLL_S = 0.5   # while paused (PRD CTL1)
HEARTBEAT_S = 1.0
ENDED = ("finished", "stopped", "failed")

_active: "weakref.WeakSet[Run]" = weakref.WeakSet()


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def _number(v: Any) -> bool:
    return v is None or (isinstance(v, (int, float)) and not isinstance(v, bool))


class Run:
    """A training run as seen by EpochControl.

    Every file operation goes through ``_safe``: a failure warns once and switches
    writing off, but never raises into the training loop (PRD SAFE1).
    """

    def __init__(self, name: str, total: int | None = None, *, source: str = "library",
                 patience: int | None = None, monitor: str = "val", mode: str = "min",
                 run_dir: str | os.PathLike | None = None, tags: list[str] | None = None,
                 checkpoint_on_pause: bool = True, stop_on_patience: bool = False, clock=None, home: Path | None = None,
                 heartbeat: bool = True, heartbeat_s: float = HEARTBEAT_S, poll_s: float = POLL_S):
        from . import __version__

        if mode not in ("min", "max"):
            raise ValueError("mode must be 'min' or 'max'")
        self.name = name
        self.total = total
        self.patience = patience
        self.monitor = monitor
        self.mode = mode
        self.checkpoint_on_pause = checkpoint_on_pause
        self.stop_on_patience = stop_on_patience
        self._early_stop = False
        self.clock = clock or SystemClock()
        self.timer = Timer(self.clock)
        self.done = 0
        self.best: dict | None = None
        self.since_best = 0
        self.state = "running"
        self.last_seq = 0
        self.error: dict | None = None
        self._pause_wanted = False
        self._stop_wanted = False
        self._requests = 0      # pause/stop requests so far: each gets at most one checkpoint
        self._saved_for = 0
        self._checkpoint: Callable[[], Any] | None = None
        self._poll_s = poll_s
        self._last_poll: float | None = None
        self._ok = True
        self._metric_warned = False
        self._lock = threading.RLock()
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
            "library_version": __version__, "pause_mode": "cooperative", "tags": list(tags or []),
            "run_dir": os.fspath(run_dir) if run_dir is not None else None, "script": script,
        })
        self.event("started")
        self.write_status()
        _active.add(self)
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
            patience = ({"limit": self.patience, "since_best": self.since_best}
                        if self.patience else None)
            self._safe(_io.write_json, self.dir / "status.json", {
                "schema": SCHEMA, "run_id": self.run_id, "state": self.state,
                "epoch": self.done, "total_epochs": self.total, "step": None, "total_steps": None,
                "best": self.best, "patience": patience, "timing": timing, "eta_s": eta,
                "heartbeat": _iso(self.clock.wall()), "pid": self.pid, "pid_start": self.pid_start,
                "last_seq": self.last_seq, "error": self.error,
            })

    def _beat_loop(self, every: float) -> None:
        while not self._stop_beat.wait(every):
            self.write_status()

    # -- reporting -----------------------------------------------------------------

    def log(self, epoch: int, **metrics: Any) -> None:
        """Record the values of a finished epoch: ``run.log(epoch=e, train=tl, val=vl, lr=lr)``.

        ``epoch`` is the epoch just completed (counting from 0). Values that are not
        numbers are skipped with one warning; NaN is stored as null.
        """
        point: dict[str, Any] = {"t": self.clock.wall(), "epoch": int(epoch)}
        for k, v in metrics.items():
            if k in ("t", "epoch"):
                continue
            if _number(v):
                point[k] = v
            elif hasattr(v, "item"):  # a tensor or numpy scalar
                try:
                    point[k] = float(v.item())
                except Exception:
                    pass
            elif not self._metric_warned:
                self._metric_warned = True
                warnings.warn(f"epochcontrol: log() skips non-number value {k}={v!r}",
                              RuntimeWarning, stacklevel=2)
        self._safe(_io.append_jsonl, self.dir / "metrics.jsonl", point)
        value = point.get(self.monitor)
        if isinstance(value, (int, float)) and value == value:  # not NaN
            better = (self.best is None or
                      (value < self.best["value"] if self.mode == "min" else value > self.best["value"]))
            if better:
                self.best = {"value": value, "epoch": int(epoch), "monitor": self.monitor, "mode": self.mode}
                self.since_best = 0
            else:
                self.since_best += 1
        self.done = max(self.done, int(epoch) + 1)
        if (self.stop_on_patience and self.patience and self.since_best >= self.patience
                and not self._stop_wanted):
            # Early stopping: same path as Stop (checkpoint, then the loop ends), but the
            # run ends as finished, with the reason in the event log.
            self._stop_wanted = True
            self._early_stop = True
            self._requests += 1
            self.state = "stopping"
            self.event("stopping", detail=f"early stop: no improvement for {self.since_best} epochs "
                                          f"(patience {self.patience})")
        self.write_status()

    def step_done(self) -> None:
        self.done += 1

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
        self.event("command", by=c.get("by", "cli"), detail=str(cmd))
        if cmd in ("pause", "stop"):
            self._requests += 1
        if cmd == "pause":
            self._pause_wanted = True
        elif cmd == "resume":
            self._pause_wanted = False
        elif cmd == "stop":
            self._stop_wanted = True
            self._pause_wanted = False
            self.state = "stopping"
            self.event("stopping")
        self.write_status()

    def should_stop(self) -> bool:
        """True once Stop was pressed. Check it at an epoch boundary and break."""
        self.poll()
        return self._stop_wanted

    def on_checkpoint(self, fn: Callable[[], Any]) -> None:
        """Register how to save a checkpoint. Called on Stop (and on Pause, unless
        ``checkpoint_on_pause=False``), at the next epoch boundary."""
        self._checkpoint = fn

    def checkpoint_if_requested(self, save: Callable[[], Any] | None = None) -> bool:
        """Save now if a pause or stop is waiting and this command was not saved yet."""
        self.poll()
        wanted = self._stop_wanted or (self._pause_wanted and self.checkpoint_on_pause)
        fn = save or self._checkpoint
        if not wanted or fn is None or self._saved_for == self._requests:
            return False
        self._saved_for = self._requests
        try:
            fn()
        except Exception as e:  # a failed save must not kill the run either
            warnings.warn(f"epochcontrol: checkpoint failed ({e})", RuntimeWarning, stacklevel=2)
            self.event("checkpoint_saved", detail=f"failed: {type(e).__name__}: {e}")
            return False
        self.event("checkpoint_saved")
        return True

    def resume_from(self, path: str | os.PathLike, load: Callable[[Path], int]) -> int:
        """Load a checkpoint if it exists. ``load(path)`` returns the epoch to start from.
        Returns 0 when there is no checkpoint."""
        p = Path(path)
        if not p.exists():
            return 0
        start = int(load(p))
        self.done = max(self.done, start)
        self.event("resumed", detail=f"from checkpoint {p.name}, epoch {start}")
        self.write_status()
        return start

    def wait_if_paused(self) -> None:
        """Block while a pause is in force; returns at once otherwise."""
        self.poll()
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
        if self._stop_wanted:
            self.state = "stopping"
        else:
            self.state = "running"
            self.event("resumed")
        self.write_status()

    def epochs(self, start: int = 0) -> Iterator[int]:
        """Yield epoch numbers from ``start`` to ``total_epochs`` (forever if unknown).

        Between epochs it saves a checkpoint if one is due, waits while paused, and
        ends on Stop."""
        e = start
        while self.total is None or e < self.total:
            self.checkpoint_if_requested()
            self.wait_if_paused()
            if self._stop_wanted:
                return
            yield e
            self.done = max(self.done, e + 1)
            e += 1
        self.checkpoint_if_requested()

    def finish(self, state: str | None = None, error: BaseException | None = None) -> None:
        """End the run. Without arguments: stopped if Stop was pressed, else finished."""
        if self.state in ENDED:
            return
        if state is None:
            state = "stopped" if self._stop_wanted and not self._early_stop else "finished"
        self._stop_beat.set()
        if self._beat is not None and self._beat is not threading.current_thread():
            self._beat.join(timeout=2)
        self.timer.resume()
        if error is not None:
            self.error = {"type": type(error).__name__, "message": str(error)[:500]}
        self.state = state
        self.event(state, **({"detail": self.error["message"]} if self.error else {}))
        self.write_status()
        _active.discard(self)

    @property
    def timing(self) -> dict:
        """Wall, active, paused and slept seconds so far (PRD TIME4)."""
        return self.timer.snapshot()

    def __enter__(self) -> "Run":
        return self

    def __exit__(self, kind, value, tb) -> bool:
        if kind is None:
            self.finish()
        elif issubclass(kind, KeyboardInterrupt):
            self.finish("stopped")
        else:
            self.finish("failed", value)
        return False


# An uncaught exception marks every open run as failed, then Python reports it as usual
# (PRD LIB9). At exit, runs never finished are closed as stopped.
_prev_hook = sys.excepthook


def _excepthook(kind, value, tb):
    for run in list(_active):
        try:
            run.finish("stopped" if issubclass(kind, KeyboardInterrupt) else "failed", value)
        except Exception:
            pass
    _prev_hook(kind, value, tb)


sys.excepthook = _excepthook


@atexit.register
def _close_open_runs() -> None:
    for run in list(_active):
        try:
            run.finish()
        except Exception:
            pass


def start(name: str | None = None, total_epochs: int | None = None, **options) -> Run:
    """Start a run.

        run = epochcontrol.start(name="tft lumo s43", total_epochs=200, patience=40)
        for epoch in run.epochs():
            ...
            run.log(epoch=epoch, train=train_loss, val=val_loss)
        run.finish()

    Options: ``patience``, ``monitor`` (default "val"), ``mode`` ("min" or "max"),
    ``run_dir`` (your own output folder, shown in the app), ``tags``,
    ``checkpoint_on_pause`` (default True), ``stop_on_patience`` (default False: when
    True, the run ends once ``patience`` epochs pass without a better ``monitor`` value,
    saving the checkpoint first, as on Stop).
    """
    if name is None:
        name = Path(sys.argv[0]).stem if sys.argv and sys.argv[0] else "run"
    return Run(name, total_epochs, **options)
