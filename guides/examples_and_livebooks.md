# Examples and Livebooks

The repo ships two teaching surfaces:

- `examples/` for live-only `.exs` scripts
- `livebooks/` for interactive notebooks

## Examples

The example scripts use real LLM backends through the GEPA LLM facade. They are not deterministic test fixtures.

The fastest smoke test is:

```bash
mix run examples/05_llm_adapters.exs -- --simple
```

To run the whole suite with built-in sample data:

```bash
examples/run_all.sh --simple
```

`examples/README.md` documents:

- provider defaults for ReqLLM and Agent Session Manager
- hosted providers: OpenAI, Gemini, Anthropic
- local agent providers: Codex, Codex Exec, Claude, Gemini, Amp
- live-call warnings
- data file formats
- troubleshooting

The scripts cover:

- quick start
- math problems
- custom adapters
- state persistence
- LLM adapters
- stop conditions
- merge and acceptance policies
- optimize-anything
- code execution
- refiner support
- tracking
- confidence-aware structured classification
- Generic RAG with local Qdrant, ReqLLM/Gemini embeddings, and ASM/Gemini inference

The examples use `--adapter` for the LLM adapter family and `--provider` for the backend:

```bash
mix run examples/05_llm_adapters.exs -- --adapter req_llm --provider anthropic
mix run examples/05_llm_adapters.exs -- --adapter asm --provider gemini --lane core
docker compose up -d qdrant
mix run examples/17_qdrant_rag.exs -- --simple
mix run examples/18_confidence_adapter.exs -- --simple
```

Task adapters in the examples are still GEPA-owned modules, usually `GEPA.Adapters.Basic` or a small custom `GEPA.Adapter` implementation inside the script.

## Livebooks

The notebooks in `livebooks/` are better when you want to explore the library interactively. They cover:

- quick start
- advanced optimization
- custom adapter construction

The live scripts are the canonical coverage for the full current provider matrix. Livebooks are best for interactive learning and may intentionally keep a smaller backend selector.

`livebooks/README.md` explains how to run them from Livebook Desktop or a local Livebook server.

## Which One To Use

- Use examples when you want a repeatable live script or CLI smoke test.
- Use livebooks when you want to inspect intermediate results and tweak cells interactively.
