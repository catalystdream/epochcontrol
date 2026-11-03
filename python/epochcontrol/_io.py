"""File writes that a reader never sees half done (PRD NF4, NF6)."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
from typing import Any


def clean(value: Any) -> Any:
    """Replace NaN and infinity with None: JSON has neither."""
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [clean(v) for v in value]
    return value


def write_json(path: Path, obj: Any) -> None:
    """Write to a temp file in the same folder, then rename over the target."""
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    data = json.dumps(clean(obj), ensure_ascii=False, allow_nan=False)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data + "\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def append_jsonl(path: Path, obj: Any) -> None:
    """Append one line. A single short write is not split by a concurrent reader."""
    line = json.dumps(clean(obj), ensure_ascii=False, allow_nan=False) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(line)


def read_json(path: Path) -> Any | None:
    """Read a JSON file; None if it is missing or not valid JSON."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
