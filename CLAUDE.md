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
- **Docs ship with the feature, in the same commit.** A new or changed option, method, environment variable, CLI command or flag, or app feature updates `docs/reference.md` (the full list), `README.md` and `python/README.md` when it is user-facing (the PyPI copy uses absolute GitHub links), and `python/epochcontrol/_guide.py` when agents need it; then regenerate `docs/llms.txt` with `epochcontrol agent-guide > docs/llms.txt` (a test checks they match).

## Layout
`python/` package · `macos/` Xcode project · `schemas/` JSON Schemas · `examples/` · `docs/`

## Running the tests
```bash
cd python && UV_PROJECT_ENVIRONMENT=.venv.nosync uv run pytest -q
```
The repo sits in `~/Documents`, which iCloud syncs. iCloud marks files in a plain `.venv` hidden, and Python 3.13+ then ignores the editable install's `.pth` file ("No module named epochcontrol"). A folder ending in `.nosync` is not synced.

## Building the Mac app
```bash
cd macos
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
swift test                 # EpochControlKit tests (fixtures copied from schemas/examples)
scripts/bundle.sh          # build/EpochControl.app, ad-hoc signed
build/EpochControl.app/Contents/MacOS/EpochControl --snapshot out.png   # render the popover to check layout
```
`SDKROOT` is needed on Harrish's Mac: the Command Line Tools `MacOSX.sdk` link points at a missing SDK. Snapshots show native buttons as placeholders (ImageRenderer limit), so bars are drawn by hand.

## Order of work
v0.1 Python only, then v0.2 app, as in PRD §12. Write the test first.
