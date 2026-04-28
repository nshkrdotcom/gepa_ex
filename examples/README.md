# GEPA Live Examples

All examples in this directory are live-only. They call the real selected LLM backend through the GEPA LLM facade. Deterministic replacement modules are limited to tests.

The example-only CLI helper lives in `examples/support/live_cli.exs`. It is intentionally not part of `lib/` or the public package API.

## Fast Start

If `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `OPENAI_API_KEY`, or `ANTHROPIC_API_KEY` is configured, the fastest live smoke is:

```bash
mix run examples/05_llm_adapters.exs -- --simple
```

To run every example with small built-in demo prompts/data:

```bash
examples/run_all.sh --simple
```

Both commands make real LLM calls. They may incur provider costs.

## Cost Warning

Each example prints a live-call warning before making any LLM call. `examples/run_all.sh` prints a stronger warning because it executes the full example suite and can make many calls.

## Sensible Defaults

When `--adapter` and `--provider` are omitted, examples default to ReqLLM using the first configured hosted provider in this order:

- Gemini: `GEMINI_API_KEY`, then `GOOGLE_API_KEY`
- OpenAI: `OPENAI_API_KEY`
- Anthropic: `ANTHROPIC_API_KEY`

Explicit CLI options override these defaults:

- `--adapter req_llm|asm`
- `--provider openai|gemini|anthropic` for ReqLLM
- `--provider codex|codex_exec|claude|gemini|amp` for ASM
- `--api-key VALUE` for an explicit ReqLLM key override
- `--model VALUE` for an explicit model override

If `--adapter asm` is provided without `--provider`, the default ASM provider is `gemini`.

Default models:

- `--adapter req_llm --provider openai` uses `gpt-5.4-mini`
- `--adapter req_llm --provider gemini` uses `gemini-3.1-flash-lite-preview`
- `--adapter req_llm --provider anthropic` uses `claude-haiku-4-5`
- `--adapter asm --provider codex` uses `gpt-5.4-mini`
- `--adapter asm --provider gemini` uses `gemini-3.1-flash-lite-preview`
- `--adapter asm --provider claude` uses the ASM/Claude default unless `--model` is provided
- `--adapter asm --provider amp` uses the ASM/Amp default unless `--model` is provided

## ReqLLM

ReqLLM examples support OpenAI, Gemini, and Anthropic:

```bash
mix run examples/05_llm_adapters.exs -- \
  --provider gemini \
  --input "Reply with exactly: gepa adapter ok"
```

Use `--api-key` only when you want to override the default key lookup:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter req_llm \
  --provider openai \
  --api-key sk-... \
  --input "Reply with exactly: gepa adapter ok"
```

Structured output is available where the selected ReqLLM provider supports it:

```bash
mix run examples/05_llm_adapters.exs -- \
  --provider gemini \
  --structured-output \
  --input "Return an improved instruction for a concise QA assistant."
```

## Agent Session Manager

ASM examples support local/CLI providers through `../agent_session_manager`:

- `codex`
- `codex_exec`
- `claude`
- `gemini`
- `amp`

Codex through ASM:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_codex_smoke \
  --input "Reply with exactly: gepa adapter ok"
```

ASM streaming emits text chunks at the GEPA facade boundary:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_stream \
  --stream \
  --input "Stream a short status update."
```

ASM provider prerequisites, authentication, sandboxing, and local CLI setup are managed outside GEPA by Agent Session Manager and the selected CLI provider.

## Simple Mode

`--simple` is a live convenience mode:

- It still makes real LLM calls.
- It infers the provider from configured keys unless you pass explicit provider options.
- It supplies small built-in demo prompts/data for examples that otherwise need JSONL input.
- It uses a small optimization budget by default: `--max-metric-calls 2` and `--minibatch-size 1`.

Examples:

```bash
mix run examples/01_quick_start.exs -- --simple
mix run examples/02_math_problems.exs -- --simple
mix run examples/03_custom_adapter.exs -- --simple
mix run examples/04_state_persistence.exs -- --simple
mix run examples/05_llm_adapters.exs -- --simple
mix run examples/06_stop_conditions.exs -- --simple
mix run examples/07_merge_and_policies.exs -- --simple
mix run examples/08_optimize_anything_single_task.exs -- --simple
mix run examples/09_optimize_anything_dataset.exs -- --simple
mix run examples/10_code_execution.exs -- --simple
mix run examples/11_refiner.exs -- --simple
mix run examples/12_tracking.exs -- --simple
mix run examples/13_adrs_cloud_optimization.exs -- --simple
mix run examples/14_arc_grid.exs -- --simple
mix run examples/15_blackbox_search.exs -- --simple
mix run examples/16_circle_packing.exs -- --simple
mix run examples/17_qdrant_rag.exs -- --simple
```

