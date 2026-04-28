#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "ARC Grid Live Example",
  script: "examples/14_arc_grid.exs",
  summary: "Optimizes a headless ARC grid-solving instruction over live fixture tasks.",
  required: [:train_jsonl, :val_jsonl]
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

seed_candidate = %{
  "instruction" =>
    "Infer the ARC grid transformation from the examples. Return only the final output grid as compact JSON."
}

adapter = GEPA.Adapters.Basic.new(llm: config.client)

IO.puts("""
ARC Grid Live Example
=====================

Adapter/provider: #{config.adapter}/#{config.provider}
Model: #{config.model || "(provider default)"}
Training rows: #{length(config.trainset)}
Validation rows: #{length(config.valset)}
Max metric calls: #{config.max_metric_calls}
Reflection minibatch size: #{config.minibatch_size}
""")

{:ok, result} =
  GEPA.optimize(
    seed_candidate: seed_candidate,
    trainset: config.trainset,
    valset: config.valset,
    adapter: adapter,
    max_metric_calls: config.max_metric_calls,
    reflection_llm: config.client,
    reflection_minibatch_size: config.minibatch_size,
    structured_output: config.structured_output?
  )

best_score = GEPA.Result.best_score(result)
initial_score = List.first(result.val_aggregate_scores) || 0.0
improvement = (best_score - initial_score) * 100

IO.puts("""

ARC Grid Optimization Complete
==============================

Initial validation score: #{Float.round(initial_score, 4)}
Best validation score: #{Float.round(best_score, 4)}
Improvement: #{Float.round(improvement, 2)} percentage points
Iterations: #{result.i}
Total evaluations: #{result.total_num_evals}

Best instruction:
#{GEPA.Result.best_candidate(result)["instruction"]}
""")
