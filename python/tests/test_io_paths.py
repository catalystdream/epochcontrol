import math
import os
import stat
import sys

from epochcontrol import _io, _paths, _proc


def test_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("EPOCHCONTROL_HOME", str(tmp_path))
    assert _paths.runs_dir() == tmp_path / "runs"


def test_default_paths(monkeypatch, tmp_path):
    monkeypatch.delenv("EPOCHCONTROL_HOME", raising=False)
    monkeypatch.setattr(_paths.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(sys, "platform", "darwin")
    assert _paths.runs_dir() == tmp_path / "Library/Application Support/EpochControl/runs"
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    assert _paths.runs_dir() == tmp_path / ".local/share/epochcontrol/runs"


def test_atomic_write_and_mode(tmp_path):
    p = tmp_path / "status.json"
    _io.write_json(p, {"a": 1, "loss": math.nan, "x": [math.inf]})
    assert _io.read_json(p) == {"a": 1, "loss": None, "x": [None]}
    assert stat.S_IMODE(os.stat(p).st_mode) == 0o600
    assert [f.name for f in tmp_path.iterdir()] == ["status.json"]  # no temp file left


def test_read_bad_json(tmp_path):
    p = tmp_path / "control.json"
    p.write_text('{"seq": ')
    assert _io.read_json(p) is None
    assert _io.read_json(tmp_path / "missing.json") is None


def test_process_start_time():
    import time

    t = _proc.start_time()
    assert 0 < t <= time.time() + 1
