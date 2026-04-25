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

Sensible Defaults:
  With --simple, this runner uses built-in demo prompts/data and infers the
  hosted ReqLLM provider from configured keys in this order:
    1. GEMINI_API_KEY, then GOOGLE_API_KEY -> req_llm/gemini
    2. OPENAI_API_KEY                    -> req_llm/openai
    3. ANTHROPIC_API_KEY                 -> req_llm/anthropic

  Explicit --adapter, --provider, --api-key, --model, data paths, and generation
  options always override defaults. If --adapter asm is provided without a
  provider, the default ASM provider is codex.

Fastest Live Smoke:
  examples/run_all.sh --simple

Usage With Your Data:
  examples/run_all.sh --provider gemini \
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

Provider Options:
  --simple                   Use defaults and built-in demo input/data where needed
  --adapter req_llm|asm      Optional when defaults can infer it
  --provider openai|gemini|anthropic for ReqLLM
  --provider codex|codex_exec|claude|gemini|amp for ASM
  --api-key VALUE            Optional ReqLLM key override

Data/Input Options:
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

  Data/input options are required unless --simple is used. In --simple mode,
  explicit data/input paths still override the built-in demo prompts/data.

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

Default API Keys:
  Gemini                     GEMINI_API_KEY, then GOOGLE_API_KEY
  OpenAI                     OPENAI_API_KEY
  Anthropic                  ANTHROPIC_API_KEY

Default Models:
  --adapter req_llm --provider openai     -> gpt-5.4-mini
  --adapter req_llm --provider gemini     -> gemini-3.1-flash-lite-preview
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

has_value() {
  [[ -n "${1:-}" ]]
}

key_for_provider() {
  case "$1" in
    gemini)
      printf '%s' "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"
      ;;
    openai)
      printf '%s' "${OPENAI_API_KEY:-}"
      ;;
    anthropic)
      printf '%s' "${ANTHROPIC_API_KEY:-}"
      ;;
    *)
      printf ''
      ;;
  esac
}

default_req_llm_provider() {
  if has_value "$(key_for_provider gemini)"; then
    printf 'gemini'
  elif has_value "$(key_for_provider openai)"; then
    printf 'openai'
  elif has_value "$(key_for_provider anthropic)"; then
    printf 'anthropic'
  else
    return 1
  fi
}

infer_adapter_for_provider() {
  case "$1" in
    openai|gemini|anthropic)
      printf 'req_llm'
      ;;
    codex|codex_exec|claude|amp)
      printf 'asm'
      ;;
    *)
      return 1
      ;;
  esac
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

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
simple="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --simple) simple="true"; shift ;;
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

if ! has_value "$adapter" && has_value "$provider"; then
  if ! adapter="$(infer_adapter_for_provider "$provider")"; then
    errors+=("invalid --provider ${provider}; cannot infer adapter")
  fi
fi

if has_value "$adapter" && ! has_value "$provider"; then
  case "$adapter" in
    req_llm)
      if provider="$(default_req_llm_provider)"; then
        :
      else
        errors+=("could not infer ReqLLM provider; set GEMINI_API_KEY, GOOGLE_API_KEY, OPENAI_API_KEY, or ANTHROPIC_API_KEY, or pass --provider")
      fi
      ;;
    asm)
      provider="codex"
      ;;
    *)
      errors+=("invalid --adapter ${adapter}; expected req_llm or asm")
      ;;
  esac
fi

if ! has_value "$adapter" && ! has_value "$provider"; then
  adapter="req_llm"

  if provider="$(default_req_llm_provider)"; then
    :
  else
    errors+=("could not infer a default provider; set GEMINI_API_KEY, GOOGLE_API_KEY, OPENAI_API_KEY, or ANTHROPIC_API_KEY, or pass --adapter/--provider")
  fi
fi

