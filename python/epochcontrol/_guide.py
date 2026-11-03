"""Instructions for coding agents (PRD AG1, AG14). docs/llms.txt is generated from this text."""

GUIDE = """\
# EpochControl: guide for coding agents

EpochControl reports a training run's progress and lets the user pause, resume and stop it
from the Mac menu bar or the command line. It needs no account and no network.
Install: pip install epochcontrol (no required dependencies).

## Smallest change: any loop

    import epochcontrol
    for epoch in epochcontrol.loop(range(num_epochs), name="short descriptive name"):
        ...  # the existing body, unchanged

Wrap the OUTER loop (epochs), not the batch loop. Pause and stop act between iterations.

## Full version: losses, best epoch, patience, safe stop

    import epochcontrol
    run = epochcontrol.start(name="...", total_epochs=num_epochs, patience=40, monitor="val", mode="min")
    run.on_checkpoint(lambda: save_checkpoint(ckpt_path))       # existing save function
    start_epoch = run.resume_from(ckpt_path, load_checkpoint)    # load returns the epoch to start from
    for epoch in run.epochs(start=start_epoch):
        train_loss = train_one_epoch(...)
        val_loss = validate(...)
        run.log(epoch=epoch, train=train_loss, val=val_loss, lr=current_lr)
    run.finish()

Early stopping: add `stop_on_patience=True` to start(); the run then ends after `patience`
epochs without a better `monitor` value (checkpoint saved first). Off by default.
Or use `with epochcontrol.start(...) as run:`; an exception then marks the run failed.
For a loop that cannot be restructured, at the end of each epoch call:
`run.log(...)`, `run.checkpoint_if_requested(save_fn)`, then `if run.should_stop(): break`,
then `run.wait_if_paused()`.

## Rules
- Do not change the training logic, the model, the data or the results folder.
- Reuse the project's existing checkpoint save and load code; do not write a new format.
- log() takes numbers (tensors with .item() are fine). Call it once per epoch, after validation.
- Only the main process reports: in multi-GPU code, guard with `if rank == 0`.
- Never pause or stop a run without the user's approval. Reading status is always fine.

## Reading and controlling runs
    epochcontrol ls --json                        # all runs, newest first
    epochcontrol status [RUN] --json              # one run
    epochcontrol pause|resume|stop [RUN] --by agent --json
RUN is a run id, an id prefix or a name; without it, the only run in progress.
Exit codes: 0 done, 1 error, 2 not found, 3 refused (for example a finished run), 4 ambiguous.
States: running, paused, stopping, stopped, finished, failed; stalled (no heartbeat, process
alive) and lost (process gone) are worked out by the reader.
"""
