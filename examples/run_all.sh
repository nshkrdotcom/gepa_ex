#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
GEPA Live Examples Runner
=========================

LIVE LLM CALL WARNING:
  This script runs every example with real provider calls. It may make many LLM
  calls and may incur provider costs. With ASM providers, it may invoke local
  CLI agent sessions. Stop now if that is not what you intend.

No Default Provider Or Adapter:
  There is intentionally no default --adapter and no default --provider.
  You must choose both explicitly.

Usage:
  examples/run_all.sh --adapter req_llm --provider openai --api-key sk-... \
    --qa-train-jsonl path --qa-val-jsonl path \
    --math-train-jsonl path --math-val-jsonl path \
    --sentiment-train-jsonl path --sentiment-val-jsonl path \
    --persistence-train-jsonl path --persistence-val-jsonl path \
    --run-dir path --smoke-input "your real prompt"

  examples/run_all.sh --adapter asm --provider codex --lane core --session gepa_run_all \
    --qa-train-jsonl path --qa-val-jsonl path \
    --math-train-jsonl path --math-val-jsonl path \
    --sentiment-train-jsonl path --sentiment-val-jsonl path \
    --persistence-train-jsonl path --persistence-val-jsonl path \
    --run-dir path --smoke-input "your real prompt"

Required Provider Options:
  --adapter req_llm|asm
  --provider openai|gemini|anthropic for ReqLLM
  --provider codex|codex_exec|claude|gemini|amp for ASM
  --api-key VALUE is required only for --adapter req_llm

Required Data/Input Options:
  --qa-train-jsonl PATH
  --qa-val-jsonl PATH
  --math-train-jsonl PATH
  --math-val-jsonl PATH
  --sentiment-train-jsonl PATH
  --sentiment-val-jsonl PATH
  --persistence-train-jsonl PATH
  --persistence-val-jsonl PATH
  --run-dir PATH
  --smoke-input TEXT

Common Options Forwarded To Every Example:
  --model VALUE
  --temperature FLOAT
  --max-tokens INTEGER
  --timeout INTEGER
  --top-p FLOAT
  --max-metric-calls INTEGER
  --minibatch-size INTEGER
  --structured-output

ASM Options:
  --lane auto|core|sdk
  --session VALUE

Default Models:
  --adapter req_llm --provider openai     -> gpt-5.4-mini
  --adapter req_llm --provider gemini     -> gemini-flash-lite-latest
  --adapter req_llm --provider anthropic  -> claude-haiku-4-5
  --adapter asm --provider codex          -> ASM/Codex default unless --model is provided
  --adapter asm --provider claude         -> ASM/Claude default unless --model is provided
  --adapter asm --provider gemini         -> ASM/Gemini default unless --model is provided
  --adapter asm --provider amp            -> ASM/Amp default unless --model is provided
USAGE
}

error_and_usage() {
  printf 'Error:\n' >&2
  for error in "$@"; do
    printf '  %s\n' "$error" >&2
  done
  printf '\n' >&2
  usage >&2
}

adapter=""
provider=""
api_key=""
model=""
lane=""
session=""
qa_train_jsonl=""
qa_val_jsonl=""
math_train_jsonl=""
math_val_jsonl=""
sentiment_train_jsonl=""
sentiment_val_jsonl=""
persistence_train_jsonl=""
persistence_val_jsonl=""
run_dir=""
smoke_input=""
temperature=""
max_tokens=""
timeout=""
top_p=""
max_metric_calls=""
minibatch_size=""
structured_output="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --adapter) adapter="${2:-}"; shift 2 ;;
    --provider) provider="${2:-}"; shift 2 ;;
    --api-key) api_key="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --lane) lane="${2:-}"; shift 2 ;;
    --session) session="${2:-}"; shift 2 ;;
    --qa-train-jsonl) qa_train_jsonl="${2:-}"; shift 2 ;;
    --qa-val-jsonl) qa_val_jsonl="${2:-}"; shift 2 ;;
    --math-train-jsonl) math_train_jsonl="${2:-}"; shift 2 ;;
    --math-val-jsonl) math_val_jsonl="${2:-}"; shift 2 ;;
    --sentiment-train-jsonl) sentiment_train_jsonl="${2:-}"; shift 2 ;;
    --sentiment-val-jsonl) sentiment_val_jsonl="${2:-}"; shift 2 ;;
    --persistence-train-jsonl) persistence_train_jsonl="${2:-}"; shift 2 ;;
    --persistence-val-jsonl) persistence_val_jsonl="${2:-}"; shift 2 ;;
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --smoke-input) smoke_input="${2:-}"; shift 2 ;;
    --temperature) temperature="${2:-}"; shift 2 ;;
    --max-tokens) max_tokens="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --top-p) top_p="${2:-}"; shift 2 ;;
    --max-metric-calls) max_metric_calls="${2:-}"; shift 2 ;;
    --minibatch-size) minibatch_size="${2:-}"; shift 2 ;;
    --structured-output) structured_output="true"; shift ;;
    *)
      error_and_usage "unknown option $1"
      exit 64
      ;;
  esac
