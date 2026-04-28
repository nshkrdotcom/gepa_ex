#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

defmodule BlackboxSearchExample do
  @moduledoc false

  @seed_code """
  solve = fn objective_function, config, best_xs ->
    candidates =
      [-4.0, -1.0, 0.0, 1.0, 3.5]
      |> Enum.take(config.budget)

    attempts =
      Enum.map(candidates, fn x ->
        %{x: x, score: objective_function.(x)}
      end)

    best = Enum.min_by(attempts, & &1.score)

    %{
      x: best.x,
      score: best.score,
      all_attempts: attempts,
      used_prior_trials: length(best_xs)
    }
  end
  """

  def seed_code, do: @seed_code

  def problem do
    %{
      name: "one-dimensional shifted sphere",
      bounds: [-5.0, 5.0],
      budget: 5,
      optimum: 2.0
    }
  end

  def evaluate(candidate, problem, opt_state) do
    counter = :counters.new(1, [])
    budget = problem.budget

    objective_function = fn value ->
      :counters.add(counter, 1, 1)
      calls = :counters.get(counter, 1)
      x = scalar(value)

      if calls > budget do
        1.0e6
      else
        :math.pow(x - problem.optimum, 2)
      end
    end

    result =
      GEPA.CodeExecution.execute_code(candidate,
        mode: :in_process,
        timeout: 5_000,
        entry_point: :solve,
        entry_point_args: [
          objective_function,
          %{bounds: problem.bounds, budget: problem.budget},
          best_xs(opt_state)
        ],
        seed: 0
      )

    calls = :counters.get(counter, 1)
    returned = Map.get(result.variables, "__return__", result.result)

    {score, feedback} =
      if result.success do
        objective_score = returned_score(returned)
        {1.0 / (1.0 + max(objective_score, 0.0)), feedback_for(objective_score, calls, budget)}
      else
        {-1.0, "The candidate code did not execute successfully: #{result.error}"}
      end

    {score,
     %{
       Input: problem.name,
       Output: inspect(returned),
       Feedback: feedback,
       stdout: result.stdout,
       error: result.error,
       traceback: result.traceback,
       calls_used: calls,
       budget: budget,
       all_trials: returned_attempts(returned),
       scores: %{"blackbox_score" => score}
     }}
  end

  defp scalar(value) when is_number(value), do: value * 1.0
  defp scalar([value | _rest]) when is_number(value), do: value * 1.0
  defp scalar(_value), do: 1.0e6

  defp returned_score(%{} = returned) do
    case Map.get(returned, :score, Map.get(returned, "score", 1.0e6)) do
      value when is_number(value) -> value * 1.0
      _other -> 1.0e6
    end
  end

  defp returned_score(_returned), do: 1.0e6

  defp returned_attempts(%{} = returned) do
    Map.get(returned, :all_attempts, Map.get(returned, "all_attempts", []))
  end

  defp returned_attempts(_returned), do: []

  defp best_xs(nil), do: []

  defp best_xs(%{best_example_evals: evals}) when is_list(evals) do
    evals
    |> Enum.flat_map(fn eval ->
      eval
      |> Map.get("side_info", Map.get(eval, :side_info, %{}))
      |> Map.get(:all_trials, [])
    end)
    |> Enum.sort_by(&Map.get(&1, :score, 1.0e6))
    |> Enum.take(10)
  end

  defp best_xs(_opt_state), do: []

  defp feedback_for(objective_score, calls, budget) do
    cond do
      calls > budget ->
        "The solver exceeded the objective-call budget. Stay within #{budget} calls."

      objective_score <= 0.001 ->
        "The solver found the optimum. Preserve the concise search and budget accounting."

      true ->
        "Lower objective values are better. Try sampling near x=2.0 and use best_xs from prior trials."
    end
  end
end

example = [
  name: "Blackbox Search Live Example",
  script: "examples/15_blackbox_search.exs",
  summary: "Optimizes executable Elixir search code for a small blackbox objective.",
  required: []
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

problem = BlackboxSearchExample.problem()

{:ok, result} =
  GEPA.OptimizeAnything.optimize_anything(
    seed_candidate: BlackboxSearchExample.seed_code(),
    dataset: [problem],
    valset: [problem],
    evaluator: &BlackboxSearchExample.evaluate/3,
    objective:
      "Improve executable Elixir code that minimizes a blackbox objective within a fixed call budget.",
    background: """
    Candidate code must bind a solve function:

        solve = fn objective_function, config, best_xs -> ... end

    The function receives bounds, an objective-call budget, and prior best trials.
    It must return %{x: best_x, score: best_objective_score, all_attempts: attempts}.
    Lower objective values are better; GEPA receives the transformed score.
    """,
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

Blackbox Search Optimization Complete
=====================================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Best code:
#{GEPA.Result.best_candidate(result)}
""")
