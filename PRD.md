# EpochControl: Product Requirements Document

| | |
|---|---|
| **Status** | Reviewed by Harrish. Open: D3 (not needed until v1.0) |
| **Version** | 0.6, 3 November 2026 (Liquid Glass and animation added) |
| **Owner** | Harrish Joseph |
| **Type** | Open-source project: a Python package and a macOS app |
| **Related** | `plan.md` (design notes, 30 October 2026) |

**How to review:** read §1 to §4 for the product, then answer §14 (decisions), then skim the requirement tables. Write comments anywhere. This document says *what* EpochControl must do and how we will know it works. `plan.md` keeps the design detail and is unchanged. If the two disagree, this document wins once approved.

**Requirement priorities**

| Tag | Meaning |
|---|---|
| **P0** | Needed for the first usable version. Without it, the product does not work |
| **P1** | Needed for v1.0 |
| **P2** | After v1.0, or only if time allows |

---

## 1. Summary

EpochControl shows the status of machine-learning training runs in the macOS menu bar and lets you pause, resume or stop them. It has two parts:

- **`epochcontrol`, a Python package.** Three or so lines in a training loop report progress, losses and timing.
- **EpochControl.app, a native macOS menu-bar app.** It displays those runs and sends commands back.

The two parts never connect directly. They share a folder of small files, so training never depends on the app being open.

Coding agents are treated as users too: an agent can add EpochControl to a training script, check that it works, and read run status (§9).

It is local, free, open source, and needs no account. It is not an experiment tracker, and it is meant to run alongside tools such as W&B, TensorBoard or trackio.

---

## 2. Problem

Long runs on a MacBook (30 minutes to many hours) have no good at-a-glance status, and no safe way to control them.

| # | Problem | Today |
|---|---|---|
| 1 | Progress is buried in a terminal | A tqdm bar does not show whether validation loss is still improving |
| 2 | Pausing is awkward | A laptop travels between home and work. Closing the lid freezes the run, which works, but nothing shows or controls it |
| 3 | Stopping cleanly is hard | Ctrl-C mid-epoch can lose everything since the last best checkpoint |
| 4 | Overnight queues are fragile | After a crash or reboot, a queue often restarts from scratch |
| 5 | Reported training time is wrong | `time.time()` keeps counting while the Mac sleeps, which inflates the time reported in a paper |

---

## 3. Users and scenarios

**Primary user:** a researcher training PyTorch models on an Apple-Silicon MacBook (MPS), often with a hand-written training loop.

**Secondary users:** people using PyTorch Lightning, Keras, Hugging Face or JAX on a Mac.

**Coding agents:** tools such as Claude Code or Codex, working for the user. They edit training scripts, and read status.

**Later user (v2):** the same researcher with runs on a remote Linux GPU machine.

| # | Scenario | Expected result |
|---|---|---|
| S1 | **Commute.** A 3-hour run is at epoch 140 of 600. The user clicks Pause, or just closes the lid | At work it resumes by button or by itself. The sleep is shown, and left out of active time and ETA |
| S2 | **Overfitting.** Validation loss has been flat for a long time | The patience bar shows 47/60. Stop finishes the epoch, saves a checkpoint and ends cleanly |
| S3 | **Crash in a queue.** The battery dies on job 4 of 9 | After reboot, `epochcontrol queue resume` skips the 3 finished jobs and continues job 4 from its last checkpoint |
| S4 | **Custom loop.** A hand-written `for` loop, no framework | A few added lines give everything above |
| S5 | **Away from the Mac.** A run finishes or fails | A macOS notification shows the result and best value |
| S6 | **Paper timing.** The user needs the true training time | The run reports wall, active, paused and slept time separately |
| S7 | **Agent setup.** The user says "add EpochControl to `train.py`" | The agent reads the guide, edits the script, runs `epochcontrol check`, and reports that it passes |
| S8 | **Agent status.** The user asks "how is the overnight run doing?" | The agent reads `epochcontrol ls --json` and answers |

---

## 4. Goals and non-goals

### Goals for v1.0

