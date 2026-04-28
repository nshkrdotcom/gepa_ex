# Changelog

## v0.3.0 · 2026-04-28

### Added
- Added upstream-style top-level convenience surfaces: `GEPA.optimize_anything/1` and `GEPA.default_adapter/1`.
- Added `GEPA.Adapters.Confidence` plus `GEPA.Adapters.Confidence.Scoring` strategies for confidence-aware classification optimization.
- Added `GEPA.Adapters.GenericRAG`, `GEPA.Adapters.GenericRAG.Pipeline`, `GEPA.Adapters.GenericRAG.Metrics`, and the shared vector-store contract for headless RAG optimization.
- Added `GEPA.Embeddings` and `GEPA.Embeddings.ReqLLM`; ReqLLM/Gemini embeddings are the first real embedding provider.
- Added local Qdrant support through `GEPA.Adapters.GenericRAG.VectorStores.Qdrant` and `docker-compose.yml`.
- Added explicit vector-store stubs for pgvector, Weaviate, LanceDB, Chroma, and Milvus so future backends can replace the current modules without changing Generic RAG call sites.
- Added W&B and MLflow tracking stubs behind the tracking abstraction, with clear failure behavior when hosted clients are not configured.
- Added `GEPA.LM` and `GEPA.LM.Tracking` compatibility helpers for upstream LM-style usage and cost/token counters.
- Added `GEPA.Image`, `GEPA.Seed`, richer `GEPA.Visualization`, and official alias modules for documented upstream naming.
- Added static/config MCP adapter inventory and tests while keeping MCP runtime transports out of scope for this line of work.
- Added live examples for ADR cloud optimization, ARC grids, blackbox search, circle packing, Qdrant RAG, and confidence-aware classification.
- Added `guides/upstream_api_parity.md` plus new HexDocs guides for adapters, candidate selection, component selection, batch sampling, acceptance criteria, merge, stop conditions, callbacks, cost tracking, experiment tracking, FAQ, and contributing.

### Changed
- Reworked adapter dispatch so structs, modules, and optional adapter-state/proposal hooks are handled consistently.
- Aligned core engine behavior more closely with upstream GEPA semantics, including acceptance, callbacks, state persistence, merge scheduling, metric-call accounting, and proposal handling.
- Expanded `GEPA.State` persistence and legacy upcast behavior for newer Pareto, cache, adapter-state, and validation-schema fields.
- Improved `GEPA.Result` round-tripping and public best-candidate helpers.
- Refined `GEPA.Proposer.InstructionProposal`, reflective mutation, merge proposer, and merge utilities against upstream signature and merge behavior.
- Expanded `GEPA.CodeExecution` from simple snippet execution to rich structured results, hashing, side-info conversion, and safer example usage.
- Tightened `GEPA.DataLoader`, `GEPA.EvaluationBatch`, `GEPA.EvaluationCache`, candidate selection, component selection, batch sampling, acceptance criteria, and Pareto utility behavior against upstream parity tests.
- Updated Agent Session Manager and ReqLLM integration defaults for the live adapter path, including ASM/Gemini defaults documented around `gemini-3.1-flash-lite-preview`.
- Updated examples to be live-only for public scripts and to reject fake/mock provider paths outside tests.
- Converted the generated `GepaEx.hello/0` scaffold into a hidden compatibility facade that delegates to the main `GEPA` entrypoints.
- Reworked README onboarding, integration roadmap, examples catalog, and HexDocs guide navigation around the current 0.3.0 public surface.

### Fixed
- Fixed Dialyzer, compiler warning, Credo strict, docs, and formatting issues found during the integration and parity pass.
- Fixed stale example API usage in code execution and tracking examples.
- Fixed confidence adapter documentation and examples to use the actual Elixir option names and provider capabilities.
- Fixed live example runner behavior so the confidence adapter uses ReqLLM structured output even when the rest of the suite is using Agent Session Manager.
- Fixed README test badge count after the public API tests were added.

### Docs
- Added a durable upstream API parity guide that records implemented, represented, stubbed, and WONT BUILD surfaces.
- Expanded Generic RAG documentation with Qdrant, embedding generation, vector-store behavior, backend stubs, and live setup expectations.
- Expanded confidence-adapter documentation with ReqLLM structured-output guidance and ASM structured-output limitations.
- Added professional HexDocs menu coverage for guide, example, integration, and public API parity workflows.
- Updated `examples/README.md` to cover all shipped live examples and their real adapter requirements.
- Documented the integration roadmap and upstream gaps in the README, including vector stores, embeddings, tracking, MCP scope, and live-only examples.

### Testing
- Expanded the suite to 925 tests plus 16 properties.
- Added upstream parity coverage for merge behavior, instruction proposal signatures, acceptance criteria, AIME-style optimization, tracking, batch sampling, callbacks, candidate selection, confidence adapter/scoring, data loading, full-program adapter behavior, evaluation cache, evaluator wrapper, experiment tracker, GEPA utilities, images, imports, incremental evaluation, LM helpers, MCP static/config inventory, module selection, optimize-anything templates, callbacks, Pareto frontier types, RAG metrics, Generic RAG adapter, RAG interface/end-to-end/pipeline behavior, vector-store interface, refiner behavior, reflection cost tracking, result upcasting, seed generation, state persistence, visualization, and ADR/example parity.
- Added integration coverage for Generic RAG and local Qdrant-backed workflows.
- Completed full quality gates at release-prep checkpoints: `mix format --check-formatted`, `mix compile --warnings-as-errors --force`, `mix test`, `mix docs`, `mix dialyzer`, and `mix credo --strict`.

### Scope Decisions
- MCP runtime transports, MCP live examples, and MCP parity work remain WONT BUILD by explicit project direction on 2026-04-28.
- DSPy, gskill, Terminal-Bench orchestration, and Python-specific harnesses are represented through Elixir headless mechanisms and examples rather than copied as runtime dependencies.
- Qdrant is the first wired vector backend; other vector stores are intentionally stubbed until a larger vector subsystem or dedicated clients are introduced.
- Qdrant stores and searches vectors only; embeddings are generated separately through `GEPA.Embeddings`.

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
