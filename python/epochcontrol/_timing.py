"""Honest timing: wall = active + paused + slept (PRD TIME1, TIME2)."""

from __future__ import annotations

SLEEP_GAP_S = 5.0  # wall ahead of monotonic by more than this between two ticks = the machine slept


class Timer:
    def __init__(self, clock, sleep_gap: float = SLEEP_GAP_S):
        self._clock = clock
        self._gap = sleep_gap
        self._w0 = self._last_w = clock.wall()
        self._m0 = self._last_m = clock.monotonic()
        self.slept_s = 0.0
        self._paused_s = 0.0
        self._pause_from: float | None = None

    def tick(self) -> float:
        """Compare the two clocks since the last tick. Returns seconds slept, or 0."""
        w, m = self._clock.wall(), self._clock.monotonic()
        gap = (w - self._last_w) - (m - self._last_m)
        self._last_w, self._last_m = w, m
        if gap > self._gap:
            self.slept_s += gap
            return gap
        return 0.0

    def pause(self) -> None:
        if self._pause_from is None:
            self._pause_from = self._clock.monotonic()

    def resume(self) -> None:
        if self._pause_from is not None:
            self._paused_s += self._clock.monotonic() - self._pause_from
            self._pause_from = None

    @property
    def paused(self) -> bool:
        return self._pause_from is not None

    def snapshot(self) -> dict:
        """Times in seconds. Sleep during a pause counts as slept, not paused."""
        self.tick()
        m = self._clock.monotonic()
        paused = self._paused_s + (m - self._pause_from if self._pause_from is not None else 0.0)
        return {
            "wall_s": max(0.0, self._clock.wall() - self._w0),
            "active_s": max(0.0, (m - self._m0) - paused),
            "paused_s": max(0.0, paused),
            "slept_s": self.slept_s,
        }