1. See at a glance whether a run is going, how far along it is, and whether it is still improving.
2. Pause, resume and stop a run from the menu bar or the command line, without losing work.
3. Work in any custom Python loop in about three lines, and with common frameworks through callbacks.
4. Report honest timing.
5. Survive failure: of the app, the training process, the Mac, or a queue.
6. Let a coding agent set EpochControl up correctly, and check its own work, with no help beyond the package itself.

### Non-goals for v1.0

- No hyperparameter search, artifact storage, or comparison of runs across months.
- No hosted service, account, cloud or telemetry.
- No Windows or Linux desktop app. The Python package must still run on Linux.
- No GPU temperature or power readings (they need `sudo powermetrics`).
- No Mac App Store release (see §13, R4).

### How we will know it worked

| Measure | Target |
|---|---|
| Lines to add to a custom loop | 5 or fewer for monitoring, 10 or fewer with pause, stop and checkpoint |
| Agent setup | A coding agent adds EpochControl to an unseen custom loop and `epochcontrol check` passes, in 3 of 3 trials with no human correction |
| Dogfooding | One real overnight run monitored each week for four weeks, with no lost work |
| Training overhead | Below the limits in NF1 and NF2 |
| Timing accuracy | Active time within 1% of the true value across a sleep and a pause |
| Resume correctness | With fixed seeds, a run paused and resumed gives the same final weights as an uninterrupted run (cooperative mode) |
| Adoption, 6 months after v1.0 (goal, not a requirement) | 100 GitHub stars, or 5 outside users reporting real use |

---

## 5. Existing tools (checked 30 October 2026)

No native macOS menu-bar app does this.

| Tool | What it is | Gap |
|---|---|---|
| OnTheFly | VS Code extension and Python package, with live loss and pause/resume | Lives inside VS Code, beta |
| Aliyah | Terminal monitor with pause, resume, stop and plots | Terminal only |
| labml-app | Mobile-first web app for monitoring runs | Web or phone, needs a server |
| Hyperdash | iOS app for a hosted monitoring service | Hosted, iPhone or iPad |
| TensorBoard, W&B, MLflow, Aim | Full experiment trackers | Browser dashboards, no menu-bar presence, no control of a local process |

**Compared with W&B:** W&B answers "what happened across my runs?". EpochControl answers "what is this run doing right now, and can I act on it?". W&B stays better for comparing many runs, sweeps, artifacts, sharing, and remote machines. EpochControl is better for glanceable status, local pause and stop, sleep-aware timing, and crash-safe queues.

---

## 6. How it works

```
 Your training script                          EpochControl.app (menu bar)
 ┌──────────────────────┐   status, metrics    ┌──────────────────────┐
 │  epochcontrol (Python)   │ ───────────────────► │ watches the folder   │
 │  run.log(...)        │                      │ icon, charts, buttons│
 │  run.epochs()        │ ◄─────────────────── │ writes commands      │
 └──────────────────────┘     pause / stop     └──────────────────────┘
        ~/Library/Application Support/EpochControl/runs/<run_id>/
```

Why a shared folder instead of a live connection:

- Training never waits for the app.
- The app can be closed, crash or restart at any time, and catch up afterwards.
- The files can be read with `cat`, which makes debugging easy.
- The same files can be copied from a remote machine later.

The smallest use, in any Python loop, the same way as tqdm:

```python
import epochcontrol

for epoch in epochcontrol.loop(range(200), name="tft-lstm lumo s43"):
    train_one_epoch(...)
```

To also see losses, best epoch and patience:

```python
import epochcontrol

run = epochcontrol.start(name="tft-lstm lumo s43", total_epochs=200, patience=40)

for epoch in run.epochs():          # waits while paused, ends on Stop
    train_loss = train_one_epoch(...)
    val_loss = validate(...)
    run.log(epoch=epoch, train=train_loss, val=val_loss)

run.finish()
```

---

## 7. Requirements: Python package

