#!/usr/bin/env elixir

# GEPA Quick Start Example
# ========================
#
# This is the simplest possible GEPA optimization example.
# It demonstrates the core concepts in just a few lines of code.
#
# ## What this does:
# - Optimizes a simple Q&A system
# - Uses mock LLM (no API keys needed!)
# - Runs for 10 iterations
# - Shows best result
#
# ## To run:
#   mix run examples/01_quick_start.exs
#
# This example is not live. It uses a deterministic mock LLM.
# See examples/05_llm_adapters.exs for a live hosted-provider smoke test.

# Mix.install([{:gepa_ex, path: "."}])
# Note: Mix.install is for standalone scripts. When running from project root,
# it's not needed as dependencies are already loaded.

# Training data: simple math questions
trainset = [
  %{input: "What is 2+2?", answer: "4"},
  %{input: "What is 5+3?", answer: "8"},
  %{input: "What is 10-7?", answer: "3"}
]

# Validation data: test the optimized system
valset = [
  %{input: "What is 6+4?", answer: "10"}
]

# Initial seed prompt (intentionally basic)
seed_candidate = %{
  "instruction" => "You are a helpful assistant."
}

IO.puts("""
🚀 GEPA Quick Start Example
===========================

Training set: #{length(trainset)} examples
Validation set: #{length(valset)} examples
Starting instruction: "#{seed_candidate["instruction"]}"
""")

IO.puts("Using deterministic mock LLM. This example makes no live LLM calls.")
llm = GEPA.LLM.Mock.new(response_fn: fn _prompt -> "The answer is 4, 8, 3, or 10." end)

# Create adapter
adapter = GEPA.Adapters.Basic.new(llm: llm)

# Run optimization
IO.puts("\n⚙️  Running optimization...")

{:ok, result} =
  GEPA.optimize(
    seed_candidate: seed_candidate,
    trainset: trainset,
    valset: valset,
    adapter: adapter,
    max_metric_calls: 10
  )

# Show results
IO.puts("""

✅ Optimization Complete!
========================

Best score: #{GEPA.Result.best_score(result)}
Iterations: #{result.i}
Total evaluations: #{result.total_num_evals}

Optimized instruction:
#{String.slice(GEPA.Result.best_candidate(result)["instruction"], 0, 200)}...

💡 Next steps:
- Try the live adapter smoke test: examples/05_llm_adapters.exs
- Increase iterations: Change max_metric_calls to 50
- Use your own data: Replace trainset and valset
- See more examples: examples/02_math_problems.exs
""")
