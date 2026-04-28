#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "GEPA Tracking Live Example",
  script: "examples/12_tracking.exs",
  summary: "Runs GEPA with the in-memory experiment tracker enabled.",
  required: [:train_jsonl, :val_jsonl]
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

tracker = GEPA.Tracking.InMemory.new(key_prefix: "example/")
adapter = GEPA.Adapters.Basic.new(llm: config.client)

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{"instruction" => "Answer accurately and briefly."},
    trainset: config.trainset,
    valset: config.valset,
    adapter: adapter,
    reflection_llm: config.client,
    max_metric_calls: config.max_metric_calls,
    reflection_minibatch_size: config.minibatch_size,
    tracker: tracker,
    structured_output: config.structured_output?
  )

snapshot = GEPA.Tracking.InMemory.snapshot(tracker)
summary = List.last(snapshot.summaries) || %{}

IO.puts("""

Tracking Complete
=================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Metric rows: #{length(snapshot.metrics)}
Summary keys: #{Map.keys(summary) |> Enum.sort() |> Enum.join(", ")}
""")
