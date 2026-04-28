# FAQ

## Does GEPA include a vector database?

The Elixir port includes a vector-store behavior, in-memory test backend, real local Qdrant adapter, and stubs for pgvector, Weaviate, LanceDB, Chroma, and Milvus.

Qdrant stores and searches vectors. Embeddings are created separately through `GEPA.Embeddings`, currently backed by ReqLLM/Gemini.

## Does Qdrant create embeddings?

No. Use `GEPA.Embeddings.ReqLLM` or another future embedding adapter to create vectors before storing documents.

## Which live inference path is preferred?

For local agent-style inference, use Agent Session Manager with Gemini:

```elixir
GEPA.LLM.agent(:gemini, provider_opts: [model: "gemini-3.1-flash-lite-preview"])
```

For hosted structured output, use ReqLLM.

## Are examples mocked?

No. Public examples are live-only. Deterministic providers, fake modules, and mocks belong in tests.

## Why is MCP marked WONT BUILD?

The user directive on 2026-04-28 removed MCP runtime, transports, live examples, and user guides from this line of work. Existing static/config code may remain, but new MCP work should not be added unless scope is reopened.

## Why are W&B and MLflow stubs?

They reserve the tracking behavior boundary without adding hosted SDK dependencies to the core package. They fail explicitly until a real integration is selected.

## Why does ASM fail structured output?

ASM does not currently expose a native structured-output contract through GEPA. The adapter fails closed so callers do not mistake free-text parsing for provider-enforced JSON.

## What should I run before committing?

```bash
mix format --check-formatted
mix compile --warnings-as-errors --force
mix test
mix docs
mix dialyzer
mix credo --strict
```
