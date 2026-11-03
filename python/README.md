# epochcontrol

See and control your training runs from the Mac menu bar: progress, losses and honest timing at a glance, with pause, resume and stop for a running job. Python package plus a native macOS app. Local, no account.

**Early development.** Working now: `loop()`.

```python
import epochcontrol

for epoch in epochcontrol.loop(range(200), name="my run"):
    train_one_epoch()
```

Pause, resume and stop take effect between iterations. The CLI and the macOS app come next.
