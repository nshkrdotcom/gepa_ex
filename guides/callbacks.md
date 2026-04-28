# Callbacks

Callbacks are synchronous hooks fired by the optimizer lifecycle.

Use callbacks for run-local side effects:

- logging
- debugging
- lightweight audit records
- custom progress messages
- safe notifications

Use Telemetry or tracking for metrics fanout.

## Events

Common events include:

- `:optimization_start`
- `:optimization_end`
- `:iteration_start`
- `:iteration_end`
- `:candidate_selected`
- `:candidate_accepted`
- `:candidate_rejected`

The callback receives event data from the engine. Treat the data as read-only.

## Composite Callbacks

`GEPA.Callbacks.Composite` lets you combine multiple callback modules or functions.

```elixir
callback = fn event, data ->
  IO.inspect({event, Map.keys(data)})
  :ok
end

GEPA.optimize(
  seed_candidate: seed,
  trainset: train,
  adapter: adapter,
  callbacks: [callback],
  max_metric_calls: 20
)
```

## Failure Behavior

Callback failures are logged and isolated from the optimizer. Do not rely on callbacks for correctness-critical task evaluation. Put that logic inside the adapter instead.
