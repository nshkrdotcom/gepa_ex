#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "Optimize Anything Dataset Live Example",
  script: "examples/09_optimize_anything_dataset.exs",
  summary: "Optimizes a prompt map over live question/answer examples.",
  required: [:train_jsonl, :val_jsonl]
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 3, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

evaluator = fn candidate, row ->
  {:ok, output} =
    GEPA.LLM.complete(
      config.client,
      """
      #{candidate.prompt}

      Question:
      #{row.input}
      """,
      LiveCLI.generation_opts(config)
    )

  expected = String.downcase(row.answer || row.expected || "")
  normalized_output = String.downcase(output)
  score = if expected != "" and String.contains?(normalized_output, expected), do: 1.0, else: 0.0

  {score,
   %{
     Input: row.input,
     Output: output,
     Expected: row.answer || row.expected,
     Feedback: "Include the expected answer text while keeping the answer concise.",
     scores: %{"contains_expected" => score},
     prompt_specific_info: %{Feedback: "The prompt controlled answer format and coverage."}
   }}
end

{:ok, result} =
  GEPA.OptimizeAnything.optimize_anything(
    seed_candidate: %{prompt: "Answer the question with the shortest correct answer."},
    dataset: config.trainset,
    valset: config.valset,
    evaluator: evaluator,
    objective: "Improve a QA prompt so answers contain the expected answer text.",
    engine: %{
      max_metric_calls: config.max_metric_calls,
      reflection_minibatch_size: config.minibatch_size,
      cache_evaluation: :memory
    },
    reflection: %{
      reflection_lm: config.client,
      structured_output: config.structured_output?,
      skip_perfect_score: false
    }
  )

IO.puts("""

Optimize Anything Dataset Complete
==================================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Best prompt:
#{GEPA.Result.best_candidate(result).prompt}
""")
