# GEPA Live Examples

All examples in this directory are live-only. They require explicit provider configuration and user-supplied data or input. They do not inspect ambient shell credential state, do not choose a default provider, and do not run without a real ReqLLM or Agent Session Manager adapter selection.

## Cost Warning

These examples make real LLM calls. ReqLLM calls may incur hosted-provider charges. ASM calls may invoke local CLI agent sessions and whatever costs or side effects those providers normally carry. Every example prints a warning before making calls.

## No Defaults

You must pass both:

- `--adapter req_llm|asm`
- `--provider PROVIDER`

If either is missing, the example prints help and exits before any LLM call.

Provider-keyed model defaults:

- `--adapter req_llm --provider openai` uses `gpt-5.4-mini`
- `--adapter req_llm --provider gemini` uses `gemini-flash-lite-latest`
- `--adapter req_llm --provider anthropic` uses `claude-haiku-4-5`
- `--adapter asm --provider codex` uses the ASM/Codex default unless `--model` is provided
- `--adapter asm --provider claude` uses the ASM/Claude default unless `--model` is provided
- `--adapter asm --provider gemini` uses the ASM/Gemini default unless `--model` is provided
- `--adapter asm --provider amp` uses the ASM/Amp default unless `--model` is provided

Pass `--model VALUE` to override the selected provider default.

## Prerequisites

For ReqLLM:

- A provider key passed explicitly with `--api-key`.
- Provider selected with `--provider openai`, `--provider gemini`, or `--provider anthropic`.

For Agent Session Manager:

- `../agent_session_manager` available through the project dependency.
- The selected local provider CLI configured outside GEPA.
- Provider selected with `--provider codex`, `--provider codex_exec`, `--provider claude`, `--provider gemini`, or `--provider amp`.
- Optional `--lane auto|core|sdk`.
- Optional `--session NAME` for a named managed ASM session. Completion passes it to ASM as `session_id`; streaming starts a managed session and closes it when the stream is consumed.

Codex through ASM:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_codex_smoke \
  --input "Inspect this repository and summarize the GEPA example surface."
```

## Data Files

Optimization examples require JSONL data that you provide. Each line must be a JSON object.

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

ReqLLM:

```bash
mix run examples/01_quick_start.exs -- \
  --adapter req_llm \
  --provider openai \
  --api-key sk-... \
  --train-jsonl /path/to/qa_train.jsonl \
  --val-jsonl /path/to/qa_val.jsonl \
  --max-metric-calls 8
```

ASM Codex:

```bash
mix run examples/01_quick_start.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_quick_start \
  --train-jsonl /path/to/qa_train.jsonl \
  --val-jsonl /path/to/qa_val.jsonl \
  --max-metric-calls 8
```

### 02 Math Problems

Runs a live GEPA optimization over your math question/answer JSONL data.

```bash
mix run examples/02_math_problems.exs -- \
  --adapter req_llm \
  --provider gemini \
  --api-key ... \
  --train-jsonl /path/to/math_train.jsonl \
  --val-jsonl /path/to/math_val.jsonl \
  --max-metric-calls 8
```

### 03 Custom Sentiment Adapter

Runs a custom live adapter over your `text`/`sentiment` JSONL data.

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
  --adapter req_llm \
  --provider anthropic \
  --api-key ... \
  --train-jsonl /path/to/persistence_train.jsonl \
  --val-jsonl /path/to/persistence_val.jsonl \
  --run-dir /path/to/gepa_run \
  --max-metric-calls 8
```

### 05 LLM Adapter Smoke

Makes one real completion call through ReqLLM or ASM.

ReqLLM:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter req_llm \
  --provider openai \
  --api-key sk-... \
  --input "Reply with exactly: gepa adapter ok"
```

ASM Codex:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_adapter_smoke \
  --input "Reply with exactly: gepa adapter ok"
```

Structured output is available where the selected adapter supports it:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter req_llm \
  --provider openai \
  --api-key sk-... \
  --structured-output \
  --input "Return an improved instruction for a concise QA assistant."
```

Streaming is available through ASM. The adapter emits text chunks, not raw ASM event structs:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_stream \
  --stream \
  --input "Stream a short status update."
```

## Run Everything

`run_all.sh` runs every example. It requires separate data files for each example so that no packaged or generated data is hidden inside the runner.

ReqLLM:

```bash
examples/run_all.sh \
  --adapter req_llm \
  --provider openai \
  --api-key sk-... \
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

## Help

Every example and the runner support `--help`:

```bash
mix run examples/01_quick_start.exs -- --help
mix run examples/05_llm_adapters.exs -- --help
examples/run_all.sh --help
```

Calling an example without required args prints the same help plus concrete missing-argument errors and exits before any LLM call.

## Troubleshooting

- Missing `--adapter` or `--provider`: choose both explicitly.
- Missing `--api-key` with ReqLLM: pass the key with `--api-key`.
- ASM provider failure: confirm the local provider CLI works outside GEPA and that the selected `--lane` is valid.
- Streaming failure: use `--adapter asm`; ReqLLM streaming is intentionally not exposed by this temporary facade.
- Structured output failure with ASM: use ReqLLM for structured output until ASM has a native structured-output contract.
- JSONL load failure: verify each line is valid JSON and uses the fields required by the selected example.