case "$adapter" in
  req_llm)
    case "$provider" in
      openai|gemini|anthropic) ;;
      *) errors+=("invalid --provider ${provider} for --adapter req_llm; expected openai, gemini, or anthropic") ;;
    esac
    ;;
  asm)
    case "$provider" in
      codex|codex_exec|claude|gemini|amp) ;;
      *) errors+=("invalid --provider ${provider} for --adapter asm; expected codex, codex_exec, claude, gemini, or amp") ;;
    esac
    ;;
  *)
    errors+=("invalid --adapter ${adapter}; expected req_llm or asm")
    ;;
esac

if [[ "$simple" == "false" ]]; then
  [[ -n "$qa_train_jsonl" ]] || errors+=("missing required --qa-train-jsonl unless --simple is used")
  [[ -n "$qa_val_jsonl" ]] || errors+=("missing required --qa-val-jsonl unless --simple is used")
  [[ -n "$math_train_jsonl" ]] || errors+=("missing required --math-train-jsonl unless --simple is used")
  [[ -n "$math_val_jsonl" ]] || errors+=("missing required --math-val-jsonl unless --simple is used")
  [[ -n "$sentiment_train_jsonl" ]] || errors+=("missing required --sentiment-train-jsonl unless --simple is used")
  [[ -n "$sentiment_val_jsonl" ]] || errors+=("missing required --sentiment-val-jsonl unless --simple is used")
  [[ -n "$persistence_train_jsonl" ]] || errors+=("missing required --persistence-train-jsonl unless --simple is used")
  [[ -n "$persistence_val_jsonl" ]] || errors+=("missing required --persistence-val-jsonl unless --simple is used")
  [[ -n "$run_dir" ]] || errors+=("missing required --run-dir unless --simple is used")
  [[ -n "$smoke_input" ]] || errors+=("missing required --smoke-input unless --simple is used")
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  error_and_usage "${errors[@]}"
  exit 64
fi

common_args=(--adapter "$adapter" --provider "$provider")
[[ "$simple" == "false" ]] || common_args+=(--simple)
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

qa_args=("${common_args[@]}")
[[ -z "$qa_train_jsonl" ]] || qa_args+=(--train-jsonl "$qa_train_jsonl")
[[ -z "$qa_val_jsonl" ]] || qa_args+=(--val-jsonl "$qa_val_jsonl")

math_args=("${common_args[@]}")
[[ -z "$math_train_jsonl" ]] || math_args+=(--train-jsonl "$math_train_jsonl")
[[ -z "$math_val_jsonl" ]] || math_args+=(--val-jsonl "$math_val_jsonl")

sentiment_args=("${common_args[@]}")
[[ -z "$sentiment_train_jsonl" ]] || sentiment_args+=(--train-jsonl "$sentiment_train_jsonl")
[[ -z "$sentiment_val_jsonl" ]] || sentiment_args+=(--val-jsonl "$sentiment_val_jsonl")

persistence_args=("${common_args[@]}")
[[ -z "$persistence_train_jsonl" ]] || persistence_args+=(--train-jsonl "$persistence_train_jsonl")
[[ -z "$persistence_val_jsonl" ]] || persistence_args+=(--val-jsonl "$persistence_val_jsonl")
[[ -z "$run_dir" ]] || persistence_args+=(--run-dir "$run_dir")

smoke_args=("${common_args[@]}")
[[ -z "$smoke_input" ]] || smoke_args+=(--input "$smoke_input")

cat <<WARNING
LIVE LLM CALL WARNING
=====================

Running all GEPA examples with real provider calls.
Adapter/provider: $adapter/$provider
Simple mode: $simple
This may incur provider costs and may invoke local CLI agents for ASM providers.

WARNING

mix run examples/01_quick_start.exs -- "${qa_args[@]}"
mix run examples/02_math_problems.exs -- "${math_args[@]}"
mix run examples/03_custom_adapter.exs -- "${sentiment_args[@]}"
mix run examples/04_state_persistence.exs -- "${persistence_args[@]}"
mix run examples/05_llm_adapters.exs -- "${smoke_args[@]}"
