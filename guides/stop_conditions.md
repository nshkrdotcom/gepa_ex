# Stop Conditions

Every GEPA run needs a way to stop.

## Built-In Conditions

- `GEPA.StopCondition.MaxCalls`
- `GEPA.StopCondition.MaxCandidateProposals`
- `GEPA.StopCondition.MaxReflectionCost`
- `GEPA.StopCondition.Timeout`
- `GEPA.StopCondition.ScoreThreshold`
- `GEPA.StopCondition.NoImprovement`
- `GEPA.StopCondition.MaxTrackedCandidates`
- `GEPA.StopCondition.SignalStopper`
- `GEPA.StopCondition.FileStopper`
- `GEPA.StopCondition.Composite`

## Common Options

```elixir
GEPA.optimize(
  seed_candidate: seed,
  trainset: train,
  valset: val,
  adapter: adapter,
  max_metric_calls: 100,
  max_candidate_proposals: 20,
  max_reflection_cost: 2.50,
  run_dir: "tmp/gepa_run"
)
```

`max_metric_calls` is usually the primary budget. `run_dir` enables persistence and file-based stopping.

## Composite Stops

Use `GEPA.StopCondition.Composite` when you need several rules at once.

```elixir
stopper =
  GEPA.StopCondition.Composite.new([
    GEPA.StopCondition.Timeout.new(seconds: 600),
    GEPA.StopCondition.ScoreThreshold.new(threshold: 0.95)
  ])
```

## File Stopper

When a run directory is configured, create a stop file from another shell or process to ask the run to stop cleanly.

```bash
touch path/to/run_dir/gepa.stop
```

The run still returns a normal `GEPA.Result`; it is not killed mid-write.
