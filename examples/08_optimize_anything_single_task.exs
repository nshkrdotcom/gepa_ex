#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "Optimize Anything Single Task Live Example",
  script: "examples/08_optimize_anything_single_task.exs",
  summary: "Optimizes one prompt string with a live LLM-backed evaluator.",
  required: [:input, :expected]
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 3, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

evaluator = fn prompt ->
  {:ok, output} =
    GEPA.LLM.complete(
      config.client,
      """
      #{prompt}

      User input:
      #{config.input}
      """,
      LiveCLI.generation_opts(config)
    )

  expected = String.downcase(config.expected)
  normalized_output = String.downcase(output)
  score = if String.contains?(normalized_output, expected), do: 1.0, else: 0.0

  GEPA.OptimizeAnything.log("expected=#{config.expected}")

  {score,
   %{
     Input: config.input,
     Output: output,
     Expected: config.expected,
     Feedback: "Score is 1.0 only when the response contains the expected text.",
     scores: %{"contains_expected" => score}
   }}
end

{:ok, result} =
  GEPA.OptimizeAnything.optimize_anything(
    seed_candidate: "Reply exactly with the requested target text.",
    evaluator: evaluator,
    objective: "Improve the prompt so the live model includes the expected text.",
    background: "Responses are graded by exact expected-text containment.",
    engine: %{
      max_metric_calls: config.max_metric_calls,
      reflection_minibatch_size: 1,
      cache_evaluation: :memory
    },
    reflection: %{
      reflection_lm: config.client,
      structured_output: config.structured_output?,
      skip_perfect_score: false
    }
  )

IO.puts("""

Optimize Anything Single Task Complete
======================================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Best candidate:
#{GEPA.Result.best_candidate(result)}
""")