You can combine `--simple` with explicit backend selection:

```bash
mix run examples/05_llm_adapters.exs -- \
  --simple \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_simple_codex
```

## Data Files

Without `--simple`, optimization examples require JSONL data that you provide. Each line must be a JSON object.

Question/answer examples use:

```json
{"input":"<your real question>","answer":"<expected answer text>"}
```

Sentiment adapter example uses:

```json
{"text":"<your real text>","sentiment":"positive"}
```

Supported sentiment labels are `positive`, `negative`, and `neutral`.

## Examples

### 01 Quick Start

Runs a small live GEPA optimization over question/answer JSONL data.

```bash
mix run examples/01_quick_start.exs -- \
  --provider gemini \
  --train-jsonl /path/to/qa_train.jsonl \
  --val-jsonl /path/to/qa_val.jsonl \
  --max-metric-calls 8
```

### 02 Math Problems

Runs a live GEPA optimization over AIME-style math question/answer JSONL data.
The solver prompt is optimized while the selected live adapter answers each
problem. Rows should contain `input` and a final numeric `answer`; `--simple`
uses a tiny built-in arithmetic set for a quick live smoke.

```bash
mix run examples/02_math_problems.exs -- \
  --provider gemini \
  --train-jsonl /path/to/math_train.jsonl \
  --val-jsonl /path/to/math_val.jsonl \
  --max-metric-calls 8
```

### 03 Custom Sentiment Adapter

Runs a custom live adapter over `text`/`sentiment` JSONL data.

```bash
mix run examples/03_custom_adapter.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_sentiment \
  --train-jsonl /path/to/sentiment_train.jsonl \
  --val-jsonl /path/to/sentiment_val.jsonl \
  --max-metric-calls 8
```

### 04 State Persistence

Runs or resumes a live optimization with checkpoint persistence.

```bash
mix run examples/04_state_persistence.exs -- \
  --provider gemini \
  --train-jsonl /path/to/persistence_train.jsonl \
  --val-jsonl /path/to/persistence_val.jsonl \
  --run-dir /path/to/gepa_run \
  --max-metric-calls 8
```

### 05 LLM Adapter Smoke

Makes one real completion call through ReqLLM or ASM.

```bash
mix run examples/05_llm_adapters.exs -- --simple
```

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_adapter_smoke \
  --input "Reply with exactly: gepa adapter ok"
