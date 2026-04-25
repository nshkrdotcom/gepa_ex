#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "GEPA Stop Conditions Live Example",
  script: "examples/06_stop_conditions.exs",
  summary: "Runs GEPA with multiple real stop conditions over question/answer JSONL data.",
  required: [:train_jsonl, :val_jsonl]
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

adapter = GEPA.Adapters.Basic.new(llm: config.client)

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{"instruction" => "Answer directly and check the expected answer."},
    trainset: config.trainset,
    valset: config.valset,
    adapter: adapter,
    reflection_llm: config.client,
    max_metric_calls: config.max_metric_calls,
    max_candidate_proposals: 1,
    score_threshold: 1.0,
    timeout_seconds: 120,
    reflection_minibatch_size: config.minibatch_size,
    structured_output: config.structured_output?
  )

IO.puts("""

Stop Conditions Complete
========================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Iterations: #{result.i}
Total evaluations: #{result.total_num_evals}
Candidates tracked: #{length(result.candidates)}
""")
