# Experiment Tracking

`GEPA.Tracking` is the experiment-tracking behavior used by optimizer runs.

## Built-Ins

- `GEPA.Tracking.NoOp`
- `GEPA.Tracking.InMemory`
- `GEPA.Tracking.WandB`
- `GEPA.Tracking.MLflow`

`NoOp` is the default safe backend. `InMemory` is useful for tests, examples, and local inspection.

```elixir
tracker = GEPA.Tracking.InMemory.new(key_prefix: "run")

{:ok, result} =
  GEPA.optimize(
    seed_candidate: seed,
    trainset: train,
    valset: val,
    adapter: adapter,
    tracker: tracker,
    max_metric_calls: 20
  )

GEPA.Tracking.InMemory.snapshot(tracker)
```

## External Backends

`GEPA.Tracking.WandB` and `GEPA.Tracking.MLflow` are explicit stubs. They compile behind the same behavior and return `{:error, {:not_configured, backend}}` until real hosted clients are wired.

This is deliberate. The core optimizer should not depend on hosted tracking SDKs. A future integration can replace these modules or route the behavior through a separate tracking subsystem.

## What To Log

The tracking behavior supports:

- scalar metrics
- tables
- summary values

Keep large artifacts outside tracker calls unless the backend is built to handle them. Store run state through `:run_dir` and log a path or artifact ID.
