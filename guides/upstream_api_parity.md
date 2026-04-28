# Upstream API Parity

This guide records how the public Python GEPA API maps to the Elixir port. The
Elixir package is not a one-to-one Python namespace clone: it preserves the
headless optimizer, adapter contracts, RAG/vector abstractions, tracking hooks,
and examples while using Elixir module names and behaviours.

## Review Policy

- Core headless behavior is implemented in Elixir and covered by tests.
- Python ecosystem adapters are represented only when they expose reusable GEPA
  mechanics. DSPy, gskill, Terminal-Bench harnesses, and MCP runtime transports
  are not copied into the core package.
- Public examples are live-only. Deterministic clients are limited to tests.
- Vector stores sit behind `GEPA.Adapters.GenericRAG.VectorStore`; Qdrant is the
  current live backend and the other named stores are replaceable stubs.
- W&B and MLflow are behind tracking abstractions. The package ships local
  tracking and explicit stubs rather than hard dependencies on hosted clients.

## Top-Level Entrypoints

| Upstream surface | Elixir target | Status |
| --- | --- | --- |
| `gepa.optimize` | `GEPA.optimize/1` | Implemented. |
| `gepa.optimize_anything` | `GEPA.optimize_anything/1` and `GEPA.OptimizeAnything.optimize_anything/1` | Implemented. |
| `gepa.default_adapter` | `GEPA.default_adapter/1` and `GEPA.Adapters.Default.new/1` | Implemented. |
| `gepa.EvaluationBatch` | `GEPA.EvaluationBatch` | Implemented. |
| `gepa.GEPAAdapter` | `GEPA.Adapter` behaviour plus `GEPA.Adapter.Dispatch` | Implemented. |
| `gepa.GEPAResult` | `GEPA.Result` | Implemented. |
| `gepa.Image` | `GEPA.Image` | Implemented. |
| Stopper exports | `GEPA.StopCondition.*` modules | Implemented with Elixir names. |
| `gepa.aime` | `examples/02_math_problems.exs` and `examples/README.md` | Represented as a live example, not a library namespace. |

## Core Optimizer

| Upstream area | Elixir target | Coverage |
| --- | --- | --- |
| `gepa.api.optimize` | `GEPA.optimize/1` | `test/gepa/optimize_test.exs`, `test/integration/end_to_end_test.exs`, guides. |
| Adapter protocol and evaluation batch | `GEPA.Adapter`, `GEPA.Adapter.Dispatch`, `GEPA.EvaluationBatch` | Adapter dispatch, batch validation, full-program adapter parity tests. |
| Data loader | `GEPA.DataLoader`, `GEPA.DataLoader.List` | Loader tests and optimize entrypoint tests. |
| Engine | `GEPA.Engine` | Engine, callbacks, state, merge, and integration tests. |
| State and cache | `GEPA.State`, `GEPA.EvaluationCache` | State parity, cache, Pareto, and result tests. |
| Result object | `GEPA.Result` | Serialization, best-candidate accessors, visualization helpers. |
| Images | `GEPA.Image` | Path, URL, base64, media type, and OpenAI content-part tests. |

## Adapters

| Upstream area | Elixir target | Status |
| --- | --- | --- |
| Default adapter | `GEPA.Adapters.Default` | Implemented. |
| Confidence adapter | `GEPA.Adapters.Confidence` and `GEPA.Adapters.Confidence.Scoring.*` | Implemented with ReqLLM structured output for live examples. ASM structured output fails closed until supported upstream. |
| AnyMaths adapter | `examples/02_math_problems.exs`, `GEPA.Adapters.Basic`, `GEPA.Adapters.Default` | Represented as a live example and reusable adapter pattern. |
| Optimize Anything adapter | `GEPA.OptimizeAnything.Adapter` and config modules | Implemented. |
| Generic RAG adapter | `GEPA.Adapters.GenericRAG`, `Pipeline`, `Metrics`, `VectorStore` | Implemented with live Qdrant path. |
| DSPy adapters | `GEPA.CodeExecution`, `GEPA.OptimizeAnything`, examples 14-16 | WONT BUILD as DSPy dependencies. Headless full-program mechanics are represented. |
| Terminal-Bench adapter | `GEPA.CodeExecution`, example 10, guide coverage | WONT BUILD as benchmark harness dependency. |
| MCP adapter runtime | Existing static/config inventory only | WONT BUILD by user directive on 2026-04-28. |

## RAG And Vector Stores

`GEPA.Adapters.GenericRAG.VectorStore` is the common contract. Callers should
depend on that contract instead of a specific backend module.

