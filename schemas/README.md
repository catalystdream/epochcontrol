# Schemas

The contract between the Python package and the macOS app (PRD §11). JSON Schema, draft 2020-12. `examples/` holds valid samples. Change a schema before the code that uses it.

`lost` and `stalled` are not in `status.json`: a frozen process cannot report them, so readers work them out.

`cli.schema.json` is the `--json` output of the `epochcontrol` command, which agents read. Exit codes: 0 done, 1 error, 2 not found, 3 refused (for example a finished run), 4 ambiguous run name.
