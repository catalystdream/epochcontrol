# EpochControl

Python package + macOS menu-bar app for monitoring and controlling training runs. `PRD.md` is the source of truth: requirement IDs are tasks, the "accepted when" column is the check. `plan.md` is older design detail (it still says EpochBar, the former name); if they disagree, the PRD wins.

## Rules
- **Never break training.** A failure inside the package warns once and carries on (SAFE1). It must not raise into the user's loop.
- **Schemas first.** Files in `schemas/` are the contract between Python and Swift. Change the schema before the code, and bump `schema` for breaking changes.
- **Pure Python, no required dependencies.** Never import torch, jax or tensorflow at package import time.
- **Timing is tested with injected clocks.** Never read the system clock directly in timing logic.
- **Writes are atomic:** temp file in the same folder, then `os.replace`.
- **The app only reads and controls.** It never trains, and quitting it never affects a run.
- **Signals only after checking process ID and start time** (CTL6).
- **Reading never writes.** Commands that change a run stay separate from those that read (AG11).

## Layout
`python/` package · `macos/` Xcode project · `schemas/` JSON Schemas · `examples/` · `docs/`

## Order of work
v0.1 Python only, then v0.2 app, as in PRD §12. Write the test first.