| Upstream vector surface | Elixir target | Status |
| --- | --- | --- |
| Vector store interface | `GEPA.Adapters.GenericRAG.VectorStore` | Implemented behaviour-style API. |
| In-memory/local test store | `GEPA.Adapters.GenericRAG.VectorStore.InMemory` | Implemented for deterministic tests. |
| Qdrant | `GEPA.Adapters.GenericRAG.VectorStores.Qdrant` | Implemented through direct HTTP calls to local Docker Qdrant. |
| pgvector | `GEPA.Adapters.GenericRAG.VectorStores.Pgvector` | Stubbed by design. |
| Weaviate | `GEPA.Adapters.GenericRAG.VectorStores.Weaviate` | Stubbed by design. |
| LanceDB | `GEPA.Adapters.GenericRAG.VectorStores.LanceDB` | Stubbed by design. |
| Chroma | `GEPA.Adapters.GenericRAG.VectorStores.Chroma` | Stubbed by design. |
| Milvus | `GEPA.Adapters.GenericRAG.VectorStores.Milvus` | Stubbed by design. |

Qdrant stores and searches vectors. Embeddings are generated separately through
`GEPA.Embeddings`, with `GEPA.Embeddings.ReqLLM` as the first real provider.

## LLM, Embeddings, And Tracking

| Upstream area | Elixir target | Status |
| --- | --- | --- |
| LiteLLM language model | `GEPA.LLM`, `GEPA.LLM.Client`, `GEPA.LM`, `GEPA.LLM.Adapters.ReqLLM` | Implemented through ReqLLM. |
| Agent CLI inference | `GEPA.LLM.Adapters.AgentSessionManager` | Implemented for Claude, Codex, Gemini, and Amp via Agent Session Manager. |
| Embeddings | `GEPA.Embeddings`, `GEPA.Embeddings.ReqLLM` | Implemented. Default Gemini embedding path is live-tested by the Qdrant example. |
| Cost tracking | `GEPA.LM`, `GEPA.LLM.Tracking`, `GEPA.Tracking` | Implemented local counters and tracker calls. |
| Experiment tracker | `GEPA.Tracking.ExperimentTracker` and `GEPA.Tracking` | Implemented local tracker with W&B/MLflow replaceable stubs. |
| Logging protocol | Elixir `Logger`, callbacks, telemetry, and tracker modules | Represented through Elixir-native observability APIs. |

## Proposers And Strategies

| Upstream area | Elixir target | Status |
| --- | --- | --- |
| Candidate proposal | `GEPA.CandidateProposal`, `GEPA.Proposer` | Implemented. |
| Reflective mutation | `GEPA.Proposer.Reflective`, `GEPA.Proposer.InstructionProposal` | Implemented with structured output support where provider supports it. |
| Merge proposer | `GEPA.Proposer.Merge`, `GEPA.Proposer.MergeUtils` | Implemented. |
| Candidate selectors | `GEPA.Strategies.CandidateSelector.*` | Implemented: Pareto, current best, top-k Pareto, epsilon-greedy. |
| Component selectors | `GEPA.Strategies.ComponentSelector.*` | Implemented: round-robin and all-components. |
| Batch samplers | `GEPA.Strategies.BatchSampler.*` | Implemented: simple and epoch-shuffled. |
| Evaluation policies | `GEPA.Strategies.EvaluationPolicy.*` | Implemented: full and incremental. |
| Acceptance criteria | `GEPA.Strategies.Acceptance.*` | Implemented: strict improvement and improvement-or-equal. |

## Stop Conditions, Callbacks, And Utilities

| Upstream area | Elixir target | Status |
| --- | --- | --- |
| Stopper protocol | `GEPA.StopCondition` behaviour-style API | Implemented. |
| Composite stopper | `GEPA.StopCondition.Composite` | Implemented. |
| File stopper | `GEPA.StopCondition.FileStopper` | Implemented. |
| Max metric calls | `GEPA.StopCondition.MaxCalls` | Implemented. |
| No improvement | `GEPA.StopCondition.NoImprovement` | Implemented. |
| Score threshold | `GEPA.StopCondition.ScoreThreshold` | Implemented. |
| Signal stopper | `GEPA.StopCondition.SignalStopper` | Implemented. |
| Timeout | `GEPA.StopCondition.Timeout` | Implemented. |
| Callback protocol and events | `GEPA.Callbacks` with event maps | Implemented and covered by callback tests. |
| Code execution | `GEPA.CodeExecution` | Implemented for headless examples and optimize-anything workflows. |
| Pareto utilities | `GEPA.Utils`, `GEPA.Utils.Pareto` | Implemented. |
| Visualization | `GEPA.Visualization` | Implemented for DOT and HTML candidate trees. |

## Out-Of-Scope Upstream Names

These upstream names are intentionally not Elixir public API:

- MCP runtime transports and live MCP examples.
- DSPy module wrappers, DSPy signatures, and DSPy tool optimization classes.
- gskill coding-agent training/evaluation scripts and SWE harness code.
- Terminal-Bench orchestration helpers.
- Python-specific stdout capture and process harness internals.
- Hosted W&B/MLflow client bindings inside the core dependency tree.

The equivalent Elixir path is to compose the core optimizer with `GEPA.Adapter`,
`GEPA.OptimizeAnything`, `GEPA.CodeExecution`, `GEPA.LLM`, `GEPA.Embeddings`,
`GEPA.Tracking`, and any external backend client selected by the application.
