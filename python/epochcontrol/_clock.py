"""Clocks. Timing code takes a clock object so tests can inject time (CLAUDE.md rule)."""

from __future__ import annotations

import time


class SystemClock:
    """wall: seconds since the epoch, counts Mac sleep. monotonic: does not count sleep on
    macOS (mach_absolute_time) or Linux (CLOCK_MONOTONIC)."""

    def wall(self) -> float:
        return time.time()

    def monotonic(self) -> float:
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)
