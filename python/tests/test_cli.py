import json
import os
import threading
import time
from pathlib import Path

import pytest

import epochcontrol
from epochcontrol import _cli, _io
from epochcontrol._guide import GUIDE
from conftest import read

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def env_home(tmp_path, monkeypatch):
    monkeypatch.setenv("EPOCHCONTROL_HOME", str(tmp_path))
    return tmp_path / "runs"


def cli(capsys, *args):
    code = _cli.main(list(args))
    out = capsys.readouterr()
    return code, out.out, out.err


def new_run(name="r", total=10):
    return epochcontrol.start(name=name, total_epochs=total, heartbeat=False)


def snapshot(home):
    return {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in home.rglob("*") if p.is_file()}


def test_ls_and_status_json_follow_schema(env_home, capsys, validate):
    a = new_run("alpha")
    a.log(epoch=0, val=0.5)
    b = new_run("beta")
    b.finish()
    code, out, _ = cli(capsys, "ls", "--json")
    runs = json.loads(out)
    validate("cli", runs)
    assert code == 0 and {r["name"]: r["state"] for r in runs} == {"alpha": "running", "beta": "finished"}
    code, out, _ = cli(capsys, "status", "alpha", "--json")
    validate("cli", json.loads(out))
    assert json.loads(out)["epoch"] == 1
    a.finish()


def test_reading_never_writes(env_home, capsys):
    run = new_run()
    before = snapshot(env_home)
    for args in (("ls",), ("ls", "--json"), ("status", "--json"), ("status", run.run_id[:12])):
        cli(capsys, *args)
    assert snapshot(env_home) == before
    run.finish()


def test_pause_resume_stop_round_trip(env_home, capsys, validate):
    run = new_run()
    stop = threading.Event()

    def worker():  # stands in for the training loop
        while not stop.is_set():
            run.poll(force=True)
            time.sleep(0.02)

    t = threading.Thread(target=worker)
    t.start()
    try:
        code, out, _ = cli(capsys, "pause", "--json", "--by", "agent")
        res = json.loads(out)
        validate("cli", res)
        assert code == 0 and res == {"run_id": run.run_id, "command": "pause", "seq": 1, "applied": True}
        ctl = read(Path(run.dir) / "control.json")
        validate("control", ctl)
        assert ctl["by"] == "agent"
        code, out, _ = cli(capsys, "resume", run.name, "--json")
        assert code == 3  # not paused: the worker only polls, it never enters the pause
    finally:
        stop.set()
        t.join()
    code, out, _ = cli(capsys, "stop", "--json", "--wait", "0")
    assert code == 0 and json.loads(out)["seq"] == 2 and json.loads(out)["applied"] is False
    run.finish()


def test_exit_codes(env_home, capsys, validate):
    code, out, _ = cli(capsys, "stop", "--json")
    assert code == 2 and json.loads(out)["code"] == "not_found"
    validate("cli", json.loads(out))
    a, b = new_run("a"), new_run("b")
    code, out, _ = cli(capsys, "pause", "--json")
    assert code == 4 and json.loads(out)["code"] == "ambiguous"
    a.finish()
    b.finish()
    code, out, _ = cli(capsys, "stop", "a", "--json")
    assert code == 3 and json.loads(out)["code"] == "refused"
    code, _, err = cli(capsys, "status", "nope")
    assert code == 2 and "no run" in err


def test_lost_and_stalled(env_home, capsys):
    run = new_run("gone")
    s = read(run.dir / "status.json")
    _io.write_json(run.dir / "status.json", {**s, "heartbeat": "2026-01-01T00:00:00+01:00"})
    assert _cli.summarise(run.dir)["state"] == "stalled"  # this process is alive
    _io.write_json(run.dir / "status.json", {**s, "heartbeat": "2026-01-01T00:00:00+01:00", "pid": 2**22 + 12345})
    assert _cli.summarise(run.dir)["state"] == "lost"
    _io.write_json(run.dir / "status.json", {**s, "heartbeat": "2026-01-01T00:00:00+01:00", "pid_start": 1.0})
    assert _cli.summarise(run.dir)["state"] == "lost"  # pid reused by another process
    run.finish()


def test_table_output(env_home, capsys):
    run = new_run("table run")
    run.log(epoch=0, val=0.25)
    code, out, _ = cli(capsys, "ls")
    assert code == 0 and "table run" in out and "0.25 @0" in out and "1/10" in out
    run.finish()


def test_agent_guide_matches_llms_txt(capsys):
    code, out, _ = cli(capsys, "agent-guide")
    assert code == 0 and out == GUIDE + "\n"
    assert (ROOT / "docs" / "llms.txt").read_text() == out
    assert "approval" in GUIDE  # PRD AG14


# -- groups in the CLI (PRD GRP1) and wait (AG9) ------------------------------------

def test_ls_and_status_show_the_group(env_home, capsys, validate):
    plain = new_run("plain")
    grouped = epochcontrol.start(name="seed42", total_epochs=5, heartbeat=False, group="sweep A1", group_total=9)
    code, out, _ = cli(capsys, "ls", "--json")
    runs = json.loads(out)
    validate("cli", runs)
    assert {r["name"]: r["group"] for r in runs} == {"seed42": {"name": "sweep A1", "total": 9}, "plain": None}
    code, out, _ = cli(capsys, "ls")
    header, *rows = out.splitlines()
    assert "GROUP" in header and any("sweep A1" in r for r in rows)
    plain.finish()
    grouped.finish()


def test_ls_has_no_group_column_without_groups(env_home, capsys):
    run = new_run("plain")
    code, out, _ = cli(capsys, "ls")
    assert "GROUP" not in out.splitlines()[0]
    run.finish()


def test_wait_returns_when_the_run_ends(env_home, capsys, validate):
    run = new_run("long")
    threading.Timer(0.4, run.finish).start()
    t0 = time.monotonic()
    code, out, _ = cli(capsys, "wait", run.run_id, "--json", "--interval", "0.05")
    result = json.loads(out)
    validate("cli", result)
    assert code == 0 and result["state"] == "finished" and time.monotonic() - t0 < 5


def test_wait_on_an_ended_run_returns_at_once(env_home, capsys):
    run = new_run("done")
    run.finish(state="failed")
    code, out, _ = cli(capsys, "wait", "done")
    assert code == 0 and "failed" in out


def test_wait_times_out_and_never_writes(env_home, capsys, validate):
    run = new_run("still going")
    before = snapshot(env_home)
    code, out, _ = cli(capsys, "wait", run.run_id, "--json", "--timeout", "0.3", "--interval", "0.05")
    result = json.loads(out)
    validate("cli", result)
    assert code == 5 and result["code"] == "timeout"
    assert snapshot(env_home) == before  # reading never writes (PRD AG11)
    run.finish()