### Core API

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| LIB0 | `epochcontrol.loop(iterable, name=...)` wraps any Python iterable, like tqdm. It shows progress, pauses and stops between iterations, and needs no other change to the loop | P0 | A plain `for` loop can be paused, resumed and stopped from the CLI |
| LIB1 | `epochcontrol.start()` creates a run with name, total epochs, patience, monitored metric and mode (min/max) | P0 | A toy loop produces a valid run folder |
| LIB2 | `run.log()` records epoch, train and validation values, learning rate and any other named metric | P0 | Values appear in `metrics.jsonl` in order |
| LIB3 | `run.epochs()` iterator handles waiting while paused and ending on stop | P0 | A loop using it needs no other control code |
| LIB4 | Explicit alternative for loops that cannot be restructured: `should_stop()`, `wait_if_paused()`, `checkpoint_if_requested()` | P0 | Same behaviour as LIB3 |
| LIB5 | Tracks best value, best epoch and patience count | P0 | Correct for min and max modes |
| LIB6 | Calculates ETA from active time only | P0 | ETA does not jump after a sleep or pause |
| LIB12 | `stop_on_patience=True` in `start()` (Harrish, 3 Nov): after `patience` epochs without a better `monitor` value the run saves its checkpoint and ends as finished, the reason in the event log. Off by default: patience otherwise only reports | P0 | Test: ends at the right epoch, checkpoint saved, state finished |
| LIB7 | `run.step()` for progress inside long epochs, limited to about 4 writes a second | P1 | Calling it on every batch adds no measurable slowdown |
| LIB8 | Context manager form, `with epochcontrol.start(...) as run:` | P1 | An exception inside marks the run `failed` |
| LIB9 | An uncaught exception marks the run `failed` and records the error | P0 | Test raises in the loop and checks the state |
| LIB10 | `on_checkpoint()` hook and `resume_from()` | P0 | A stopped run resumes from its checkpoint |
| LIB11 | RNG helpers saving and restoring Python, NumPy, torch CPU, CUDA and MPS state | P1 | The resume-correctness measure in §4 passes |

### Must never break training

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| SAFE1 | A failure inside `epochcontrol` (full disk, bad folder, permission error) never stops training. It warns once and carries on | P0 | Test with a read-only folder: the loop still finishes |
| SAFE2 | No framework is imported at package import time | P0 | `import epochcontrol` works with no torch installed |
| SAFE3 | Only the main process reports. Multi-GPU ranks other than 0 and DataLoader workers do nothing | P1 | Test with forked workers shows one run, one heartbeat |
| SAFE4 | Works in a Jupyter notebook, where stopping must not kill the kernel | P1 | Stop in a notebook ends the loop only |
| SAFE5 | Pure Python with no required dependencies. `psutil` is optional | P0 | Installs and runs in a clean environment |

### Pause and stop

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| CTL1 | **Cooperative pause:** at the next `log`, `step` or wait point, optionally checkpoint, then wait. Poll `control.json` every 0.5 s | P0 | Paused and resumed by CLI during a real MPS run |
| CTL2 | **Cooperative stop:** at the next epoch boundary, run the checkpoint hook, set state `stopped`, end the loop | P0 | Checkpoint exists, final state is `stopped` |
| CTL3 | **OS-level pause:** SIGSTOP and SIGCONT to the process and its descendants. Needs no cooperation from the loop | P1 | Works on a script with no library calls, through `epochcontrol wrap` |
| CTL4 | **OS-level stop:** SIGTERM, then SIGKILL after a grace period, with a warning that progress since the last checkpoint is lost | P1 | Confirm dialog appears in the app |
| CTL5 | Commands are not repeated: each has a sequence number, and the library applies each one once | P0 | Replaying the same file does nothing |
| CTL6 | Signals go only to a process whose ID **and** start time match the run record, and only processes of the same user | P0 | Test with a reused ID refuses to signal |

### Timing

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| TIME1 | Reports wall, active, paused and slept time separately | P0 | Values add up: wall = active + paused + slept, within 1 s |
| TIME2 | Detects Mac sleep from the gap between wall and monotonic clocks, and logs a `slept` event | P0 | Simulated with injected clocks, and confirmed on one real lid close |
| TIME3 | Detects a SIGSTOP freeze from a gap in the monotonic clock itself, and counts it as paused | P1 | Simulated with injected clocks, and confirmed on one real OS pause |
| TIME4 | A summary can be read from code (`run.timing`) and is written to the run record at the end | P0 | Ready to quote in a paper |

