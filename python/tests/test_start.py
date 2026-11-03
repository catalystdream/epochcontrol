import json
import math
import subprocess
import sys
import textwrap
import warnings

import pytest

import epochcontrol
from conftest import control, lines, read, run_dir


def start(home, clock, **kw):
    return epochcontrol.start(name="s", home=home, clock=clock, heartbeat=False, poll_s=0, **kw)


def test_log_best_patience_and_metrics(home, clock, validate):
    run = start(home, clock, total_epochs=6, patience=3)
    vals = [0.9, 0.5, 0.6, 0.4, 0.7, math.nan]
    for e in run.epochs():
        clock.advance(10)
        run.log(epoch=e, train=1.0 - e / 10, val=vals[e], lr=1e-3, grad_norm=2)
    run.finish()
    d = run_dir(home)
    s = read(d / "status.json")
    validate("status", s)
    assert s["state"] == "finished" and s["epoch"] == 6
    assert s["best"] == {"value": 0.4, "epoch": 3, "monitor": "val", "mode": "min"}
    assert s["patience"] == {"limit": 3, "since_best": 1}  # NaN epoch does not count
    m = lines(d / "metrics.jsonl")
    for point in m:
        validate("metrics", point)
    assert m[5]["val"] is None and m[0]["grad_norm"] == 2


def test_mode_max_and_tensor_like_values(home, clock):
    class Scalar:
        def __init__(self, v):
            self.v = v

        def item(self):
            return self.v

    run = start(home, clock, total_epochs=3, monitor="acc", mode="max")
    for e, acc in zip(run.epochs(), [0.5, 0.8, 0.7]):
        run.log(epoch=e, acc=Scalar(acc))
    run.finish()
    assert read(run_dir(home) / "status.json")["best"]["value"] == 0.8


def test_non_number_skipped_with_one_warning(home, clock):
    run = start(home, clock, total_epochs=2)
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        run.log(epoch=0, val=1.0, note="hello")
        run.log(epoch=1, val=1.0, note="again")
    run.finish()
    assert len(w) == 1
    assert "note" not in lines(run_dir(home) / "metrics.jsonl")[0]


def test_stop_saves_checkpoint_then_ends(home, clock):
    run = start(home, clock, total_epochs=10)
    saved = []
    run.on_checkpoint(lambda: saved.append(run.done))
    seen = []
    for e in run.epochs():
        seen.append(e)
        run.log(epoch=e, val=1.0)
        if e == 2:
            control(home, "stop", 1)
    run.finish()
    assert seen == [0, 1, 2] and saved == [3]
    d = run_dir(home)
    assert read(d / "status.json")["state"] == "stopped"
    assert [e["type"] for e in lines(d / "events.jsonl")].count("checkpoint_saved") == 1


def test_pause_saves_once_and_can_be_switched_off(home, clock):
    for on_pause, expected in ((True, 1), (False, 0)):
        saved = []
        clock.on_sleep = None
        clock.sleeps = 0
        run = start(home / str(on_pause), clock, total_epochs=3, checkpoint_on_pause=on_pause)
        run.on_checkpoint(lambda: saved.append(1))
        clock.on_sleep = lambda n, h=home / str(on_pause): control(h, "resume", 2) if n == 2 else None
        for e in run.epochs():
            if e == 0:
                control(home / str(on_pause), "pause", 1)
        run.finish()
        assert len(saved) == expected


def test_failed_checkpoint_does_not_kill_the_run(home, clock):
    run = start(home, clock, total_epochs=5)
    run.on_checkpoint(lambda: 1 / 0)
    with warnings.catch_warnings(record=True):
        warnings.simplefilter("always")
        for e in run.epochs():
            if e == 1:
                control(home, "stop", 1)
    run.finish()
    ev = lines(run_dir(home) / "events.jsonl")
    assert any(e["type"] == "checkpoint_saved" and e["detail"].startswith("failed") for e in ev)


