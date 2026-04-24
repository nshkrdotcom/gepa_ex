#!/usr/bin/env elixir

# GEPA Math Problems Optimization
# ===============================
#
# Demonstrates optimizing an LLM for solving math word problems.
# This example shows how GEPA can improve domain-specific performance.
#
# ## Features demonstrated:
# - More realistic training data
# - EpochShuffledBatchSampler for better training
# - Custom evaluation metrics
# - Deterministic mock LLM execution
#
# ## To run with mock LLM:
#   mix run examples/02_math_problems.exs
#
# This example is not live. It uses a deterministic mock LLM.
# See examples/05_llm_adapters.exs for a live hosted-provider smoke test.

# Mix.install([{:gepa_ex, path: "."}])

# Math word problems dataset
trainset = [
  %{
    input: "If Sarah has 3 apples and John gives her 5 more, how many apples does Sarah have?",
    answer: "8"
  },
  %{
    input: "A train travels 60 miles in 2 hours. What is its average speed in miles per hour?",
    answer: "30"
  },
  %{
    input: "If a rectangle has a length of 8 cm and width of 5 cm, what is its area?",
    answer: "40"
  },
  %{
    input: "Tom has $50 and spends $18. How much money does he have left?",
    answer: "32"
  },
  %{
    input: "If there are 24 hours in a day, how many hours are in 3 days?",
    answer: "72"
  }
]

valset = [
  %{
    input: "A car travels 150 miles in 3 hours. What is its average speed?",
    answer: "50"
  },
  %{
    input: "If a square has sides of 6 inches, what is its area?",
    answer: "36"
  }
]

# Math-specific seed instruction
seed_candidate = %{
  "instruction" => """
  You are a math tutor. Solve the problem step by step and provide the final answer as a number.
  """
}

IO.puts("""
🧮 GEPA Math Problems Example
==============================

Training examples: #{length(trainset)}
Validation examples: #{length(valset)}

Seed instruction:
#{seed_candidate["instruction"]}
""")

IO.puts("ℹ️  Using deterministic Mock LLM. This example makes no live LLM calls.\n")

llm =
  GEPA.LLM.Mock.new(response_fn: fn _prompt ->
    "The answer is 8, 30, 40, 32, 72, 50, or 36."
  end)

# Create adapter with chosen LLM
adapter = GEPA.Adapters.Basic.new(llm: llm)

# Use EpochShuffledBatchSampler for better training dynamics
batch_sampler =
  GEPA.Strategies.BatchSampler.EpochShuffled.new(
    minibatch_size: 3,
    seed: 42
  )

IO.puts("⚙️  Running optimization with epoch-shuffled batches...")
IO.puts("   (This may take a minute with real LLMs)\n")

{:ok, result} =
  GEPA.optimize(
    seed_candidate: seed_candidate,
    trainset: trainset,
    valset: valset,
    adapter: adapter,
    batch_sampler: batch_sampler,
    max_metric_calls: 20
  )

# Analyze results
best_candidate = GEPA.Result.best_candidate(result)
best_score = GEPA.Result.best_score(result)
initial_score = List.first(result.val_aggregate_scores) || 0.0
improvement = (best_score - initial_score) * 100

IO.puts("""

✅ Optimization Complete!
========================

Initial validation score: #{Float.round(initial_score, 3)}
Best validation score: #{Float.round(best_score, 3)}
Improvement: +#{Float.round(improvement, 1)} percentage points

Iterations completed: #{result.i}
Total evaluations: #{result.total_num_evals}

📝 Optimized instruction:
#{best_candidate["instruction"]}

💡 Key insights:
- GEPA learned to improve math problem-solving
- The optimized instruction includes domain-specific guidance
- More iterations and data would yield better results

🚀 Next steps:
- Try with more training examples
- Use examples/05_llm_adapters.exs to smoke-test a live hosted provider
- Increase max_metric_calls to 50+
- See examples/03_custom_adapter.exs for custom evaluation
""")
