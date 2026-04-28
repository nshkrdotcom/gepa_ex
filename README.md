<p align="center">
  <img src="assets/gepa_ex.svg" alt="GEPA Elixir Logo" width="200" height="200">
</p>

# GEPA for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/gepa_ex.svg)](https://hex.pm/packages/gepa_ex)
[![Elixir](https://img.shields.io/badge/elixir-1.18.3-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/otp-27.3.3-blue.svg)](https://www.erlang.org)
[![Tests](https://img.shields.io/badge/tests-329%2F329%20passing-brightgreen)]()
[![Coverage](https://img.shields.io/badge/coverage-75.4%25-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/nshkrdotcom/gepa_ex/blob/main/LICENSE)

GEPA for Elixir is a library for optimizing text-based system components with LLM-backed reflection, Pareto search, and evaluator-driven workflows.

## Installation

Add `gepa_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gepa_ex, "~> 0.2.0"}
  ]
end
```

## Start Here

- [Getting Started](guides/getting_started.md)
- [Core API](guides/core_api.md)
- [LLM and Adapters](guides/llm_and_adapters.md)
- [Optimization Workflow](guides/optimization_workflow.md)
- [Optimize Anything](guides/optimize_anything.md)
- [Observability](guides/observability.md)
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
- Adapter contract plus shipped adapters for Q&A, default chat-style tasks, ReqLLM, Agent Session Manager, and testing
- LLM facade with structured output support, streaming, and provider normalization
- Candidate proposal, batch sampling, and selection strategies including epsilon-greedy
- Telemetry, callbacks, tracking, and terminal progress output
- Result serialization and utility modules for code execution and evaluation caching

## Integration Roadmap and Upstream Gaps

`gepa_ex` is a headless Elixir port focused on the core optimizer, adapter
contracts, and live examples. Some upstream surfaces are represented as
abstractions or deterministic local backends so users can plug in their own
runtime without pulling extra infrastructure into the core package.

| Surface | Current status | Expected gap after the current parity pass |
| --- | --- | --- |
| Core optimizer | Real implementation: Pareto frontiers, reflection, merge, persistence, callbacks, telemetry, and `optimize_anything` run in Elixir. | Continue tracking upstream semantics and edge cases; no GUI is planned. |
| LLM adapters | Real normalized facade for ReqLLM and Agent Session Manager, plus test/mock adapters. | Provider coverage follows those libraries; upstream Python provider shims are not copied one-for-one. |
| Generic RAG vector store | Abstraction plus deterministic `InMemory` backend for tests, examples, and local development. | No production vector DB client is bundled. Qdrant, pgvector, Pinecone, Chroma, Weaviate, etc. should be optional adapters built against the vector-store behavior. |
| Generic RAG adapter | Headless adapter pipeline with retrieval/generation metrics and vector-store behavior. | No hosted document ingestion service, embedding service, or persistent vector index is included by default. |
| MCP adapter | Adapter contract, static test client, and dependency-free stdio/SSE/streamable HTTP transport config structs. | No bundled MCP SDK/runtime process manager. Real MCP transports should be supplied by an external client implementing `GEPA.Adapters.MCP.Client`. |
| Tracking integrations | Dependency-free experiment tracker and callback surface compatible with upstream-style events. | Hosted W&B/MLflow clients are not forced into the core package; external integrations can attach through callbacks/tracker behavior. |
| Examples and guides | Intended to be live, headless, and adapter-backed as this parity work finishes. | Examples should avoid GUI assumptions and should state when they use local mocks, in-memory stores, or real provider credentials. |

## Examples and Livebooks

- Live scripts: `examples/README.md`
- Batch runner: `examples/run_all.sh`
- Notebooks: `livebooks/README.md`

The scripts and notebooks are tied to the current codebase and should be read alongside the guide set above.

## HexDocs

The full API reference is generated from `mix.exs` and the module docs in `lib/`. The guide menu now lives under `guides/*.md`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes.