def test_resume_from(home, clock, tmp_path):
    ckpt = tmp_path / "ckpt.pt"
    run = start(home, clock, total_epochs=10)
    assert run.resume_from(ckpt, lambda p: 99) == 0
    ckpt.write_text("x")
    assert run.resume_from(ckpt, lambda p: 7) == 7
    assert list(run.epochs(start=7)) == [7, 8, 9]
    run.finish()
    assert read(run_dir(home) / "status.json")["epoch"] == 10


def test_explicit_api_without_iterator(home, clock):
    run = start(home, clock, total_epochs=100)
    seen = []
    for e in range(100):
        seen.append(e)
        run.log(epoch=e, val=1.0)
        if e == 4:
            control(home, "stop", 1)
        run.checkpoint_if_requested(lambda: None)
        if run.should_stop():
            break
        run.wait_if_paused()
    run.finish()
    assert seen == [0, 1, 2, 3, 4]


def test_context_manager_marks_failure(home, clock, validate):
    with pytest.raises(ZeroDivisionError):
        with start(home, clock, total_epochs=5) as run:
            for e in run.epochs():
                run.log(epoch=e, val=1.0)
                if e == 1:
                    1 / 0
    s = read(run_dir(home) / "status.json")
    validate("status", s)
    assert s["state"] == "failed" and s["error"]["type"] == "ZeroDivisionError"


def test_uncaught_exception_marks_failed_in_a_real_process(tmp_path):
    code = textwrap.dedent("""
        import epochcontrol
        run = epochcontrol.start(name="crash", total_epochs=5)
        for e in run.epochs():
            run.log(epoch=e, val=1.0)
            if e == 2:
                raise RuntimeError("boom")
    """)
    env = {"EPOCHCONTROL_HOME": str(tmp_path), "PATH": "/usr/bin:/bin"}
    p = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True)
    assert p.returncode == 1 and "boom" in p.stderr  # Python still reports the error
    s = read(run_dir(tmp_path / "runs") / "status.json")
    assert s["state"] == "failed" and s["error"]["message"] == "boom"


def test_forgotten_finish_is_closed_at_exit(tmp_path):
    code = "import epochcontrol\nrun = epochcontrol.start(name='x', total_epochs=2)\nrun.log(epoch=0, val=1)\n"
    subprocess.run([sys.executable, "-c", code], env={"EPOCHCONTROL_HOME": str(tmp_path)}, check=True)
    assert read(run_dir(tmp_path / "runs") / "status.json")["state"] == "finished"


def test_import_has_no_heavy_dependencies():
    code = "import sys, epochcontrol; bad=[m for m in ('torch','jax','tensorflow','numpy') if m in sys.modules]; print(bad)"
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout
    assert out.strip() == "[]"


def test_stop_on_patience_ends_as_finished(home, clock):
    run = start(home, clock, total_epochs=100, patience=3, stop_on_patience=True)
    saved = []
    run.on_checkpoint(lambda: saved.append(run.done))
    vals = [0.5, 0.4, 0.45, 0.46, 0.47, 0.3]  # best at epoch 1, then 3 epochs without improvement
    seen = []
    for e in run.epochs():
        seen.append(e)
        run.log(epoch=e, val=vals[e])
    run.finish()
    assert seen == [0, 1, 2, 3, 4] and saved == [5]
    d = run_dir(home)
    s = read(d / "status.json")
    assert s["state"] == "finished" and s["patience"] == {"limit": 3, "since_best": 3}
    stop = [e for e in lines(d / "events.jsonl") if e["type"] == "stopping"]
    assert len(stop) == 1 and "early stop" in stop[0]["detail"]


def test_patience_without_stop_only_reports(home, clock):
    run = start(home, clock, total_epochs=8, patience=2)
    for e in run.epochs():
        run.log(epoch=e, val=1.0 + e)  # never improves after epoch 0
    run.finish()
    s = read(run_dir(home) / "status.json")
    assert s["state"] == "finished" and s["epoch"] == 8 and s["patience"]["since_best"] == 7
