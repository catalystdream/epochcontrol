"""epochcontrol: see and control training runs from the Mac menu bar.

The smallest use, in any Python loop:

    import epochcontrol
    for epoch in epochcontrol.loop(range(200), name="my run"):
        train_one_epoch()

Each run writes a folder of small JSON files (see ``schemas/`` in the repo); the macOS
app and the ``epochcontrol`` CLI read them and send pause, resume and stop commands back.
"""

from ._loop import loop
from ._run import Run, start

__version__ = "0.1.1"
__all__ = ["loop", "start", "Run", "__version__"]
