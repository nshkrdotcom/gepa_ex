#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Running GEPA examples."
echo
echo "Examples 01-04 are deterministic and make no live LLM calls."
echo "Example 05 is LIVE and makes exactly one hosted-provider LLM call."
echo "Pass live provider credentials to this script and they will be forwarded to example 05."
echo
echo "Usage:"
echo "  examples/run_all.sh --provider openai --api-key sk-..."
echo "  examples/run_all.sh --provider gemini --api-key ..."
echo "  examples/run_all.sh --provider anthropic --api-key ..."
echo

mix run examples/01_quick_start.exs
mix run examples/02_math_problems.exs
mix run examples/03_custom_adapter.exs

rm -rf tmp/gepa_example_run
mix run examples/04_state_persistence.exs
rm -rf tmp/gepa_example_run

echo
echo "LIVE: running examples/05_llm_adapters.exs. This will make one hosted LLM call."
mix run examples/05_llm_adapters.exs -- "$@"