done

errors=()
[[ -n "$adapter" ]] || errors+=("missing required --adapter")
[[ -n "$provider" ]] || errors+=("missing required --provider")
[[ "$adapter" != "req_llm" || -n "$api_key" ]] || errors+=("missing required --api-key for --adapter req_llm")
[[ -n "$qa_train_jsonl" ]] || errors+=("missing required --qa-train-jsonl")
[[ -n "$qa_val_jsonl" ]] || errors+=("missing required --qa-val-jsonl")
[[ -n "$math_train_jsonl" ]] || errors+=("missing required --math-train-jsonl")
[[ -n "$math_val_jsonl" ]] || errors+=("missing required --math-val-jsonl")
[[ -n "$sentiment_train_jsonl" ]] || errors+=("missing required --sentiment-train-jsonl")
[[ -n "$sentiment_val_jsonl" ]] || errors+=("missing required --sentiment-val-jsonl")
[[ -n "$persistence_train_jsonl" ]] || errors+=("missing required --persistence-train-jsonl")
[[ -n "$persistence_val_jsonl" ]] || errors+=("missing required --persistence-val-jsonl")
[[ -n "$run_dir" ]] || errors+=("missing required --run-dir")
[[ -n "$smoke_input" ]] || errors+=("missing required --smoke-input")

if [[ ${#errors[@]} -gt 0 ]]; then
  error_and_usage "${errors[@]}"
  exit 64
fi

common_args=(--adapter "$adapter" --provider "$provider")
[[ -z "$api_key" ]] || common_args+=(--api-key "$api_key")
[[ -z "$model" ]] || common_args+=(--model "$model")
[[ -z "$lane" ]] || common_args+=(--lane "$lane")
[[ -z "$session" ]] || common_args+=(--session "$session")
[[ -z "$temperature" ]] || common_args+=(--temperature "$temperature")
[[ -z "$max_tokens" ]] || common_args+=(--max-tokens "$max_tokens")
[[ -z "$timeout" ]] || common_args+=(--timeout "$timeout")
[[ -z "$top_p" ]] || common_args+=(--top-p "$top_p")
[[ -z "$max_metric_calls" ]] || common_args+=(--max-metric-calls "$max_metric_calls")
[[ -z "$minibatch_size" ]] || common_args+=(--minibatch-size "$minibatch_size")
[[ "$structured_output" == "false" ]] || common_args+=(--structured-output)

cat <<WARNING
LIVE LLM CALL WARNING
=====================

Running all GEPA examples with real provider calls.
Adapter/provider: $adapter/$provider
This may incur provider costs and may invoke local CLI agents for ASM providers.

WARNING

mix run examples/01_quick_start.exs -- "${common_args[@]}" \
  --train-jsonl "$qa_train_jsonl" --val-jsonl "$qa_val_jsonl"

mix run examples/02_math_problems.exs -- "${common_args[@]}" \
  --train-jsonl "$math_train_jsonl" --val-jsonl "$math_val_jsonl"

mix run examples/03_custom_adapter.exs -- "${common_args[@]}" \
  --train-jsonl "$sentiment_train_jsonl" --val-jsonl "$sentiment_val_jsonl"

mix run examples/04_state_persistence.exs -- "${common_args[@]}" \
  --train-jsonl "$persistence_train_jsonl" --val-jsonl "$persistence_val_jsonl" --run-dir "$run_dir"

mix run examples/05_llm_adapters.exs -- "${common_args[@]}" --input "$smoke_input"
