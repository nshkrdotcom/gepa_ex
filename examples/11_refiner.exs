#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "Optimize Anything Refiner Live Example",
  script: "examples/11_refiner.exs",
  summary: "Runs optimize_anything with the per-evaluation refiner enabled.",
  required: [:input, :expected]
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 4, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

evaluator = fn candidate ->
  {:ok, output} =
    GEPA.LLM.complete(
      config.client,
      """
      #{candidate}

      Input:
      #{config.input}
      """,
      LiveCLI.generation_opts(config)
    )

  expected = String.downcase(config.expected)
  score = if String.contains?(String.downcase(output), expected), do: 1.0, else: 0.0

  {score,
   %{
     Input: config.input,
     Output: output,
     Expected: config.expected,
     Feedback: "Refine the candidate toward exact expected text coverage.",
     scores: %{"contains_expected" => score}
   }}
end

{:ok, result} =
  GEPA.OptimizeAnything.optimize_anything(
    seed_candidate: "Follow the instruction and answer clearly.",
    evaluator: evaluator,
    objective: "Improve the candidate and its refiner prompt for exact expected text coverage.",
    engine: %{
      max_metric_calls: config.max_metric_calls,
      reflection_minibatch_size: 1,
      cache_evaluation: :memory
    },
    reflection: %{
      reflection_lm: config.client,
      structured_output: config.structured_output?,
      skip_perfect_score: false
    },
    refiner: %{
      enabled: true,
      refiner_lm: config.client,
      max_attempts: 1
    }
  )

IO.puts("""

Refiner Optimization Complete
=============================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Best candidate:
#{GEPA.Result.best_candidate(result)}
""")