```

### 06 Stop Conditions

Runs GEPA with multiple stop conditions composed together.

```bash
mix run examples/06_stop_conditions.exs -- --simple
```

### 07 Merge and Policies

Runs GEPA with merge enabled and explicit strategy settings.

```bash
mix run examples/07_merge_and_policies.exs -- --simple
```

### 08 Optimize Anything Single Task

Optimizes a single prompt string with a live LLM-backed evaluator.

```bash
mix run examples/08_optimize_anything_single_task.exs -- --simple
```

### 09 Optimize Anything Dataset

Optimizes a prompt map over question/answer examples.

```bash
mix run examples/09_optimize_anything_dataset.exs -- --simple
```

### 10 Code Execution

Optimizes a small Elixir snippet and evaluates it through `GEPA.CodeExecution`.

```bash
mix run examples/10_code_execution.exs -- --simple
```

### 11 Refiner

Runs `GEPA.OptimizeAnything` with the per-evaluation refiner enabled.

```bash
mix run examples/11_refiner.exs -- --simple
```

### 12 Tracking

Runs GEPA with `GEPA.Tracking.InMemory` enabled.

```bash
mix run examples/12_tracking.exs -- --simple
```

### 13 ADR Cloud Optimization

Optimizes a cloud architecture-decision policy across two headless ADR-style
domains: deadline-aware spot/on-demand scheduling and cost-aware multi-cloud
broadcast routing. The evaluator uses built-in scenario maps and the selected
live LLM adapter proposes policy revisions through `GEPA.OptimizeAnything`.

```bash
mix run examples/13_adrs_cloud_optimization.exs -- --simple
```

Expected output includes `ADR Cloud Optimization Complete`, the best validation
score, and the best policy text. If the score stays low, increase
`--max-metric-calls` or use a stronger reflection model.

### 14 ARC Grid

Optimizes a headless ARC grid-solving instruction. The live adapter sees
training input/output grids and predicts a test output grid as compact JSON.
`--simple` uses a tiny fixture set; custom JSONL rows should provide `input`
as the full ARC task prompt and `answer` as the exact JSON grid to match.

```bash
mix run examples/14_arc_grid.exs -- --simple
```

Expected output includes `ARC Grid Optimization Complete`, the best validation
score, and the best instruction. If exact JSON matching is brittle for a
provider, make the `answer` string and task prompt agree on compact formatting.

### 15 Blackbox Search

Optimizes executable Elixir search code for a small blackbox minimization
problem. The evaluator executes candidate code with `GEPA.CodeExecution`, tracks
objective-call budget use, and feeds prior best trials back into later
proposals.

```bash
mix run examples/15_blackbox_search.exs -- --simple
```

Expected output includes `Blackbox Search Optimization Complete`, the best
transformed score, and the best candidate code. If generated code fails, the
feedback includes execution errors and budget details.

### 16 Circle Packing

Optimizes executable Elixir geometry code that packs circles inside the
unit square. The evaluator runs candidate code with `GEPA.CodeExecution`,
validates the returned circle list, scores valid layouts by the sum of radii,
and feeds the best prior layout back into later candidates.

```bash
mix run examples/16_circle_packing.exs -- --simple
```

Candidate code must bind `pack = fn config, current_best_solution -> ... end`
and return `%{circles: circles, all_scores: scores}`. Each circle may be
`%{x: x, y: y, r: r}` or `[x, y, r]`. `--simple` uses four circles for a short
live smoke; full mode uses twenty-six circles to match the upstream problem
shape.

Expected output includes `Circle Packing Optimization Complete`, the problem
size, the best `sum_radii`, and the best candidate code. If generated code
returns an invalid layout, evaluator feedback reports shape errors, boundary
violations, negative radii, overlaps, stdout, and execution errors.

### 17 Qdrant RAG

Runs Generic RAG with a real local Qdrant container, real ReqLLM/Gemini
embeddings, and real Agent Session Manager/Gemini inference. Qdrant stores and
searches vectors; it does not create embeddings.

Start Qdrant first:

```bash
docker compose up -d qdrant
```

Then run the live integration smoke:

```bash
mix run examples/17_qdrant_rag.exs -- --simple
```

The default inference path is `--adapter asm --provider gemini` using
`gemini-3.1-flash-lite-preview`. The default embedding model is
`google:gemini-embedding-001` through ReqLLM. Override local services with:

```bash
mix run examples/17_qdrant_rag.exs -- \
  --adapter asm \
  --provider gemini \
  --qdrant-url http://localhost:6333 \
  --collection gepa_ex_qdrant_rag \
  --embedding-model gemini-embedding-001 \
  --max-metric-calls 2
```

## Run Everything

`run_all.sh` runs every example.

Fast live demo:

```bash
examples/run_all.sh --simple
```

With your own data:

```bash
examples/run_all.sh \
  --provider gemini \
  --qa-train-jsonl /path/to/qa_train.jsonl \
  --qa-val-jsonl /path/to/qa_val.jsonl \
  --math-train-jsonl /path/to/math_train.jsonl \
  --math-val-jsonl /path/to/math_val.jsonl \
  --sentiment-train-jsonl /path/to/sentiment_train.jsonl \
  --sentiment-val-jsonl /path/to/sentiment_val.jsonl \
  --persistence-train-jsonl /path/to/persistence_train.jsonl \
  --persistence-val-jsonl /path/to/persistence_val.jsonl \
  --run-dir /path/to/gepa_run_all \
  --smoke-input "Reply with exactly: gepa adapter ok" \
  --max-metric-calls 8
```

ASM Codex:

```bash
examples/run_all.sh \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_run_all \
  --simple
```

## Help

Every example and the runner support `--help`:

```bash
mix run examples/01_quick_start.exs -- --help
mix run examples/05_llm_adapters.exs -- --help
examples/run_all.sh --help
```

Calling `examples/run_all.sh` without arguments prints the same help menu and does not run the suite. Calling an individual example without required args prints help plus concrete missing-argument errors and exits before any LLM call.

## Troubleshooting

- Missing default key: set `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `OPENAI_API_KEY`, or `ANTHROPIC_API_KEY`, or pass `--adapter/--provider/--api-key`.
- Wrong literal API key: pass the actual secret value, for example `--api-key "$GEMINI_API_KEY"`, not `--api-key GEMINI_API_KEY`.
- ReqLLM provider failure: confirm the hosted provider key and selected model are valid.
- ASM provider failure: confirm the local provider CLI works outside GEPA and that the selected `--lane` is valid.
- Streaming failure: use `--adapter asm`; ReqLLM streaming is intentionally not exposed by this temporary facade.
- Structured output failure with ASM: use ReqLLM for structured output until ASM has a native structured-output contract.
- JSONL load failure: verify each line is valid JSON and uses the fields required by the selected example.
- Qdrant RAG failure: run `docker compose up -d qdrant`, confirm `curl http://localhost:6333/collections`, and set `GEMINI_API_KEY` or `GOOGLE_API_KEY` for embeddings.
