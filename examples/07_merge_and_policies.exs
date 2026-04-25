#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "GEPA Merge and Policies Live Example",
  script: "examples/07_merge_and_policies.exs",
  summary: "Runs GEPA with merge enabled and explicit strategy policy settings.",
  required: [:train_jsonl, :val_jsonl]
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 3, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

adapter = GEPA.Adapters.Basic.new(llm: config.client)

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{
      "instruction" =>
        "Answer the question accurately, using the expected answer as the grading target."
    },
    trainset: config.trainset,
    valset: config.valset,
    adapter: adapter,
    reflection_llm: config.client,
    max_metric_calls: config.max_metric_calls,
    reflection_minibatch_size: config.minibatch_size,
    candidate_selection_strategy: :top_k_pareto,
    module_selector: :all,
    val_evaluation_policy: :full_eval,
    acceptance_criterion: :improvement_or_equal,
    use_merge: true,
    max_merge_invocations: 2,
    merge_val_overlap_floor: 1,
    structured_output: config.structured_output?
  )

IO.puts("""

Merge and Policies Complete
===========================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Iterations: #{result.i}
Total evaluations: #{result.total_num_evals}
Candidates tracked: #{length(result.candidates)}
""")