### Command line

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| CLI1 | `epochcontrol ls` lists runs and states | P0 | Works with no app installed |
| CLI2 | `epochcontrol pause / resume / stop <run>` | P0 | Same effect as the app's buttons |
| CLI3 | `epochcontrol wrap -- <cmd>` runs an unmodified script, reads progress from its output, and supports OS-level control only | P1 | A plain tqdm script shows progress |
| CLI5 | `epochcontrol app` opens the Mac app, or offers to download it if it is missing; the app, when it finds no runs, shows the `pip install` line and the `loop()` example | P1 | One command leads a Python user to the app |
| CLI4 | `epochcontrol clean --older 30d` removes old run records, never the user's own outputs | P1 | Test confirms `run_dir` is untouched |

### Queue

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| Q1 | `epochcontrol queue add / run / status / resume` | P1 | Jobs run one after another |
| Q2 | Skips jobs that already finished successfully | P1 | Scenario S3 passes |
| Q3 | The queue runner is Python, works on Linux, and needs no app | P1 | Runs on Linux in CI |

### Framework support

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| FW1 | PyTorch Lightning callback | P1 | Example runs in CI |
| FW2 | Keras callback | P1 | Example runs in CI |
| FW3 | Hugging Face `TrainerCallback` | P1 | Example runs in CI |
| FW4 | JAX example using the core API, no adapter needed | P1 | Example runs in CI |
| FW6 | `from epochcontrol.tqdm import tqdm`: a subclass of tqdm, in the way `tqdm.contrib.telegram` is. Changing that one import adds reporting, pause and stop at each iteration, and the terminal bar still works. tqdm stays an optional dependency, not a fork | P1 | An existing tqdm script gains pause and stop with only the import changed |
| FW5 | Read existing `train_history.json`, TensorBoard or W&B offline folders, for runs without the library | P2 | |

---

## 8. Requirements: macOS app

### Menu bar

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| APP1 | Lives in the menu bar with no Dock icon | P0 | |
| APP2 | Idle icon, and a progress ring for one active run | P0 | |
| APP3 | Clear state signals: paused badge, red for a failed run, green dot for a run finished since last viewed | P0 | |
| APP4 | With several runs: shows the oldest active run with a count badge | P1 | |
| APP5 | Optional text beside the icon, such as `73%` or `140/600` | P1 | |

### Popover

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| APP6 | One tab per run, plus an overview | P1 | |
| APP7 | Run card: name, state, active time, progress, ETA, best value and epoch | P0 | |
| APP8 | Patience bar, amber above 75% | P1 | |
| APP9 | Loss chart: train and validation, log or linear scale, best epoch marked | P0 | Updates live during a run |
| APP10 | Chart extras: hover values, learning-rate overlay, last 50 / all | P1 | |
| APP11 | Timing card with a timeline of sleeps and pauses | P1 | |
| APP12 | Pause/Resume and Stop buttons | P0 | |
| APP13 | Stop always asks for confirmation | P0 | |
| APP14 | Open run folder, copy command | P1 | |
| APP15 | Queue card showing finished, running and waiting jobs | P1 | |

### Behaviour

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| APP16 | Finds new runs within 2 s, using file watching with a timer as fallback | P0 | |
| APP17 | A corrupt or half-written file never crashes the app | P0 | Tested with fixture folders |
| APP18 | Quitting the app never affects runs | P0 | |
| APP19 | Tells a frozen process from a dead one (see §11, states) | P0 | Tested for sleep, SIGSTOP and a killed process |
| APP20 | Notifications: finished, failed, stopped, lost | P1 | |
| APP21 | Optional alerts: plateau (patience above a set share), queue finished | P1 | |
| APP22 | Settings: runs folder, menu text, refresh rate, notifications, default pause mode, launch at login, retention | P1 | |
| APP23 | Works in light and dark mode | P1 | Snapshot test of both |
| APP24 | **Liquid Glass on macOS 26 and later** (Harrish, 3 Nov): cards, the run selection and the buttons use the system glass (`glassEffect`, `GlassEffectContainer`, glass button styles). macOS 14–25 get the same layout with materials | P0 | Looks native on macOS 27; still works on macOS 14 |
| APP25 | **Animated selection** (Harrish, 3 Nov): the highlight moves to the chosen run (glass morph on 26+, sliding highlight before), the run card swaps with a blur-fade, changing numbers roll | P0 | Switching runs is smooth, never a jump; respects Reduce Motion |

