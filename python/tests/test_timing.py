from epochcontrol._timing import Timer


def total(t):
    return t["active_s"] + t["paused_s"] + t["slept_s"]


def test_active_only(clock):
    t = Timer(clock)
    clock.advance(10)
    s = t.snapshot()
    assert s == {"wall_s": 10, "active_s": 10, "paused_s": 0, "slept_s": 0}


def test_mac_sleep_is_not_active(clock):
    t = Timer(clock)
    clock.advance(10)
    t.tick()
    clock.mac_sleep(3600)
    clock.advance(5)
    s = t.snapshot()
    assert s["slept_s"] == 3600 and s["active_s"] == 15 and s["wall_s"] == 3615
    assert abs(total(s) - s["wall_s"]) < 1e-6


def test_small_drift_is_not_sleep(clock):
    t = Timer(clock)
    clock.advance(1)
    clock.mac_sleep(2)  # under the 5 s threshold
    assert t.tick() == 0 and t.slept_s == 0


def test_pause_and_sleep_during_pause(clock):
    t = Timer(clock)
    clock.advance(10)
    t.pause()
    clock.advance(20)
    t.tick()
    clock.mac_sleep(600)  # lid closed while paused: slept, not paused
    clock.advance(5)
    t.resume()
    clock.advance(3)
    s = t.snapshot()
    assert s["paused_s"] == 25 and s["active_s"] == 13 and s["slept_s"] == 600
    assert abs(total(s) - s["wall_s"]) < 1e-6
