# Observability

GEPA has four observability layers:

1. `GEPA.Telemetry`
2. `GEPA.Callbacks`
3. `GEPA.Tracking`
4. `GEPA.Progress`

They overlap, but they serve different jobs.

## Telemetry

`GEPA.Telemetry` emits a stable event schema with version metadata.

Events cover:

- run start and stop
- baseline evaluation
- iteration start and stop
- proposal generation and decision
- validation set updates
- evaluation batches

Use Telemetry handlers when you want structured metrics and are comfortable wiring an external consumer.

## Callbacks

`GEPA.Callbacks` is synchronous and visible to the engine. It supports events such as:

- `:optimization_start`
- `:optimization_end`
- `:iteration_start`
- `:iteration_end`
- `:candidate_selected`
- `:candidate_accepted`
- `:candidate_rejected`

Callbacks are meant for local side effects that belong to the run itself, not for async metric fanout.

## Tracking

`GEPA.Tracking` is a behavior for metric backends. The built-ins are:

- `GEPA.Tracking.NoOp`
- `GEPA.Tracking.InMemory`
- `GEPA.Tracking.WandB`
- `GEPA.Tracking.MLflow`

The tracking API expects scalar metrics, tables, and summary data. It intentionally does not try to render charts or notebooks.

`WandB` and `MLflow` are dependency-free placeholders. They compile behind the
same behavior and return `{:error, {:not_configured, backend}}` until a real
external client is wired in. This keeps the core optimizer independent from
hosted tracking SDKs while preserving the integration boundary.

LLM provider usage and cost metadata are normalized onto `GEPA.LLM.Response` when the selected LLM adapter returns them. Hosted ReqLLM clients and ASM clients both expose cost-related metadata where their providers make it available; task adapters decide whether that data is included in run-level tracking.

## Progress

`GEPA.Progress` prints a terminal progress display when `progress: true` or `progress: [width: 60, color: true]` is passed to `GEPA.optimize/1`.

It shows:

- progress or spinner state
- best score
- Pareto size
- ETA when possible

## Stop Files and Run Directories

When you provide `:run_dir`, GEPA can persist state and also watch for a `gepa.stop` file. That gives you a simple external kill switch without wiring custom signal handling.

## Code Execution

`GEPA.CodeExecution` is part of the observability story for optimize-anything evaluators. It captures `stdout` and returns structured error data instead of raising user-code failures directly.

That makes evaluator diagnostics available to reflection and tracking layers without losing the underlying failure context.
