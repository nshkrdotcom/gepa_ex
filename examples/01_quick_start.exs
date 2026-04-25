#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "GEPA Quick Start Live Example",
  script: "examples/01_quick_start.exs",
  summary: "Runs a small live GEPA optimization over your JSONL question/answer data.",
  required: [:train_jsonl, :val_jsonl]
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(
  LiveCLI.cost_warning(
    example[:name],
    config.adapter,
    config.provider,
    estimated_calls
  )
)

seed_candidate = %{
  "instruction" => "Answer the user's question accurately and concisely."
}

adapter = GEPA.Adapters.Basic.new(llm: config.client)

IO.puts("""
GEPA Quick Start Live Example
=============================

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

IO.puts("""

Optimization Complete
=====================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Iterations: #{result.i}
Total evaluations: #{result.total_num_evals}

Best instruction:
#{GEPA.Result.best_candidate(result)["instruction"]}
""")
