"""The ``epochcontrol`` command. Reading commands never write (PRD AG11).

Exit codes: 0 done, 1 error, 2 not found, 3 refused, 4 ambiguous run (PRD AG8).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

from . import _io, _proc
from ._paths import runs_dir
from ._run import ENDED, HEARTBEAT_S

STALE_S = 3 * HEARTBEAT_S
LIVE = ("starting", "running", "paused", "stopping")
OK, ERROR, NOT_FOUND, REFUSED, AMBIGUOUS = 0, 1, 2, 3, 4


def _alive(pid: int | None, pid_start: float | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False  # another user's process: never ours
    if pid_start:
        now_start = _proc.start_time(pid)
        if now_start and abs(now_start - pid_start) > 2:
            return False  # the pid was reused (PRD CTL6)
    return True


def summarise(d: Path, now: float | None = None) -> dict | None:
    """One run as shown to people and agents, with lost and stalled worked out (PRD §11)."""
    meta = _io.read_json(d / "meta.json")
    if not isinstance(meta, dict):
        return None
    status = _io.read_json(d / "status.json") or {}
    now = time.time() if now is None else now
    age = None
    if status.get("heartbeat"):
        try:
            age = max(0.0, now - datetime.fromisoformat(status["heartbeat"]).timestamp())
        except ValueError:
            pass
    state = status.get("state", "starting")
    if state in LIVE and (age is None or age > STALE_S):
        if not _alive(status.get("pid", meta.get("pid")), status.get("pid_start", meta.get("pid_start"))):
            state = "lost"
        else:
            ctl = _io.read_json(d / "control.json") or {}
            os_paused = ctl.get("mode") == "os" and ctl.get("command") == "pause"
            state = "paused" if os_paused else "stalled"
    return {
        "run_id": meta.get("run_id", d.name), "name": meta.get("name", ""), "state": state,
        "epoch": status.get("epoch"), "total_epochs": status.get("total_epochs", meta.get("total_epochs")),
        "best": status.get("best"), "patience": status.get("patience"), "timing": status.get("timing"),
        "eta_s": status.get("eta_s"), "heartbeat_age_s": age, "pid": status.get("pid", meta.get("pid")),
        "started_at": meta.get("started_at"), "dir": str(d),
    }


def all_runs(home: Path | None = None) -> list[dict]:
    root = Path(home) if home else runs_dir()
    if not root.is_dir():
        return []
    runs = [summarise(d) for d in sorted(root.iterdir(), reverse=True) if d.is_dir()]
    return [r for r in runs if r]


def find(runs: list[dict], ref: str | None) -> tuple[dict | None, int, str]:
    """By run id, a unique id prefix, or a name (newest live one). No ref: the only live run."""
    if ref is None:
        live = [r for r in runs if r["state"] in LIVE]
        if len(live) == 1:
            return live[0], OK, ""
        if not live:
            return None, NOT_FOUND, "no run in progress"
        return None, AMBIGUOUS, f"{len(live)} runs in progress, name one: " + ", ".join(r["run_id"] for r in live)
    exact = [r for r in runs if r["run_id"] == ref]
    if exact:
        return exact[0], OK, ""
    pref = [r for r in runs if r["run_id"].startswith(ref)]
    if len(pref) == 1:
        return pref[0], OK, ""
    named = [r for r in runs if r["name"] == ref]
    live_named = [r for r in named if r["state"] in LIVE]
    if live_named or named:
        return (live_named or named)[0], OK, ""
    if len(pref) > 1:
        return None, AMBIGUOUS, f"'{ref}' matches {len(pref)} runs"
    return None, NOT_FOUND, f"no run '{ref}'"


def send(run: dict, command: str, by: str = "cli", wait_s: float = 3.0) -> dict:
    """Write control.json with the next seq, then wait briefly for the run to confirm."""
    d = Path(run["dir"])
    ctl = _io.read_json(d / "control.json") or {}
    status = _io.read_json(d / "status.json") or {}
    seq = max(int(ctl.get("seq", 0) or 0), int(status.get("last_seq", 0) or 0)) + 1
    _io.write_json(d / "control.json", {
        "schema": 1, "command": command, "seq": seq, "by": by, "mode": "cooperative",
        "issued_at": datetime.now().astimezone().isoformat(timespec="seconds")})
    deadline = time.monotonic() + wait_s
    applied = False
    while time.monotonic() < deadline:
        s = _io.read_json(d / "status.json") or {}
        if int(s.get("last_seq", 0) or 0) >= seq:
            applied = True
            break
        time.sleep(0.1)
    return {"run_id": run["run_id"], "command": command, "seq": seq, "applied": applied}


def _fmt_s(s) -> str:
    if s is None:
        return "-"
    s = int(s)
    return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def _print_table(runs: list[dict]) -> None:
    if not runs:
        print("no runs")
        return
    rows = [("RUN", "NAME", "STATE", "EPOCH", "ACTIVE", "ETA", "BEST")]
    for r in runs:
        ep = f"{r['epoch']}/{r['total_epochs']}" if r["total_epochs"] else str(r["epoch"] if r["epoch"] is not None else "-")
        best = f"{r['best']['value']:.4g} @{r['best']['epoch']}" if r.get("best") else "-"
        rows.append((r["run_id"], r["name"][:28], r["state"], ep,
                     _fmt_s((r["timing"] or {}).get("active_s")), _fmt_s(r["eta_s"]), best))
    w = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    for row in rows:
        print("  ".join(c.ljust(w[i]) for i, c in enumerate(row)).rstrip())


def _fail(args, code: int, message: str) -> int:
    names = {NOT_FOUND: "not_found", REFUSED: "refused", AMBIGUOUS: "ambiguous"}
    if args.json:
        print(json.dumps({"error": message, "code": names.get(code, "refused")}))
    else:
        print(f"epochcontrol: {message}", file=sys.stderr)
    return code


def main(argv: list[str] | None = None) -> int:
    from . import __version__
    from ._guide import GUIDE

    p = argparse.ArgumentParser(prog="epochcontrol", description="See and control training runs.")
    p.add_argument("--version", action="version", version=f"epochcontrol {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("ls", help="list runs, newest first")
    ls.add_argument("-n", type=int, default=20, help="how many (default 20, 0 = all)")
    st = sub.add_parser("status", help="one run in detail")
    st.add_argument("run", nargs="?", help="run id, id prefix or name (default: the only live run)")
    for c in ("pause", "resume", "stop"):
        sp = sub.add_parser(c, help=f"{c} a run (acts between iterations)")
        sp.add_argument("run", nargs="?", help="run id, id prefix or name (default: the only live run)")
        sp.add_argument("--by", choices=["cli", "agent"], default="cli", help="who sends it (recorded)")
        sp.add_argument("--wait", type=float, default=3.0, help="seconds to wait for the run to confirm")
    sub.add_parser("agent-guide", help="instructions for coding agents")
    for sp in (ls, st, *[sub.choices[c] for c in ("pause", "resume", "stop")]):
        sp.add_argument("--json", action="store_true", help="machine-readable output")
    args = p.parse_args(argv)

    if args.cmd == "agent-guide":
        print(GUIDE)
        return OK
    runs = all_runs()
    if args.cmd == "ls":
        shown = runs if args.n == 0 else runs[: args.n]
        print(json.dumps(shown, indent=2)) if args.json else _print_table(shown)
        return OK
    run, code, message = find(runs, args.run)
    if run is None:
        return _fail(args, code, message)
    if args.cmd == "status":
        print(json.dumps(run, indent=2)) if args.json else _print_table([run])
        return OK
    if run["state"] not in ("running", "paused", "stopping", "starting"):
        return _fail(args, REFUSED, f"run {run['run_id']} is {run['state']}")
    if args.cmd == "resume" and run["state"] != "paused":
        return _fail(args, REFUSED, f"run {run['run_id']} is not paused")
    result = send(run, args.cmd, by=args.by, wait_s=args.wait)
    if args.json:
        print(json.dumps(result))
    else:
        note = "done" if result["applied"] else "sent; it applies at the next iteration"
        print(f"{args.cmd} {run['run_id']} ({run['name']}): {note}")
    return OK


if __name__ == "__main__":
    sys.exit(main())