---

## 9. Requirements: agent support

Everything here works with any coding agent. Only the optional MCP server is tied to one protocol.

### Setting up a project

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| AG1 | `epochcontrol agent-guide` prints exact integration instructions: where each line goes, how to add the checkpoint hook, what not to change. It ships inside the package, so it matches the installed version | P0 | An agent given only this output integrates a toy loop correctly |
| AG2 | `llms.txt` on the docs site gives the same guide for agents reading the web | P0 | Generated from the same source as AG1, so they cannot differ |
| AG3 | `epochcontrol setup-agent` adds a short section to the project's `AGENTS.md` or `CLAUDE.md`, and can install a Claude Code skill. It shows the change first, and never overwrites existing text | P1 | Running it twice changes nothing the second time |
| AG4 | `epochcontrol check <script>` does a very short real run and reports whether logging, pause, stop, checkpoint and resume work | P1 | A deliberately broken script gets a specific error |
| AG5 | `check` leaves no trace: it uses a temporary run record, and does not touch the user's results | P1 | Output folders are unchanged after a check |
| AG6 | Error messages say what to change, and where | P1 | Each `check` failure names the fix |

### Reading and controlling runs

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| AG7 | `--json` on every CLI command that shows data, with a stable, documented output | P0 | Output validates against a schema in `schemas/` |
| AG8 | Exit codes tell success, not found and refused apart | P0 | Tested for each case |
| AG9 | `epochcontrol wait <run>` blocks until the run ends, so an agent need not poll | P1 | Returns the final state as JSON |
| AG10 | `epochcontrol mcp`: a local MCP server with `list_runs`, `get_status`, `get_metrics`, and control tools | P2 | Works from Claude Code. Only built if `--json` proves not to be enough |

### Safety with agents

| ID | Requirement | Pri | Accepted when |
|---|---|---|---|
| AG11 | Reading is always allowed. Anything that changes a run is a separate command, so an agent's permissions can tell them apart | P0 | `ls`, `status` and `wait` never write |
| AG12 | The MCP server starts read-only. Control tools need an explicit `--allow-control` | P2 | Control tools are absent without the flag |
| AG13 | Every command records who issued it (app, CLI or agent) in `events.jsonl` | P1 | The timeline shows the source |
| AG14 | The agent guide says stopping a run needs the user's approval | P0 | Stated in AG1's output |

---

## 10. Non-functional requirements

| ID | Requirement | Target |
|---|---|---|
| NF1 | Cost of one `log` call | Under 1 ms |
| NF2 | Heartbeat CPU use | Under 0.1% |
| NF3 | App at rest with 10 active runs | Under 0.5% CPU, under 60 MB memory |
| NF4 | Writes are atomic | The app never reads a half-written status file |
| NF5 | Local only | No network access in v1, no telemetry |
| NF6 | Privacy | Folders 0700, files 0600. Full command line stored only with `record_command=True`, because it may contain secrets |
| NF7 | Python support | 3.10 to 3.14, on macOS and Linux (see D5) |
| NF8 | macOS support | macOS 14 or later, Apple Silicon first (see D4) |
| NF9 | File format | Every file has a `schema` version. Newer files must not crash an older app |
| NF10 | Testing | CI on macOS and Linux. Timing tested with injected clocks. Each adapter tested on a CPU toy model in under 10 s |

---

## 11. Data contract

JSON Schemas in `schemas/` are the contract between the two parts. Each is written before the code that uses it.

**Folder:** `~/Library/Application Support/EpochControl/runs/<run_id>/` on macOS, `~/.local/share/epochcontrol/runs/` on Linux, or `EPOCHCONTROL_HOME` if set.

| File | Written by | When | Holds |
|---|---|---|---|
| `meta.json` | Package | Once, at start | Run ID, name, process ID and start time, host, total epochs, framework, version, tags, user's output folder |
| `status.json` | Package | Each second and each epoch | State, epoch, step, best, patience, ETA, timing, heartbeat |
| `metrics.jsonl` | Package | Each log, append only | Time, epoch, step, train, validation, learning rate, other metrics |
| `events.jsonl` | Package | Each change | Started, paused, resumed, slept, checkpoint saved, stopped, finished, failed |
| `control.json` | App, CLI or agent | On a command | Command, sequence number, time, source |

