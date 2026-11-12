# EpochControl reference

Everything the package, the command line and the menu-bar app do, in one place. The
[README](../README.md) is the short tour; this page is the full list. Keep it in step with
the code: a feature is not done until it is described here (see `CLAUDE.md`).

Contents: [Python API](#python-api) · [Environment variables](#environment-variables) ·
[Command line](#command-line) · [Menu-bar app](#menu-bar-app) ·
[Runs on other machines](#runs-on-other-machines) · [Files](#files) · [Limits](#limits)

---

## Python API

`pip install epochcontrol` · Python 3.10+ · no required dependencies · works on macOS and
Linux. A failure inside the package warns once and never raises into your training loop.

### `epochcontrol.loop(iterable, name=None, total=None, **options)`

The one-line version, like tqdm. Yields the items of `iterable` and reports each one done.

```python
for epoch in epochcontrol.loop(range(200), name="tft lstm h20"):
    train_one_epoch()
```

- `name`: shown in the app and the CLI. Default: the script's file name.
- `total`: number of items. Default: `len(iterable)` if it has one.
- `options`: any `start()` option below (`group=`, `open_app=` …).
- Pause and Stop act **between items**: a paused loop holds back the next item; a stopped
  loop ends and the code after it still runs.
- Wrap the outer (epoch) loop, not the batch loop.

### `epochcontrol.start(name=None, total_epochs=None, **options) -> Run`

The full version: losses, best epoch, patience, checkpoints. Also usable as
`with epochcontrol.start(...) as run:` (an exception then marks the run failed).

| Option | Default | What it does |
|---|---|---|
| `name` | script name | Shown in the app and the CLI |
| `total_epochs` | `None` | Progress and ETA; without it the run counts up |
| `patience` | `None` | Epochs without a better `monitor` value before "patience exceeded" |
| `monitor` | `"val"` | Which logged value decides the best epoch |
| `mode` | `"min"` | `"min"` (loss) or `"max"` (accuracy) |
| `stop_on_patience` | `False` | End the run once `patience` is used up (checkpoint saved first) |
| `checkpoint_on_pause` | `True` | Save a checkpoint on Pause as well as on Stop |
| `run_dir` | `None` | Your own output folder, shown in the app; never deleted by EpochControl |
| `tags` | `[]` | Free labels stored with the run |
| `open_app` | `True` | Open the Mac app when the run starts (Mac with a screen session only) |
| `group` | `$EPOCHCONTROL_GROUP` | Group name for runs started by one script (see [Groups](#groups)) |
| `group_total` | `$EPOCHCONTROL_GROUP_TOTAL` | How many runs that script will start |

### `Run` methods

| Method | What it does |
|---|---|
| `run.epochs(start=0)` | Yields epoch numbers from `start` to `total_epochs` (forever if unknown). Between epochs: saves a checkpoint if one is due, waits while paused, ends on Stop |
| `run.log(epoch=e, train=…, val=…, lr=…, **more)` | Records a finished epoch. `epoch` counts **from 0** (the epoch just completed). Any number is accepted (tensors with `.item()` too); non-numbers are skipped with one warning; NaN is stored as null. Call once per epoch, after validation |
| `run.on_checkpoint(save)` | Registers your save function; called on Stop (and Pause, unless `checkpoint_on_pause=False`) at the next epoch boundary |
| `run.resume_from(path, load)` | If `path` exists, calls `load(path)`, which returns the epoch to start from; returns 0 without a checkpoint |
| `run.finish(state=None, error=None)` | Ends the run: stopped if Stop was pressed, else finished. A `with` block, an uncaught exception or a forgotten `finish()` close the run too |
| `run.timing()` | Wall, active, paused and slept seconds so far |

For a loop you cannot restructure, call these at the end of each epoch instead of using
`epochs()`:

```python
run.log(epoch=e, train=tl, val=vl)
run.checkpoint_if_requested(save_fn)   # saves if a pause or stop is waiting
if run.should_stop():                  # True once Stop was pressed
    break
run.wait_if_paused()                   # blocks while paused
```

### Full example

```python
import epochcontrol

run = epochcontrol.start(name="tft lstm h20", total_epochs=400, patience=60, monitor="val", mode="min")
run.on_checkpoint(lambda: save_checkpoint(ckpt_path))
start_epoch = run.resume_from(ckpt_path, load_checkpoint)
for epoch in run.epochs(start=start_epoch):
    train_loss = train_one_epoch()
    val_loss = validate()
    run.log(epoch=epoch, train=train_loss, val=val_loss)
run.finish()
```

In multi-GPU code only the main process reports: guard with `if rank == 0`.

### Groups

Runs started by one script, for example a bash loop over seeds, are shown together:
"aeroconf A1 · spark  4 of 9 done · 1 running · 4 to go". No change to the Python code:

```bash
export EPOCHCONTROL_GROUP="aeroconf A1"
export EPOCHCONTROL_GROUP_TOTAL=9
for seed in 42 43 44 45 46 47 48 49 50; do
    python train.py --seed $seed
done
```

- The total is what you declare; if more runs start, the total grows to match.
- Reusing the same name more than 1 hour after the last run of the batch ended starts a new
  batch, so running the script again tomorrow starts at "0 of 9".
- Runs on different machines are separate batches.
- A group only counts. It never starts, skips or resumes runs (that is the planned queue,
  v0.3).
- Needs package 0.1.1 or later in the training environment.

---

## Environment variables

| Variable | Effect |
|---|---|
| `EPOCHCONTROL_HOME` | Base folder; runs go in its `runs/`. Default: macOS `~/Library/Application Support/EpochControl`, Linux `$XDG_DATA_HOME/epochcontrol` (`~/.local/share/epochcontrol`) |
| `EPOCHCONTROL_NO_APP=1` | Never open the Mac app from a run (same as `open_app=False` everywhere) |
| `EPOCHCONTROL_GROUP` | Group name for every run this shell starts |
| `EPOCHCONTROL_GROUP_TOTAL` | How many runs the group will have (a whole number ≥ 1; anything else is ignored) |

The training process and the CLI must see the same `EPOCHCONTROL_HOME`, or they look in
different folders.

---

## Command line

```bash
epochcontrol ls [-n N]          # runs, newest first (default 20; -n 0 = all)
epochcontrol status [RUN]       # one run in detail
epochcontrol pause  [RUN]       # acts at the end of the current epoch
epochcontrol resume [RUN]
epochcontrol stop   [RUN]       # clean stop, checkpoint first if registered
epochcontrol agent-guide        # instructions for coding agents (= docs/llms.txt)
```

- `RUN` is a run id, an id prefix or a name. Without it: the only run in progress.
- Every command takes `--json` (format: [`schemas/cli.schema.json`](../schemas/cli.schema.json)).
- `pause`, `resume`, `stop` also take `--by cli|agent` (recorded in the run's events) and
  `--wait SECONDS` (how long to wait for the run to confirm, default 3).
- Exit codes: 0 done, 1 error, 2 not found, 3 refused (for example a finished run),
  4 ambiguous.

States: `starting`, `running`, `paused`, `stopping`, `stopped`, `finished`, `failed` are
written by the run. `stalled` (no heartbeat, process alive) and `lost` (process gone) are
worked out by whoever reads. The app adds `offline` for a remote run it cannot reach.

---

## Menu-bar app

macOS 14+. Built from the repo for now (`cd macos && scripts/bundle.sh`, then copy
`build/EpochControl.app` to `/Applications`). It opens by itself when a run starts; quitting
it never affects a run.

**Icon:** a progress ring for the oldest live run; marks for paused, stalled, failed and
finished-but-unseen.

**Popover, top to bottom:**

- **Runs card:** how many are training; an amber line for any remote host that is offline;
  one line per [group](#groups) that is running or was active in the last 12 hours (tap it
  to list that batch's runs); then live runs plus the 3 most recent ended ones. Remote runs
  are labelled `host · name`.
- **Show all (N):** the history. Every run, newest day first (Today, Yesterday, Mon 9 Nov),
  with filters for machine (All, This Mac, each host) and outcome (Finished, Stopped,
  Failed). Shows the newest 150 matches; filter to reach older ones. "‹ Recent" goes back.
- **Tiles** for the selected run: Progress (with ETA), Patience, Best val, Time (active,
  paused, slept).
- **Loss chart:** train and val, best validation epoch marked in green, linear or log.
- **Buttons:** Pause / Resume, Stop (asks first), Remote hosts (network icon), Open folder
  (local runs only), Quit.

The cards scroll when they do not fit on the screen; the header and buttons stay put.

Pause and Stop are **cooperative**: they act at the end of the current epoch, after a
checkpoint if the script registered one.

---

## Runs on other machines

Watch and control runs on a Linux GPU box (DGX Spark, a server, a cloud VM) from the Mac,
over SSH. No server, no open port, nothing extra installed on the remote machine.

**On the remote machine:**

1. `pip install epochcontrol` in the training environment, and use `loop()` or `start()` as
   on the Mac.
2. `python3` on the PATH of a non-interactive SSH session (any Python 3.6+; Ubuntu has it).
3. If training runs inside Docker, mount `~/.local/share/epochcontrol` out of the container.

**On the Mac:**

1. An SSH login that does not ask for a password: `ssh -o BatchMode=yes <host> true` must
   succeed (a key in `~/.ssh`, the ssh agent, or 1Password's agent all work). Set `User`
   and `HostName` in `~/.ssh/config` if needed.
2. In the app: network icon → **Remote hosts** → type the SSH name (`spark`, or several,
   comma separated) → **Save**.

**What happens:** every 5 seconds the app runs `ssh <host> python3 -` and sends a small
reader that ships with the app (Python standard library only). It reads the run folders on
that machine and answers with their status; chart points come only for live runs and runs
on screen. Pause, Resume and Stop write the same command file there that the app writes
locally. Liveness and heartbeat age are worked out on the remote machine, so clock
differences do not matter.

**When the host cannot be reached:** its runs turn grey and show **offline** with their last
known state, never "lost"; an amber line in the Runs card gives the reason. They come back
by themselves when the host answers again.

**Privacy:** only status, metadata and metrics leave the remote machine; a recorded command
line (`record_command=True`) never does. Host names are checked before they reach `ssh`.

**Troubleshooting:**

| Shown | Fix |
|---|---|
| `offline · Permission denied` | The login prompts or is refused: test `ssh -o BatchMode=yes <host> true` |
| `offline · no answer in time` | Host down, asleep, or off Tailscale |
| `offline · …python3: not found` | Install Python 3 on the remote machine |
| Host green, "0 runs", but training | The run writes elsewhere: same user? `EPOCHCONTROL_HOME` set? inside Docker? |

---

## Files

One folder per run, in the runs folder (see `EPOCHCONTROL_HOME`):

| File | Written by | Content |
|---|---|---|
| `meta.json` | the run, once | name, pid, host, start time, total, group … |
| `status.json` | the run, every heartbeat | state, epoch, best, patience, timing, ETA |
| `metrics.jsonl` | the run, per epoch | one line per `log()` call |
| `events.jsonl` | the run | started, paused, commands received … |
| `control.json` | app, CLI, agent | the latest command with a sequence number |

All writes are atomic (temp file, then rename). Formats: [`schemas/`](../schemas/). Folders
are private to the user (0700, files 0600).

---

## Limits

- Pause and Stop act between epochs (or loop items), not in the middle of one.
- History and groups for a remote host cover its newest 300 runs while the history is open
  (30 otherwise).
- An offline host's last known state is kept in memory only: after an app restart, its runs
  appear once it answers again.
- Not an experiment tracker: no run comparison, sweeps or sharing. Use W&B, TensorBoard or
  trackio next to it.
