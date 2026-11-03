import os
import stat
import time
import warnings

import epochcontrol
from conftest import control, lines, read, run_dir


def run_loop(items, home, clock, **kw):
    return list(epochcontrol.loop(items, name="t", home=home, clock=clock, heartbeat=False, poll_s=0, **kw))


def test_plain_loop_finishes(home, clock, validate):
    assert run_loop(range(5), home, clock) == [0, 1, 2, 3, 4]
    d = run_dir(home)
    assert stat.S_IMODE(os.stat(d).st_mode) == 0o700
    meta, status = read(d / "meta.json"), read(d / "status.json")
    validate("meta", meta)
    validate("status", status)
    assert meta["source"] == "loop" and meta["total_epochs"] == 5 and meta["name"] == "t"
    assert status["state"] == "finished" and status["epoch"] == 5 and status["eta_s"] is None
    ev = lines(d / "events.jsonl")
    for e in ev:
        validate("events", e)
    assert [e["type"] for e in ev] == ["started", "finished"]


def test_generator_without_length(home, clock):
    assert run_loop((i for i in range(3)), home, clock) == [0, 1, 2]
    assert read(run_dir(home) / "meta.json")["total_epochs"] is None


def test_nothing_happens_until_iterated(home, clock):
    gen = epochcontrol.loop(range(3), home=home, clock=clock, heartbeat=False)
    assert not home.exists()
    gen.close()


def test_stop_command_ends_loop_cleanly(home, clock, validate):
    seen = []
    for i in epochcontrol.loop(range(10), name="t", home=home, clock=clock, heartbeat=False, poll_s=0):
        seen.append(i)
        if i == 2:
            control(home, "stop", 1, by="app")
    after_loop = True  # code after the loop still runs
    assert seen == [0, 1, 2] and after_loop
    d = run_dir(home)
    status = read(d / "status.json")
    validate("status", status)
    assert status["state"] == "stopped" and status["epoch"] == 3 and status["last_seq"] == 1
    cmd = [e for e in lines(d / "events.jsonl") if e["type"] == "command"]
    assert cmd == [{"t": cmd[0]["t"], "type": "command", "by": "app", "detail": "stop"}]


def test_pause_then_resume(home, clock):
    def resume_later(n):
        if n == 3:  # resume after 3 pause polls (1.5 s)
            control(home, "resume", 2)

    clock.on_sleep = resume_later
    seen = []
    for i in epochcontrol.loop(range(4), name="t", home=home, clock=clock, heartbeat=False, poll_s=0):
        seen.append(i)
        clock.advance(1)
        if i == 0:
            control(home, "pause", 1)
    assert seen == [0, 1, 2, 3]
    d = run_dir(home)
    status = read(d / "status.json")
    assert status["state"] == "finished"
    assert status["timing"]["paused_s"] == 1.5 and status["timing"]["active_s"] == 4
    types = [e["type"] for e in lines(d / "events.jsonl")]
    assert types == ["started", "command", "paused", "command", "resumed", "finished"]


def test_old_command_is_not_applied_twice(home, clock):
    seen = []
    clock.on_sleep = lambda n: control(home, "resume", 2) if n == 1 else None
    for i in epochcontrol.loop(range(5), name="t", home=home, clock=clock, heartbeat=False, poll_s=0):
        seen.append(i)
        if i == 0:
            control(home, "pause", 1)
        if i == 2:
            control(home, "pause", 1)  # same seq again: ignored
    assert seen == [0, 1, 2, 3, 4] and clock.sleeps == 1


def test_stop_while_paused(home, clock):
    clock.on_sleep = lambda n: control(home, "stop", 2) if n == 2 else None
    seen = []
    for i in epochcontrol.loop(range(5), name="t", home=home, clock=clock, heartbeat=False, poll_s=0):
        seen.append(i)
        if i == 1:
            control(home, "pause", 1)
    assert seen == [0, 1]
    assert read(run_dir(home) / "status.json")["state"] == "stopped"


def test_user_break_marks_stopped(home, clock):
    for i in epochcontrol.loop(range(10), name="t", home=home, clock=clock, heartbeat=False, poll_s=0):
        if i == 3:
            break
    status = read(run_dir(home) / "status.json")
    assert status["state"] == "stopped" and status["epoch"] == 3


def test_eta_uses_active_time(home, clock):
    from epochcontrol._run import Run

    r = Run("eta", 10, clock=clock, home=home, heartbeat=False)
    for _ in range(4):
        clock.advance(2)
        r.step_done()
    clock.mac_sleep(3600)  # must not inflate the ETA
    r.write_status()
    s = read(r.dir / "status.json")
    assert s["eta_s"] == 12 and s["timing"]["slept_s"] == 3600
    assert [e["type"] for e in lines(r.dir / "events.jsonl")][-1] == "slept"
    r.finish()


def test_unwritable_folder_never_breaks_training(tmp_path, clock):
    ro = tmp_path / "ro"
    ro.mkdir()
    os.chmod(ro, 0o500)
    try:
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            out = list(epochcontrol.loop(range(3), name="t", home=ro / "runs", clock=clock, heartbeat=False))
        assert out == [0, 1, 2]
        assert len([x for x in w if issubclass(x.category, RuntimeWarning)]) == 1
    finally:
        os.chmod(ro, 0o700)


def test_heartbeat_thread_updates_status(home):
    gen = epochcontrol.loop(range(2), name="t", home=home, heartbeat_s=0.05)
    next(gen)
    d = run_dir(home)
    first = read(d / "status.json")["timing"]["wall_s"]
    time.sleep(0.3)
    assert read(d / "status.json")["timing"]["wall_s"] > first
    gen.close()
    assert read(d / "status.json")["state"] == "stopped"


def test_overhead_is_small(home):
    n = 200_000
    t0 = time.perf_counter()
    for _ in epochcontrol.loop(range(n), name="t", home=home):
        pass
    per_item = (time.perf_counter() - t0) / n
    assert per_item < 20e-6, per_item  # far below NF1's 1 ms per log call