**Run states**

```
starting → running ⇄ paused → stopping → stopped | finished | failed | lost
```

**Telling frozen from dead.** A frozen process cannot update its heartbeat, so a stale heartbeat alone proves nothing. The app must decide like this:

| Heartbeat | Process | Other evidence | Shown as |
|---|---|---|---|
| Fresh | Exists | | The state in `status.json` |
| Stale | Exists, same start time | OS pause sent by EpochControl | Paused |
| Stale | Exists, same start time | No pause sent | Stalled (process is frozen or stuck) |
| Stale | Gone, or ID reused | | Lost |

**Stalled** is a new state in this document, not in `plan.md`. It is shown by the app and not written by the package.

A stuck training step with a live heartbeat is a separate case: the heartbeat thread keeps running while the loop hangs. Detecting that (no `log` for several times the usual epoch length) is P2.

---

## 12. Distribution and release plan

| Item | Plan |
|---|---|
| **Repository** | One GitHub repo with `python/`, `macos/`, `schemas/`, `examples/`, `docs/`. Two installs, released separately with their own tags (`py-v…` for PyPI, `app-v…` for the app); the schemas keep them compatible |
| **Licence** | MIT |
| **Python package** | PyPI, published from GitHub Actions with trusted publishing |
| **App, before v1.0** | Unsigned builds on GitHub Releases, or build from source |
| **App, v1.0** | Developer ID signed and notarized DMG, Homebrew cask, updates through Sparkle 2 |
| **App tech** | Swift 6 and SwiftUI, `MenuBarExtra`, Swift Charts, Liquid Glass on macOS 26+ with a material fallback, no third-party dependencies except Sparkle |

| Release | Contents | Done when |
|---|---|---|
| **v0.1, Python only** | Repo with `CLAUDE.md`, schemas, CI, LIB and CTL P0s, timing, CLI with `--json`, `agent-guide`, `llms.txt` | A real MPS run is paused, resumed and stopped from the CLI, and timing survives a lid close |
| **v0.2, app MVP** | All APP P0s | One week of real overnight runs monitored from the menu bar |
| **v0.3, complete** | Notifications, settings, launch at login, OS-level control, queue, `wrap`, tqdm subclass, `epochcontrol app`, `setup-agent`, `check`, `wait` | Scenario S3 passes on a real crash |
| **v0.4, frameworks** | Lightning, Keras, Hugging Face, JAX | Examples run in CI |
| **v1.0, public** | Signed app, Homebrew, docs, README GIF | A fresh Mac installs through brew with no security prompts |
| **v2** | Remote runs over SSH, GPU and power readings, iPhone widget, MCP server if needed | |

v0.1 is useful on its own, and it needs no Swift.

**Building EpochControl with agents:** the repo gets a `CLAUDE.md` from the first commit, with these rules: write schemas first; test timing with injected clocks; the app only reads and controls; never break training. Each requirement ID here can be a task, and its "accepted when" column is the check.

---

## 13. Risks

| # | Risk | Effect | Plan |
|---|---|---|---|
| R1 | SIGSTOP in the middle of an MPS command buffer may not be safe | Corrupted run | Stress test: pause and resume 100 times, compare final weights with an uninterrupted run. Until proven, cooperative stays the default |
| R2 | The monotonic clock may behave differently during sleep across Python or macOS versions (only observed so far on one MacBook) | Wrong timing | Injected-clock tests, plus one real lid-close test on each supported Python |
| R3 | Notifications may not work in an unsigned app | S5 fails before v1.0 | Test at v0.3. If they fail, say so in the docs until signing |
| R4 | The Mac App Store sandbox blocks signalling other processes | No App Store release | Accepted. A cooperative-only build could come later |
| R5 | $99 a year for signing, for a free tool | Ongoing cost | Only needed at v1.0. Decide at D3 |
| R6 | Scope grows: the queue and adapters could delay the core | v1.0 never ships | v0.1 and v0.2 stay small. Queue and adapters stay separate releases |
| R8 | An agent stops or pauses a long run by mistake | Lost hours of training | AG11, AG12, AG14: separate commands, read-only by default, approval stated in the guide |
| R9 | An agent integrates the code wrongly and the run looks fine | Bad checkpoints, resume fails later | `epochcontrol check` tests a real stop and resume, not just imports |
| R7 | Time competes with the paper revision | Project stalls | Built side by side with the revision (D12). The revision comes first when they clash. v0.1 alone is already useful, and real Mac runs can test it |

