<p align="center">
  <img src="assets/gepa_ex.svg" alt="GEPA Elixir Logo" width="200" height="200">
</p>

# GEPA for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/gepa_ex.svg)](https://hex.pm/packages/gepa_ex)
[![Elixir](https://img.shields.io/badge/elixir-1.18.3-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/otp-27.3.3-blue.svg)](https://www.erlang.org)
[![Tests](https://img.shields.io/badge/tests-927%2F927%20passing-brightgreen)]()
[![Coverage](https://img.shields.io/badge/coverage-75.4%25-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/nshkrdotcom/gepa_ex/blob/main/LICENSE)

GEPA for Elixir is a library for optimizing text-based system components with LLM-backed reflection, Pareto search, and evaluator-driven workflows.

## Installation

Add `gepa_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gepa_ex, "~> 0.3.0"}
  ]
end
```

## Start Here

- [Getting Started](guides/getting_started.md)
- [Guides](guides/index.md)
- [Core API](guides/core_api.md)
- [LLM and Adapters](guides/llm_and_adapters.md)
- [Adapters](guides/adapters.md)
- [Generic RAG and Vector Stores](guides/generic_rag.md)
- [Optimization Workflow](guides/optimization_workflow.md)
- [Optimize Anything](guides/optimize_anything.md)
- [Confidence Adapter](guides/confidence_adapter.md)
- [Observability](guides/observability.md)
- [Upstream API Parity](guides/upstream_api_parity.md)
- [FAQ](guides/faq.md)
- [Examples and Livebooks](guides/examples_and_livebooks.md)

## Quick Start

```elixir
llm = GEPA.LLM.req_llm(:openai)
adapter = GEPA.Adapters.Basic.new(llm: llm)

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{"instruction" => "Answer exactly."},
    trainset: [%{input: "What is 2+2?", answer: "4"}],
    valset: [%{input: "What is 5+5?", answer: "10"}],
    adapter: adapter,
    max_metric_calls: 20
  )

IO.puts("Best score: #{GEPA.Result.best_score(result)}")
```

For evaluator-driven tasks, use `GEPA.OptimizeAnything.optimize_anything/1` and provide a candidate, evaluator, dataset, and objective text.

## What Ships

- Core optimization engine with Pareto fronts, state persistence, stop conditions, merge scheduling, and acceptance criteria
- Adapter contract plus shipped adapters for Q&A, default chat-style tasks, Generic RAG, confidence scoring, ReqLLM, Agent Session Manager, and testing
- Embedding behavior with a ReqLLM-backed Gemini embedding provider
- Generic RAG vector-store behavior with in-memory tests, real local Qdrant, and explicit stubs for pgvector, Weaviate, LanceDB, Chroma, and Milvus
- LLM facade with structured output support, streaming, and provider normalization through the shared `:inference` contracts
- Candidate proposal, batch sampling, and selection strategies including epsilon-greedy
- Telemetry, callbacks, tracking, and terminal progress output
- Result serialization and utility modules for code execution and evaluation caching

## Integration Roadmap and Upstream Gaps

`gepa_ex` is a headless Elixir port focused on the core optimizer, adapter
contracts, and live examples. Some upstream surfaces are represented as
abstractions or deterministic local backends so users can plug in their own
runtime without pulling extra infrastructure into the core package.

| Surface | Current status | Remaining gap |
| --- | --- | --- |
| Core optimizer | Real implementation: Pareto frontiers, reflection, merge, persistence, callbacks, telemetry, and `optimize_anything` run in Elixir. | Continue tracking upstream semantics and edge cases; no GUI is planned. |
| LLM adapters | Real normalized facade for ReqLLM and Agent Session Manager. GEPA keeps the `GEPA.LLM.*` compatibility API, but provider dispatch now delegates through the shared `:inference` adapter contracts. ASM/Gemini defaults to `gemini-3.1-flash-lite-preview`; ReqLLM/Gemini uses the same text model by default. | Provider coverage follows `:inference` plus the optional provider libraries installed by this app; upstream Python provider shims are not copied one-for-one. ASM/Gemini uses the local Gemini CLI auth/runtime path, not a hosted API key. ASM structured output remains unsupported until ASM exposes that contract. |
| Embeddings | Real `GEPA.Embeddings` behavior with `GEPA.Embeddings.ReqLLM`; default Gemini embedding model is `google:gemini-embedding-001`. | Other embedding providers can replace the behavior implementation later. Qdrant never creates embeddings. |
| Generic RAG vector store | Real vector-store behavior, deterministic `InMemory` for tests, local Qdrant through Docker/HTTP, and explicit stubs for pgvector, Weaviate, LanceDB, Chroma, and Milvus. | Qdrant currently uses direct HTTP calls by design; a production client or larger vector subsystem can replace that module without changing Generic RAG call sites. |
| Generic RAG adapter | Headless adapter pipeline with retrieval/generation metrics, injected embedder, and live Qdrant example using real embeddings plus real ASM/Gemini inference. | No hosted document-ingestion service is bundled. Non-Qdrant vector backends are stubs until implemented. |
| MCP adapter | Existing static/config MCP code may remain, but MCP runtime, transports, live examples, and parity work are WONT BUILD for this line of work by 2026-04-28 user directive. | Reopen only if MCP is explicitly brought back into scope. |
| Tracking integrations | Dependency-free tracker plus explicit W&B and MLflow stubs behind `GEPA.Tracking`. | Hosted W&B/MLflow clients are optional future work and should remain replaceable. |
| Examples and guides | Live, headless, adapter-backed scripts and guides. Qdrant RAG requires Docker Qdrant plus Gemini embedding credentials. | Examples should keep using real backends only; deterministic providers stay in tests. |

## Examples and Livebooks

- Live scripts: `examples/README.md`
- Batch runner: `examples/run_all.sh`
- Notebooks: `livebooks/README.md`

The scripts and notebooks are tied to the current codebase and should be read alongside the guide set above.

## HexDocs

The full API reference is generated from `mix.exs` and the module docs in `lib/`. The guide menu now lives under `guides/*.md`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes.
