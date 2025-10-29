#!/usr/bin/env elixir

# GEPA State Persistence Example
# ===============================
#
# This example demonstrates how to:
# - Save optimization state to disk
# - Resume interrupted optimizations
# - Inspect saved results
# - Gracefully stop long-running optimizations
#
# ## To run:
#   mix run examples/04_state_persistence.exs
#
# ## To resume an optimization:
#   # The script will automatically resume if state exists
#   mix run examples/04_state_persistence.exs

# Mix.install([{:gepa_ex, path: "."}])

# Configuration
run_dir = "./tmp/gepa_example_run"
max_iterations_per_run = 5
total_desired_iterations = 15

# Training data
trainset = [
  %{input: "What is the capital of France?", answer: "Paris"},
  %{input: "What is 10 * 12?", answer: "120"},
  %{input: "Who wrote Hamlet?", answer: "Shakespeare"},
  %{input: "What is the largest ocean?", answer: "Pacific"},
  %{input: "What year did World War II end?", answer: "1945"}
]

valset = [
  %{input: "What is the capital of Japan?", answer: "Tokyo"},
  %{input: "What is 7 * 8?", answer: "56"}
]

seed_candidate = %{
  "instruction" => "Answer the question accurately and concisely."
}

IO.puts("""
💾 GEPA State Persistence Example
=================================

Run directory: #{run_dir}
Max iterations per run: #{max_iterations_per_run}
Total desired: #{total_desired_iterations}
""")

# Check if previous state exists
state_file = Path.join(run_dir, "state.etf")
previous_state_exists = File.exists?(state_file)

if previous_state_exists do
  # Load previous state to check progress
  previous_state = File.read!(state_file) |> :erlang.binary_to_term()

  IO.puts("""

  ♻️  Found previous optimization state!
  Previous iterations: #{previous_state.i}
  Previous best score: #{Float.round(GEPA.Result.best_score(previous_state), 3)}

  Resuming optimization...
  """)
else
  IO.puts("\n🆕 Starting new optimization...\n")
end

# Create adapter
adapter = GEPA.Adapters.Basic.new(llm: GEPA.LLM.Mock.new())

# Run optimization with state persistence
{:ok, result} =
  GEPA.optimize(
    seed_candidate: seed_candidate,
    trainset: trainset,
    valset: valset,
    adapter: adapter,
    # 🔑 This enables state persistence!
    run_dir: run_dir,
    max_metric_calls: max_iterations_per_run
  )

IO.puts("""

✅ Optimization Run Complete!
=============================

Current iteration: #{result.i}
Best score: #{Float.round(GEPA.Result.best_score(result), 3)}
Total evaluations: #{result.total_num_evals}

State saved to: #{run_dir}/
""")

# Check if we should continue
if result.i < total_desired_iterations do
  IO.puts("""

  ⏸️  Paused at iteration #{result.i}/#{total_desired_iterations}

  To continue optimization, run this script again:
    mix run examples/04_state_persistence.exs

  The optimization will automatically resume from iteration #{result.i + 1}.

  📁 Saved files:
  - #{run_dir}/state.etf (optimization state)
  - #{run_dir}/result.etf (results so far)

  💡 To stop optimization gracefully, create a file:
    touch #{run_dir}/gepa.stop
  """)
else
  IO.puts("""

  🎉 Optimization Complete!
  =========================

  Reached #{result.i} iterations (target: #{total_desired_iterations})

  Best candidate:
  #{GEPA.Result.best_candidate(result)["instruction"]}

  📊 Final statistics:
  - Total iterations: #{result.i}
  - Total evaluations: #{result.total_num_evals}
  - Best validation score: #{Float.round(GEPA.Result.best_score(result), 3)}
  - Candidates evaluated: #{length(result.program_candidates)}
  - Pareto front size: #{length(result.program_at_pareto_front_valset)}
  """)
end

IO.puts("""

📚 What you learned:
- Use `run_dir` option to enable state persistence
- Optimization automatically resumes from saved state
- State is saved after each iteration
- Graceful stopping with `gepa.stop` file
- Inspect saved state at any time

🔧 Advanced usage:
- Set different max_metric_calls for each run
- Inspect intermediate results between runs
- Copy state to continue with different parameters
- Archive successful optimization runs

🧹 Cleanup:
  rm -rf #{run_dir}
""")
