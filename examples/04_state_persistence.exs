#!/usr/bin/env elixir

example = [
  name: "GEPA State Persistence Live Example",
  script: "examples/04_state_persistence.exs",
  summary: "Runs or resumes a live GEPA optimization with checkpoint persistence.",
  required: [:train_jsonl, :val_jsonl, :run_dir]
]

config = GEPA.Examples.LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(
  GEPA.Examples.LiveCLI.cost_warning(
    example[:name],
    config.adapter,
    config.provider,
    estimated_calls
  )
)

seed_candidate = %{
  "instruction" => "Answer the user's question accurately and cite the key fact in the answer."
}

state_file = Path.join(config.run_dir, "gepa_state.etf")

if File.exists?(state_file) do
  previous_state = File.read!(state_file) |> :erlang.binary_to_term()
  previous_result = GEPA.Result.from_state(previous_state)

  IO.puts("""
  Existing checkpoint found.
  Previous iterations: #{previous_state.i}
  Previous best score: #{Float.round(GEPA.Result.best_score(previous_result), 4)}
  """)
else
  IO.puts("No existing checkpoint found. Starting a new live optimization.")
end

adapter = GEPA.Adapters.Basic.new(llm: config.client)

IO.puts("""
GEPA State Persistence Live Example
===================================

Adapter/provider: #{config.adapter}/#{config.provider}
Model: #{config.model || "(provider default)"}
Run directory: #{config.run_dir}
Training rows: #{length(config.trainset)}
Validation rows: #{length(config.valset)}
Max metric calls this run: #{config.max_metric_calls}
Reflection minibatch size: #{config.minibatch_size}
""")

{:ok, result} =
  GEPA.optimize(
    seed_candidate: seed_candidate,
    trainset: config.trainset,
    valset: config.valset,
    adapter: adapter,
    run_dir: config.run_dir,
    max_metric_calls: config.max_metric_calls,
    reflection_llm: config.client,
    reflection_minibatch_size: config.minibatch_size,
    structured_output: config.structured_output?
  )

IO.puts("""

Optimization Run Complete
=========================

Current iteration: #{result.i}
Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Total evaluations: #{result.total_num_evals}
State saved to: #{config.run_dir}

Saved files:
- #{Path.join(config.run_dir, "gepa_state.etf")}
- #{Path.join(config.run_dir, "candidates.json")}
""")
