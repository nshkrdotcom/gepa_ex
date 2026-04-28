#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

example = [
  name: "Optimize Anything Code Execution Live Example",
  script: "examples/10_code_execution.exs",
  summary: "Optimizes a small Elixir snippet and evaluates it through GEPA.CodeExecution.",
  required: []
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

evaluator = fn code ->
  result = GEPA.CodeExecution.execute_code(code, mode: :subprocess, timeout: 5_000)

  score =
    if result.success and String.contains?(result.stdout, "gepa-code-ok") do
      1.0
    else
      0.0
    end

  {score,
   %{
     Output: inspect(result.result),
     stdout: result.stdout,
     Error: result.error,
     Feedback: "The snippet must print gepa-code-ok and finish successfully.",
     scores: %{"prints_marker" => score}
   }}
end

{:ok, result} =
  GEPA.OptimizeAnything.optimize_anything(
    seed_candidate: "IO.puts(\"gepa-code-ok\")\n:ok",
    evaluator: evaluator,
    objective:
      "Produce a small Elixir snippet that prints gepa-code-ok and returns successfully.",
    background: "The evaluator executes the snippet in a subprocess with a short timeout.",
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

Code Execution Optimization Complete
====================================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Best code:
#{GEPA.Result.best_candidate(result)}
""")
