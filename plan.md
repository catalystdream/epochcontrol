# EpochBar — Product Requirements Document

*A macOS menu-bar monitor and remote control for machine-learning training runs, with a small Python library that any training loop can call.*

- **Status:** plan, not started (written 2026-10-30)
- **Owner:** Harrish Joseph (personal open-source project, GitHub)
- **Handover note:** this document is self-contained. The next session should start from §13, "First session checklist".

---

## 1. Problem

Long training runs (30 minutes to many hours) on a MacBook have no good at-a-glance status.

- **Progress is buried in a terminal.** A tqdm bar in a terminal tab says nothing about whether validation loss is still improving.
- **Pausing is awkward.** The laptop travels in a bag between home and work. Closing the lid sleeps the Mac and freezes the run, which works but isn't visible or controllable. `caffeinate -i` blocks only idle sleep, not lid-close sleep, which surprises people. Pausing without closing the lid means `kill -STOP <pid>` by hand, and you first have to find the right pid. With `caffeinate -i python train.py`, `caffeinate` is the *child* of the Python process, not its parent.
- **Stopping cleanly is hard.** Ctrl-C mid-epoch can lose everything since the last best checkpoint. A clean stop that saves a resumable checkpoint needs cooperation from the training loop.
- **Queues are fragile.** Overnight queues of several runs restart from scratch after a crash or reboot unless the queue skips finished jobs and the trainer can resume from its last epoch.
- **Elapsed time is wrong after sleep.** `time.time()` keeps counting while the Mac sleeps, so the "training time" reported in a paper is inflated. `time.monotonic()` on macOS (`mach_absolute_time`) stops during sleep.

## 2. Existing tools (checked 2026-10-30)

No native macOS menu-bar app does this.

