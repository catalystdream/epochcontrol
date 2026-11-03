import json
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def _no_app(monkeypatch):
    """Tests never start the Mac app."""
    monkeypatch.setenv("EPOCHCONTROL_NO_APP", "1")

SCHEMAS = Path(__file__).resolve().parents[2] / "schemas"


class FakeClock:
    """Injected time. ``advance`` moves both clocks; ``mac_sleep`` only the wall clock,
    as a closed lid does. ``on_sleep`` lets a test act while the loop waits."""

    def __init__(self, wall=1_793_000_000.0):
        self.w, self.m = wall, 1000.0
        self.on_sleep = None
        self.sleeps = 0

    def wall(self):
        return self.w

    def monotonic(self):
        return self.m

    def advance(self, s):
        self.w += s
        self.m += s

    def mac_sleep(self, s):
        self.w += s

    def sleep(self, s):
        self.advance(s)
        self.sleeps += 1
        if self.on_sleep:
            self.on_sleep(self.sleeps)


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def home(tmp_path):
    return tmp_path / "runs"


@pytest.fixture
def validate():
    from jsonschema import Draft202012Validator, FormatChecker

    def check(kind, obj):
        schema = json.loads((SCHEMAS / f"{kind}.schema.json").read_text())
        errors = [e.message for e in Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(obj)]
        assert not errors, (kind, errors, obj)

    return check


def run_dir(home):
    (d,) = list(home.iterdir())
    return d


def read(path):
    return json.loads(path.read_text())


def lines(path):
    return [json.loads(l) for l in path.read_text().splitlines()]


def control(home, command, seq, by="cli"):
    from epochcontrol._io import write_json

    write_json(run_dir(home) / "control.json", {"schema": 1, "command": command, "seq": seq,
                                                "issued_at": "2026-11-03T12:00:00+01:00",
                                                "by": by, "mode": "cooperative"})
