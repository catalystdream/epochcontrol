"""Groups: runs started by one script, e.g. a bash loop (PRD GRP1)."""

import epochcontrol
from conftest import read, run_dir


def meta_of(home, clock, **kw):
    run = epochcontrol.start(name="s", home=home, clock=clock, heartbeat=False, poll_s=0, **kw)
    run.finish()
    return read(run_dir(home) / "meta.json")


def test_group_from_the_environment(home, clock, validate, monkeypatch):
    monkeypatch.setenv("EPOCHCONTROL_GROUP", "  aeroconf A1 ")
    monkeypatch.setenv("EPOCHCONTROL_GROUP_TOTAL", "9")
    meta = meta_of(home, clock)
    validate("meta", meta)
    assert meta["group"] == {"name": "aeroconf A1", "total": 9}


def test_arguments_win_over_the_environment(home, clock, validate, monkeypatch):
    monkeypatch.setenv("EPOCHCONTROL_GROUP", "from env")
    monkeypatch.setenv("EPOCHCONTROL_GROUP_TOTAL", "9")
    meta = meta_of(home, clock, group="sweep", group_total=4)
    validate("meta", meta)
    assert meta["group"] == {"name": "sweep", "total": 4}


def test_no_group_is_null(home, clock, validate, monkeypatch):
    monkeypatch.delenv("EPOCHCONTROL_GROUP", raising=False)
    meta = meta_of(home, clock)
    validate("meta", meta)
    assert meta["group"] is None


def test_a_bad_total_is_dropped_never_raised(home, clock, validate, monkeypatch):
    monkeypatch.setenv("EPOCHCONTROL_GROUP", "g")
    for bad in ("nine", "0", "-3", ""):
        monkeypatch.setenv("EPOCHCONTROL_GROUP_TOTAL", bad)
        meta = meta_of(home, clock)
        validate("meta", meta)
        assert meta["group"] == {"name": "g", "total": None}
        for d in list(home.iterdir()):  # one run folder per round
            for f in d.iterdir():
                f.unlink()
            d.rmdir()
    assert meta_of(home, clock, group="g", group_total=True)["group"]["total"] is None


def test_loop_passes_the_group_on(home, clock, monkeypatch):
    monkeypatch.setenv("EPOCHCONTROL_GROUP", "loop group")
    monkeypatch.delenv("EPOCHCONTROL_GROUP_TOTAL", raising=False)
    for _ in epochcontrol.loop(range(2), name="l", home=home, clock=clock, heartbeat=False, poll_s=0):
        pass
    assert read(run_dir(home) / "meta.json")["group"] == {"name": "loop group", "total": None}