| Tool | What it is | Gap |
|---|---|---|
| [OnTheFly](https://pypi.org/project/onthefly-ai/) | VS Code extension + Python package; live loss dashboard, pause/resume | lives inside VS Code; beta |
| [Aliyah](https://pypi.org/project/aliyah) ([GitHub lovechants/Aliyah](https://github.com/lovechants/Aliyah)) | terminal training monitor with pause/resume/stop and plots | terminal only |
| [Apple-Silicon TUI dashboard (autoresearch wiki)](https://github.com/elementalcollision/autoresearch/wiki/TUI-Dashboard/e26146cbf18622aa587d57e93689ae7195e26580) | Textual TUI that parses the training script's stdout; loss, throughput, ETA | parses text output; terminal |
| [labml-app](https://pypi.org/project/labml-app/0.0.4) | mobile-first web app for monitoring PyTorch/TensorFlow runs | web/phone, needs a server |
| [Hyperdash](https://apps.apple.com/app/id1257582233) | iOS app for a hosted training-monitor service | hosted, iPhone/iPad |
| TensorBoard, Weights & Biases, MLflow, Aim | full experiment trackers | browser dashboards; no menu-bar presence; no pause/stop control of a local process |

**Positioning:** EpochBar is not an experiment tracker. It's the glanceable, local, zero-account status light and remote control for the run on *this* machine. It sits next to W&B or TensorBoard and doesn't replace them.

The visual reference is the ClaudeBar usage monitor: dark popover, cards, progress bars, sparkline charts.

## 3. Goals and non-goals

### Goals (v1)
1. A menu-bar icon that shows, at a glance, whether a run is in progress, its epoch progress, and whether the best validation loss is still improving.
2. A popover per run with:
   - progress bar (epoch k of N, ETA);
   - train and validation loss chart (log scale toggle) with the best epoch marked;
   - **Pause / Resume / Stop** buttons.
3. A Python library, `epochbar`, usable from **any custom training loop** in about three lines, plus ready-made callbacks for PyTorch Lightning, Keras, and Hugging Face `Trainer`.
4. Three pause and stop mechanisms, chosen per run:
   - **cooperative:** the loop pauses and stops at a step or epoch boundary, with a checkpoint hook;
   - **OS-level:** SIGSTOP/SIGCONT of the process tree, which needs no loop cooperation;
   - **sleep-aware:** the app shows "Mac was asleep for 42 min" and the library reports sleep-excluded training time.
5. Correct, honest timing: wall time, active time (sleep and pause excluded), and paused time, all reported separately.
6. Queue awareness: a run list shows finished, in-progress and waiting jobs when they are launched through `epochbar queue`.

### Non-goals (v1)
- Not a hosted service; no accounts, no cloud; everything local.
- No hyperparameter search, artifact storage or experiment comparison across months; that's W&B or MLflow territory.
- No GPU temperature or power readings. They need `sudo powermetrics` on macOS; deferred to v2 as optional.
- No Windows or Linux GUI. The Python library must still work on Linux (it simply writes status files), so remote runs can be added in v2.

## 4. Users and scenarios

- **Primary user:** a researcher training PyTorch models on an Apple-Silicon MacBook (MPS), with occasional runs on a remote Linux GPU box.

**S1, morning commute.** A 3-hour run is at epoch 140/600. Before leaving, the user clicks **Pause** (or just closes the lid). At work they open the lid and click **Resume**, or it continues by itself after a lid sleep. The popover shows "paused 38 min" and a sleep-excluded ETA.

**S2, overfitting check.** A glance at the sparkline shows validation loss flat for 60 epochs. Early-stopping patience is shown as a bar, "patience 47/60". The user clicks **Stop**: the loop finishes the current epoch, saves a resumable checkpoint and exits with status `stopped`.

**S3, crash during an overnight queue.** The battery dies on job 4 of 9. After a reboot, `epochbar queue resume` skips the 3 finished jobs and restarts job 4 from its last epoch checkpoint, if the loop registered a resume hook; otherwise from scratch.

**S4, custom loop with no framework.** A hand-written loop with `for ep in range(E): ... ` adds `run.log(...)` and `run.checkpoint_hook(...)` and gets everything above.

**S5, notifications.** When a run finishes, fails or stops improving, a macOS notification shows best epoch and best validation loss. Clicking it opens the run folder.

## 5. System architecture

```
 training process (Python)                       EpochBar.app (SwiftUI, MenuBarExtra)
 ┌──────────────────────────┐   status (JSON,    ┌──────────────────────────────────┐
 │ epochbar library          │   atomic rename)   │ RunStore: watches runs dir        │
 │  run = epochbar.start()   │ ─────────────────► │   (FSEvents / DispatchSource)     │
 │  run.log(epoch, ...)      │                    │ Menu-bar icon + popover           │
 │  run.should_stop() etc.   │ ◄───────────────── │ Buttons write control.json        │
 │  heartbeat thread         │  control (JSON)    │ OS-level pause: kill -STOP tree   │
 └──────────────────────────┘                    └──────────────────────────────────┘
          ▲ both read/write ~/Library/Application Support/EpochBar/runs/<run_id>/
```

### 5.1 Transport: a shared directory, not sockets (v1)
- **Location:** one directory per run in `~/Library/Application Support/EpochBar/runs/<run_id>/`. Override with `EPOCHBAR_HOME`; on Linux, `~/.local/share/epochbar/runs/`.
- **Why files:** the training process never blocks on the UI; the app can be closed or reopened at any time; runs survive app crashes; the files are debuggable with `cat`; and the same format can later be synced from a remote box (`rsync`, or an SSH tail in v2).
- **Atomic writes:** write to a temporary file in the same directory, then `os.replace`. The app never reads a half-written file.
- **Files per run:**
  - `meta.json`: written once at start. Holds run_id, name, pid, process start time, host, command line, cwd, total epochs, framework, library version, user tags, and the run folder of the user's own outputs, if given.
  - `status.json`: rewritten at most every 1 s and after every epoch. Holds state, epoch, step, best epoch and value, patience counter, ETA, timing block, and last heartbeat time.
  - `metrics.jsonl`: one line per logged point, append-only. Fields: `{"t": ..., "epoch": ..., "step": ..., "train": ..., "val": ..., "lr": ..., ...}`.
  - `control.json`: written by the app, read by the library. Holds `{"command": "pause"|"resume"|"stop"|"none", "seq": n, "issued_at": ...}`. `seq` makes commands idempotent.
  - `events.jsonl`: state changes (started, paused, resumed, slept/woke, checkpoint saved, stopped, finished, failed), for the timeline.

### 5.2 Run states
`starting → running ⇄ paused → stopping → stopped | finished | failed | lost`

`lost` means the heartbeat is older than 3× its interval and the pid is gone or reused. Pid reuse is checked against the process start time.

### 5.3 Liveness and pid handling
- **Heartbeat:** a daemon thread updates `status.json` every 1 s. It also detects sleep: a gap between monotonic and wall-clock deltas larger than 5 s means the Mac slept, and an event is logged.
- **Pid reuse:** the library records the process start time. Use `psutil.Process().create_time()`, or the start time from `ps -o lstart` if psutil is absent. The app treats a pid as the same process only if both match.
- **caffeinate gotcha (documented):** with `caffeinate -i python train.py`, macOS `caffeinate` makes the utility the *parent* and itself the child. The training pid is the process the library runs in, so always use `os.getpid()` from inside the library, never `$!` from a shell. OS-level pause signals the training pid **and its descendants** (DataLoader workers, a caffeinate child).

## 6. Python library (`epochbar`)

### 6.1 Install
```bash
pip install epochbar          # pure Python, no hard deps
pip install "epochbar[psutil]"  # optional: robust pid/start-time checks
```
Python 3.9+. Never import torch, jax or tensorflow at module import time; framework callbacks live in submodules.

### 6.2 Core API (custom loops; the main use case)
```python
import epochbar

run = epochbar.start(name="tft-lstm lumo s43", total_epochs=200,
                     patience=40, monitor="val", mode="min",          # best/patience tracking
                     run_dir="results/LUMO_mac_tft-lstm_s43",         # optional: user's own output folder (shown in app)
                     pause_mode="cooperative")                        # "cooperative" | "os" | "both"

for epoch in run.epochs(start=start_epoch):          # yields epochs; blocks while paused; ends on stop
    train_loss = train_one_epoch(...)
    val_loss = validate(...)
    run.log(epoch=epoch, train=train_loss, val=val_loss, lr=sched.get_last_lr()[0])

run.finish()                                         # or context manager: `with epochbar.start(...) as run:`
```

**Without the iterator,** for loops the user doesn't want to restructure:
```python
for epoch in range(E):
    ...
    run.log(epoch=epoch, train=tl, val=vl)
    run.checkpoint_if_requested(save_fn)   # saves only when the app asked for pause/stop
    if run.should_stop():                  # app pressed Stop (after save)
        break
    run.wait_if_paused()                   # blocks here while paused (cooperative)
```

**Step-level progress** (optional, for long epochs):
```python
run.step(i, total=n_batches)   # throttled; never more than ~4 writes/s
```

**Checkpoint and resume hooks**, which make the cooperative Stop safe and the queue resumable:
```python
run.on_checkpoint(lambda: torch.save({"model": m.state_dict(), "opt": opt.state_dict(),
                                      "sched": sched.state_dict(), "epoch": epoch,
                                      "rng": epochbar.utils.rng_state()}, ckpt_path))
start_epoch = run.resume_from(ckpt_path, load_fn)   # returns 0 if no checkpoint
```

`epochbar.utils.rng_state()` and `set_rng_state()` capture and restore the Python, NumPy, torch CPU, CUDA and MPS RNG states. That lets a resumed run continue the same random stream, though bit-exactness on MPS isn't guaranteed and the docs must say so.

**Timing helpers:**
```python
run.timing  # {"wall_s", "active_s", "paused_s", "slept_s"}; active = monotonic minus paused
```

### 6.3 Framework adapters
- **PyTorch Lightning:** `from epochbar.lightning import EpochBarCallback`. It hooks `on_train_epoch_end` and `on_validation_epoch_end`; Stop maps to `trainer.should_stop = True`; Pause blocks in `on_train_batch_start`; the checkpoint uses `trainer.save_checkpoint`.
- **Keras:** `from epochbar.keras import EpochBarCallback`. `on_epoch_end` logs; Stop maps to `self.model.stop_training = True`.
- **Hugging Face:** `from epochbar.hf import EpochBarCallback` (a `TrainerCallback`). Stop maps to `control.should_training_stop = True`; save maps to `control.should_save = True`.
- **JAX / Flax / Equinox:** no adapter needed; the core API works. One example script in `examples/`.
- **Text-only fallback:** `epochbar wrap -- python train.py` runs an unmodified script, parses tqdm/`epoch N … loss …` lines with user-configurable regexes, and supports OS-level pause/stop only.

### 6.4 CLI
```
epochbar ls                       # runs and states
epochbar pause|resume|stop <run>  # same as the buttons (writes control.json; OS mode: signals the tree)
epochbar wrap -- <cmd>            # monitor an unmodified script (stdout parsing)
epochbar queue add <cmd> ...      # append jobs to the queue
epochbar queue run                # run them one after another; skips jobs that finished OK
epochbar queue status|resume
epochbar clean --older 30d        # delete finished run records (never the user's run_dir)
```

### 6.5 Pause and stop semantics (precise)
| Action | Cooperative (default) | OS-level |
|---|---|---|
| Pause | at the next `run.log`/`step`/`wait_if_paused`: optional checkpoint, then block (sleep-poll `control.json` every 0.5 s); GPU memory stays allocated | `SIGSTOP` to pid + descendants; immediate; works for any script |
| Resume | unblock | `SIGCONT` to the same set |
| Stop | at the next epoch boundary: checkpoint hook, state `stopped`, `should_stop()` true / iterator ends | `SIGTERM`, then `SIGKILL` after a grace period (confirm dialog in app: "loses progress since last checkpoint") |
| Lid closed / sleep | nothing to do: the process is frozen by the OS; library logs a `slept` event on wake | same |

Paused and slept time are excluded from `active_s` and from the ETA.

## 7. macOS app (EpochBar.app)

### 7.1 Tech
- Swift 5.10+ and SwiftUI, using `MenuBarExtra` with `.menuBarExtraStyle(.window)`; macOS 14+.
- Swift Charts for loss curves; no third-party dependencies in v1.
- `LSUIElement = YES`: no Dock icon. Launch at login via `SMAppService.mainApp`.
- **File watching:** `DispatchSource.makeFileSystemObjectSource` per run directory, plus a 2 s fallback timer for `status.json`.
- **Signals:** `kill(pid, SIGSTOP)` from Swift. Allowed for the same user's processes. Not sandboxed: OS-level pause needs to signal arbitrary user processes, and that rules out the App Store sandbox.

### 7.2 Menu-bar icon
- **Idle:** a monochrome template glyph.
- **One run in progress:** a tiny ring progress around the glyph, plus optional text "73%" or "140/600" (setting).
- **States:** paused shows a pause badge; any failed run turns the icon red; a finished run since you last looked shows a green dot.
- **Several runs in progress:** the ring shows the oldest active run, with a count badge.

### 7.3 Popover layout (dark, card style like the ClaudeBar reference)
1. **Header:** "EpochBar", host name, a tab per run, and an "All" overview.
2. **Run card:**
   - run name, state pill (RUNNING / PAUSED / STOPPED / FINISHED / FAILED / LOST) and elapsed active time;
   - progress bar "epoch 140 / 600", step sub-bar, and ETA computed on active time;
   - patience bar "no improvement for 47 / 60 epochs", amber above 75 %;
   - best: "val 0.02336 at epoch 368".
3. **Chart card:**
   - train and validation loss lines on log or linear scale, with the best epoch marked by a vertical rule and a learning-rate overlay toggle;
   - hover shows the values;
   - range chips: last 50 / all.
4. **Timing card:** wall / active / paused / slept, plus an event timeline strip (slept 08:54–10:27, paused 12:01–12:40).
5. **Controls row:** Pause/Resume (toggle), Stop (confirm), Open run folder, Copy command, Reveal log.
6. **Queue card**, when the run belongs to an `epochbar queue`: job list with ✓ / ▶ / ⏸ / ✗ / waiting, and the "next up" item.
7. **Footer:** settings, and "quit app" (it never touches the runs).

### 7.4 Notifications (`UNUserNotificationCenter`)
- **Events:** finished, failed (non-zero exit or exception captured by the library), stopped, lost.
- **Optional plateau alert:** patience above X %.
- **Queue finished:** a summary of jobs and their exit states.

### 7.5 Settings
Runs directory; show text in the menu bar; refresh rate; notification toggles; default pause mode for the CLI; launch at login; keep finished runs for N days.

## 8. Data schemas (v1, versioned with `"schema": 1`)

```json
// status.json
{"schema": 1, "run_id": "20261030-104512-7f3a", "state": "running",
 "epoch": 140, "total_epochs": 600, "step": 12, "total_steps": 40,
 "best": {"value": 0.02336, "epoch": 368, "monitor": "val", "mode": "min"},
 "patience": {"limit": 60, "since_best": 47},
 "timing": {"wall_s": 9312.4, "active_s": 7020.1, "paused_s": 0, "slept_s": 2292.3},
 "eta_s": 4210, "heartbeat": "2026-10-30T10:45:12+01:00", "pid": 40751, "pid_start": 1793353512.0}
```
```json
// metrics.jsonl (one object per line)
{"t": 1793353600.1, "epoch": 140, "train": 0.0241, "val": 0.0236, "lr": 0.00071}
```
```json
// control.json (written by the app)
{"schema": 1, "command": "pause", "seq": 7, "issued_at": "2026-10-30T12:01:03+01:00", "by": "app"}
```

## 9. Packaging and distribution

- **Repo:** a GitHub monorepo `epochbar/`:
  - `python/` (the library, `pyproject.toml`, tests);
  - `macos/` (the Xcode project);
  - `docs/`, `examples/` (custom loop, Lightning, Keras, HF, JAX), `schemas/` (JSON Schema files).
- **Licence:** MIT.
- **Python:** published to PyPI with trusted publishing from GitHub Actions; CI on macOS and Linux for Python 3.9–3.13.
- **App distribution:**
  - **v0.x:** an unsigned build on GitHub Releases. Users right-click → Open, or build from source with `xcodebuild`. No Apple account needed.
  - **v1.0:** a **Developer ID-signed and notarized** DMG, using the paid Apple Developer Program at $99 a year. Use `notarytool` from a GitHub Actions macOS runner with an App Store Connect API key in secrets. Ship through a Homebrew cask (`brew install --cask epochbar`).
  - **Mac App Store:** not planned. OS-level signalling of other processes conflicts with the App Sandbox. A sandboxed "cooperative-only" build would be possible later.
- **Auto-update:** Sparkle 2 (EdDSA-signed appcast on GitHub Pages) once signed builds exist.

## 10. Quality, testing, security

- **Library tests (pytest):**
  - atomic writes under concurrent reads;
  - the state machine;
  - cooperative pause, resume and stop from a fake control writer;
  - the timing maths, with injected monotonic and wall clocks, including a simulated sleep gap;
  - pid-reuse detection;
  - each framework adapter on a toy model (CPU, under 10 s).
- **Integration test:** a 3-epoch toy run is paused, resumed and stopped by the CLI; checks the checkpoint exists and the final state is `stopped`.
- **App tests:**
  - XCTest for RunStore parsing against fixture directories, including a corrupt `status.json`, a missing heartbeat and a lost process;
  - a UI snapshot test of the popover in light and dark.
- **Performance budget:** the library adds under 1 ms per `log` call and under 0.1 % CPU from the heartbeat thread; the app stays idle below 0.5 % CPU and under 60 MB RAM with 10 active runs.
- **Security and privacy:**
  - no network access in v1;
  - files are created with mode 0700 and 0600;
  - the app only signals pids recorded in `meta.json` whose start time matches, and never processes of other users;
  - command lines may contain secrets, so `meta.json` stores `argv` only if `record_command=True` (default False; store the script name only).

## 11. Milestones

| M | Scope | Done when |
|---|---|---|
| M0 | Repo skeleton, schemas, CI | `pytest` green on macOS + Linux; JSON Schemas committed |
| M1 | Python core: `start/log/epochs/finish`, status + metrics files, heartbeat, timing incl. sleep detection, CLI `ls` | toy loop produces correct files; sleep simulated in tests |
| M2 | Control: cooperative pause/resume/stop, checkpoint hook, `resume_from`, RNG helpers; CLI pause/resume/stop; OS mode | integration test passes; a real MPS run paused/resumed by CLI |
| M3 | macOS app MVP: MenuBarExtra, run list, progress, Swift Charts loss plot, buttons | dogfood on real overnight runs for one week |
| M4 | Notifications, settings, launch at login, queue (`epochbar queue`) with skip-finished and resume | crash in the middle of a queue recovers by `queue resume` |
| M5 | Adapters: Lightning, Keras, HF; `wrap` with stdout parsing | example scripts run in CI |
| M6 | v1.0: signed + notarized DMG, Homebrew cask, Sparkle, docs site, README GIF | fresh Mac installs via brew without security prompts |
| v2 | Remote runs over SSH (status sync from a Linux GPU box), optional `powermetrics` GPU/power, iPhone widget | — |

## 12. Open questions

1. **Name:** is EpochBar free on PyPI, GitHub and Homebrew? Check at M0; alternatives: TrainBar, LossLight.
2. **OS-level pause on MPS:** is SIGSTOP of a process in the middle of an MPS command buffer always safe? Lid sleep is, by observation. Verify with a stress test at M2 (pause or resume 100 times, then compare final weights with an uninterrupted run).
3. **Cooperative pause:** should it release GPU memory (`torch.mps.empty_cache()`)? Probably an option, default off.
4. **App reading user plots:** should the app also read an existing `train_history.json`, TensorBoard event files or a W&B offline dir? Possible v2 importers, to monitor runs that don't use the library.
5. **Queue implementation:** should the queue runner be Python (portable, Linux too) or part of the app (needs to stay running)? Proposed: Python, with the app as a viewer only.

## 13. First session checklist (for the next Claude session)

1. Create `~/Documents/Projects/EpochBar/` as a git repo, and check whether the name is free on PyPI, GitHub and Homebrew.
2. Scaffold `python/epochbar/` with `pyproject.toml` (hatchling) and `schemas/`; write the JSON Schemas from §8 first.
3. Implement M1 test-first: clock injection for timing, atomic writer, heartbeat thread.
4. Write `examples/custom_loop_torch.py`: a 2-layer MLP on synthetic data, 30 epochs, using `run.epochs()`, `run.log()` and a checkpoint hook. Use it as the manual test for every milestone.
5. Only then start the Xcode project (M3); keep the app a pure *reader and controller* of the run directory.

## 14. Lessons this design builds in (observed on a real MacBook, 2026-10)

- **Lid close always sleeps the Mac,** even with `caffeinate -i` active: `pmset -g log` shows "Clamshell Sleep" entries. Training freezes and continues on wake with identical results, so sleep is a legitimate pause.
- **`caffeinate -i <cmd>` on macOS** keeps `<cmd>` in the original process and runs as its child. Shell `$!` is therefore the training process, and `pgrep -P $!` gives `caffeinate`. Signal the whole tree.
- **Training-time measurement:** `time.time()` counts sleep; `time.monotonic()` (`mach_absolute_time`) doesn't. Neither excludes a SIGSTOP pause; the library has to subtract that itself.
- **Overnight queues** need "skip jobs that already exited 0" plus a per-job status line, so a crash costs at most one job.
