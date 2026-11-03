# EpochControl in the FIS2 / SensorFusionTFT work: guide for the PostDoc session

*Written 3 Nov 2026 for the Claude session that works in `Incarico Post Doc/`. Personal to
Harrish's setup: remove or move this file before the repo goes public.*

## What EpochControl is

A Python package plus a Mac menu-bar app. The package, called from a training loop, writes a
small status folder per run; the app (already installed in `/Applications` and running) shows
progress, losses, best epoch, patience and honest timing, and sends Pause / Resume / Stop. Full
API and rules for agents: run `epochcontrol agent-guide` after installing, or read
`~/Documents/Projects/EpochControl/docs/llms.txt`.

## Goal of this task

v0.2 is done when Harrish has used the app for **one week of real overnight runs on the Mac**.
Your job: install the package in the Mac training environment, add it to **copies** of the
training scripts used for that week, and help check the results.

## Rules (read first)

1. **Never touch the code or folders behind submitted or paper results.** Work on a copy of the
   script (e.g. `<name>_ec.py` next to it), and confirm the file list with Harrish first.
2. The training logic, data, model, seeds, output names (`R_<name>`, run folders) and the
   revision ledger stay exactly as they are. EpochControl only observes and controls.
3. Reuse the script's existing checkpoint save and load; do not invent a new checkpoint format.
4. Only Mac runs (MPS, conda `sftft_mac`). The DGX Spark: not yet (the app cannot see remote
   runs until v2).
5. Never pause or stop a run without Harrish's OK. Reading status is always fine.

## 1. Install (once)

```bash
conda activate sftft_mac
pip install -e ~/Documents/Projects/EpochControl/python
epochcontrol --version          # 0.1.0.dev0 or later
epochcontrol agent-guide        # the API, the rules, the commands
```

Editable install: later fixes in the repo apply without reinstalling. `pip install
epochcontrol` from PyPI also works once v0.1.0 is published (today PyPI has only a placeholder,
0.0.1, which does nothing).

## 2. Add it to a training script copy

The full form, which fits the revision scripts (epochs, validation, checkpoints):

```python
import epochcontrol

run = epochcontrol.start(
    name="tft-lstm lumo s43",            # short; shown in the menu bar
    total_epochs=n_epochs,
    patience=patience,                   # the script's own early-stopping patience
    monitor="val", mode="min",
    run_dir=str(out_dir),                # the script's existing run folder (shown in the app)
    stop_on_patience=False,              # True only if the script has no early stopping of its own
)
run.on_checkpoint(lambda: save_checkpoint(...))           # the script's existing save
start_epoch = run.resume_from(ckpt_path, load_checkpoint) # load returns the epoch to start from

for epoch in run.epochs(start=start_epoch):
    train_loss = train_one_epoch(...)
    val_loss = validate(...)
    run.log(epoch=epoch, train=train_loss, val=val_loss, lr=current_lr)
run.finish()
```

If the loop cannot be restructured, keep it and call at the end of each epoch:
`run.log(...)`, `run.checkpoint_if_requested(save_fn)`, then `if run.should_stop(): break`,
then `run.wait_if_paused()`. The smallest form, progress only:
`for epoch in epochcontrol.loop(range(n_epochs), name="..."):`.

Check with a short run (2–3 epochs) before an overnight one:

```bash
epochcontrol ls                 # the run appears, state running, epochs counting
epochcontrol pause              # applies at the next epoch boundary
epochcontrol ls                 # wait until it shows paused
epochcontrol resume
epochcontrol stop               # ends at the epoch boundary, checkpoint saved
```

## 3. The week of overnight runs

- Start runs as usual (with `caffeinate -i python …` if that is how they run).
- Each morning, read `epochcontrol ls` and note in the PostDoc journal anything that was wrong
  or missing: wrong numbers, a run marked stalled or lost that was fine, timing that looks off,
  something Harrish wanted to see and could not.
- Training time for the paper: `run.timing` gives `active_s` (sleep and pauses excluded);
  the status file `status.json` keeps it after the run.

## 4. The lid-close test (Harrish does it, you check)

The Mac must really sleep for this, so: unplug the external display, quit any `caffeinate`
(`pkill caffeinate`, only if no run depends on it), keep Internet Sharing off. Start a run,
close the lid for at least 5 minutes, open it. Then:

```bash
epochcontrol status --json      # timing.slept_s ≈ the time the lid was closed; active_s did not grow
```

## 5. Report back

Collect findings (date, run, what happened, what was expected) in the PostDoc journal under
"EpochControl", and give Harrish the list at the end of the week. Fixes happen in the
EpochControl repo (`~/Documents/Projects/EpochControl`), not in the training code.