---

## 14. Decisions for you

Write your answer in the last column. Proposals are mine.

| # | Decision | Proposal | Why | Your answer |
|---|---|---|---|---|
| D1 | Name | **EpochControl** | Decided 2 Nov. Checked: free on PyPI, as a GitHub username and in Homebrew casks, no Mac App Store match. "EpochBar" was dropped because an active Mac App Store tool has that name | EpochControl |
| D2 | GitHub owner | Your personal account | Simple. An `epochcontrol` org is also free if you prefer |yes personal account |
| D3 | Pay $99 a year for signing at v1.0? | Yes, but only once v0.3 is used daily | Without it, users see security warnings, which limits adoption |I already have one but will expire in two months which I sued for owl app. Not sure if I want to continue subsrciption |
| D4 | Lowest macOS | macOS 14 | `plan.md` says the same. It keeps the newest SwiftUI and Charts features |ok |
| D5 | Python versions | 3.10 to 3.14 | **Changed from `plan.md`** (3.9 to 3.13): 3.9 has reached end of life, and your Mac has 3.14 |ok |
| D6 | Swift version | Swift 6 | **Changed from `plan.md`** (5.10+): your Mac has Swift 6.4 and Xcode 27 |ok |
| D7 | Default pause mode | Cooperative | Safest, and allows a checkpoint. OS-level stays opt-in until R1 is tested |ok |
| D8 | Queue in v1.0? | Yes, but as its own release (v0.3) | It solves a real problem, but must not delay the core | Yes, v0.3 |
| D9 | Remote runs in v2 | Keep in v2 | You run on the DGX Spark too, so tell me if this matters sooner. The file format already allows it |ok |
| D10 | Licence | MIT | Common and simple for a tool like this | ok|
| D11 | Release before v1.0 to the public? | Yes, publish v0.1 on PyPI early | Early feedback, and it reserves the name | ok|
| D12 | Start date | After the paper revision | Your main job at the moment |side by side |
| D13 | Build the MCP server? | Only if `--json` is not enough | `--json` works with every agent, and costs far less to maintain | ok|
| D14 | Should an agent be able to pause and stop at all? | Yes through the CLI, under the agent's own permission prompts | Blocking it entirely would remove a useful feature: stopping a run that has plateaued |yes |

---

## 15. Changes from `plan.md`

| Change | Reason |
|---|---|
| Requirements given IDs, priorities and acceptance checks | To review and test them one by one |
| Python 3.10 to 3.14, Swift 6 | Tools have moved on (D5, D6) |
| New **SAFE** requirements: the package must never break training, plus rank 0 only and notebook behaviour | Missing from the plan, and they matter most to users |
| New **Stalled** state and the frozen-or-dead rule | A frozen process cannot update its heartbeat, so the plan's rules could not show an OS pause correctly |
| New **TIME3** for SIGSTOP freezes | The plan says the library must subtract these, but not how |
| Releases v0.1 to v1.0 replace milestones M0 to M6, same order | Each release is usable on its own |
| New risks R3, R6 and R7 | Notifications when unsigned, scope, and competition for your time |
| New tqdm subclass (FW6), instead of a fork | Reaches existing tqdm code with one changed import, and leaves tqdm maintained by its own team |
| New `epochcontrol.loop()`, one line like tqdm (LIB0) | The easiest possible start, and it works for any long Python loop |
| Renamed from EpochBar to EpochControl | An active Mac App Store tool is called EpochBar. `plan.md` keeps the old name |
| Success measures added | To tell whether v1.0 worked |
| New §9, agent support, with AG requirements and scenarios S7 and S8 | Agents are a second kind of user, and a way to stand out |
| Repo gets a `CLAUDE.md` from the first commit | So agents can help build it safely |
