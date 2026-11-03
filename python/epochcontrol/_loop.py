"""``loop()``: one line, like tqdm (PRD LIB0)."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterable, Iterator, TypeVar

from ._run import Run

T = TypeVar("T")


def loop(iterable: Iterable[T], name: str | None = None, total: int | None = None,
         **options) -> Iterator[T]:
    """Yield the items of ``iterable`` while reporting progress, and obey commands.

    Pause and stop take effect between items: a paused loop does not hand over the
    next item until resumed; a stopped loop ends, and the code after it still runs.
    ``status.json`` counts completed items in ``epoch``.

    ``options`` are passed to the run (for tests: ``clock``, ``home``, ``heartbeat``,
    ``poll_s``).
    """
    if total is None:
        try:
            total = len(iterable)  # type: ignore[arg-type]
        except TypeError:
            total = None
    if name is None:
        name = Path(sys.argv[0]).stem if sys.argv and sys.argv[0] else "loop"
    run = Run(name, total, source="loop", **options)
    finished = False
    try:
        first = True
        for item in iterable:
            if not first:
                run.step_done()
            first = False
            run.poll()
            run.wait_if_paused()
            if run.should_stop():
                break
            yield item
        else:
            if not first:
                run.step_done()
            finished = True
    finally:
        # Stopped by command, or the loop was left early (break or an exception).
        run.finish("finished" if finished else "stopped")
