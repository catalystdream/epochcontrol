import epochcontrol
from epochcontrol import _app


def test_only_on_a_mac_with_a_screen():
    assert _app.should_open({}, "darwin")
    assert not _app.should_open({}, "linux")
    assert not _app.should_open({"EPOCHCONTROL_NO_APP": "1"}, "darwin")
    assert not _app.should_open({"SSH_CONNECTION": "1.2.3.4 5 6.7.8.9 22"}, "darwin")


def test_a_run_opens_the_app_once_in_the_background(home, clock, monkeypatch):
    calls = []
    monkeypatch.delenv("EPOCHCONTROL_NO_APP")
    monkeypatch.setattr(_app, "_tried", False)
    monkeypatch.setattr(_app.sys, "platform", "darwin")
    monkeypatch.setattr(_app, "_spawn", calls.append)
    for _ in range(2):
        list(epochcontrol.loop(range(2), home=home, clock=clock, heartbeat=False))
    assert calls == [["open", "-g", "-b", _app.BUNDLE_ID]]


def test_failure_to_open_never_breaks_the_run(home, clock, monkeypatch):
    monkeypatch.delenv("EPOCHCONTROL_NO_APP")
    monkeypatch.setattr(_app, "_tried", False)
    monkeypatch.setattr(_app.sys, "platform", "darwin")

    def boom(*a, **k):
        raise FileNotFoundError("open")

    monkeypatch.setattr(_app, "_spawn", boom)
    assert list(epochcontrol.loop(range(3), home=home, clock=clock, heartbeat=False)) == [0, 1, 2]


def test_can_be_switched_off_per_run(home, clock, monkeypatch):
    calls = []
    monkeypatch.delenv("EPOCHCONTROL_NO_APP")
    monkeypatch.setattr(_app, "_tried", False)
    monkeypatch.setattr(_app.sys, "platform", "darwin")
    monkeypatch.setattr(_app, "_spawn", calls.append)
    run = epochcontrol.start(name="x", home=home, clock=clock, heartbeat=False, open_app=False)
    run.finish()
    assert calls == []
