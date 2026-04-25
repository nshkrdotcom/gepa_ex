# Changelog

## v0.2.0 · 2026-04-24

### Added
- `GEPA.OptimizeAnything` with nested config structs for engine, reflection, merge, refiner, and tracking workflows
- `GEPA.Adapters.Default` for prompt-style tasks without writing a custom adapter first
- `GEPA.CodeExecution` for in-process or subprocess Elixir snippet execution with structured results
- `GEPA.EvaluationCache` and cache-aware evaluation plumbing
- `GEPA.Progress` terminal progress output plus the `progress` option on `GEPA.optimize/1`
- `GEPA.Tracking` behavior with `NoOp` and `InMemory` backends
- `GEPA.Telemetry` event schema for run, baseline, iteration, proposal, valset, and evaluation events
- `GEPA.Callbacks` synchronous lifecycle hooks for optimization runs
- `GEPA.Result` round-trip persistence helpers and richer best-output metadata
- `GEPA.LLM` facade types and adapters, including `Client`, `Request`, `Response`, `Capabilities`, `Tool`, ReqLLM, and Agent Session Manager support
- `GEPA.Proposer.InstructionProposal` with configurable templates and structured-output support
- `GEPA.Strategies.CandidateSelector.EpsilonGreedy` with decay, reset, and stateful selector support
- New stop conditions for timeout, no improvement, max calls, score threshold, file stop, tracked candidates, proposal count, reflection cost, signal stop, and composite logic
- New live example suite, `examples/run_all.sh`, and `examples/support/live_cli.exs`
- New top-level guides under `guides/*.md` and a docs menu that groups guides, examples, livebooks, and module reference sections
- Expanded unit, property, integration, and live example coverage across optimization, proposals, telemetry, tracking, progress, and optimize-anything workflows

### Changed
- `GEPA.optimize/1` now covers adapter construction, progress, callbacks, tracking, merge scheduling, evaluation caching, and state persistence from one option surface
- `GEPA.Engine` coordinates proposal generation, acceptance, telemetry, progress, tracking, and adapter-state syncing in the main optimization loop
- `GEPA.State` now tracks objective and cartesian Pareto fronts, best outputs, adapter state, and validation schema version 5
- `GEPA.Result.from_state/1` preserves the expanded state and exposes objective-level summaries
- `GEPA.LLM.complete_structured/3` prefers native structured output and falls back to JSON parsing when needed
- `GEPA.Adapters.Basic` and `GEPA.Adapters.Default` now emit richer traces and objective scores for reflection
- `GEPA.LLM` default models and the live example defaults were normalized across hosted providers and ASM providers
- `GEPA.Proposer.Reflective` uses instruction proposal when configured instead of the earlier placeholder path
- `mix.exs` docs now surface the new guide set instead of the older design-doc pages

### Docs
- Reworked the README around the new guides and current public entrypoints
- Added `guides/getting_started.md`
- Added `guides/core_api.md`
- Added `guides/llm_and_adapters.md`
- Added `guides/optimization_workflow.md`
- Added `guides/optimize_anything.md`
- Added `guides/observability.md`
- Added `guides/examples_and_livebooks.md`

### Testing
- Expanded unit, property, integration, and live example tests across optimization, proposals, LLM adapters, progress, telemetry, tracking, and optimize-anything workflows

## v0.1.1 · 2025-11-29

### Changed
- Release v0.1.1 - documentation cleanup and tagging

## v0.1.0 · 2025-10-29

### Added
- Initial release of GEPA for Elixir. Core optimization engine, reflective proposer, Pareto state management, batch sampling, adapters, and production documentation delivered.
