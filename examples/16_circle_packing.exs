#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

defmodule CirclePackingExample do
  @moduledoc false

  @tolerance 1.0e-6

  @seed_code """
  pack = fn config, current_best_solution ->
    n = config.num_circles

    circle_radius = fn circle ->
      Map.get(circle, :r, Map.get(circle, "r", 0.0))
    end

    circles =
      if is_list(current_best_solution) and length(current_best_solution) == n do
        current_best_solution
      else
        centers =
          if n == 4 do
            [{0.25, 0.25}, {0.75, 0.25}, {0.25, 0.75}, {0.75, 0.75}]
          else
            center = [{0.5, 0.5}]

            inner =
              for i <- 0..7 do
                angle = 2.0 * :math.pi() * i / 8.0
                {0.5 + 0.25 * :math.cos(angle), 0.5 + 0.25 * :math.sin(angle)}
              end

            outer_count = max(n - 9, 0)

            outer =
              if outer_count > 0 do
                for i <- 0..(outer_count - 1) do
                  angle = 2.0 * :math.pi() * i / outer_count
                  {0.5 + 0.43 * :math.cos(angle), 0.5 + 0.43 * :math.sin(angle)}
                end
              else
                []
              end

            (center ++ inner ++ outer)
            |> Enum.take(n)
          end

        Enum.map(centers, fn {x, y} ->
          margin = min(min(x, y), min(1.0 - x, 1.0 - y))
          %{x: x, y: y, r: margin * 0.65}
        end)
      end

    %{
      circles: circles,
      all_scores: [Enum.reduce(circles, 0.0, fn circle, acc -> acc + circle_radius.(circle) end)]
    }
  end
  """

  def seed_code, do: @seed_code

  def problem(simple?) do
    num_circles = if simple?, do: 4, else: 26

    %{
      name: "unit-square circle packing",
      num_circles: num_circles,
      timeout_ms: 5_000,
      target_sum_radii: if(simple?, do: 1.0, else: 2.3)
    }
  end

  def evaluate(candidate, problem, opt_state) do
    result =
      GEPA.CodeExecution.execute_code(candidate,
        mode: :in_process,
        timeout: problem.timeout_ms,
        entry_point: :pack,
        entry_point_args: [
          Map.take(problem, [:num_circles, :timeout_ms]),
          best_circles(opt_state)
        ],
        seed: 0
      )

    returned = Map.get(result.variables, "__return__", result.result)

    {score, circles, all_scores, details, feedback} =
      evaluation_result(result, returned, problem)

    {score,
     %{
       Input:
         "Pack #{problem.num_circles} non-overlapping circles inside the [0,1] x [0,1] square.",
       Output: inspect(circles),
       Feedback: feedback,
       code: candidate,
       circles: circles,
       all_scores: all_scores,
       metrics: metrics(all_scores),
       stdout: result.stdout,
       error: result.error,
       traceback: result.traceback,
       validation_details: details,
       scores: %{"sum_radii" => score}
     }}
  end

  defp evaluation_result(%{success: false} = result, _returned, _problem) do
    details = %{sum_radii: 0.0, execution_error: result.error}

    {0.0, [], [0.0], details, "The candidate code did not execute successfully: #{result.error}"}
  end

  defp evaluation_result(_result, returned, problem) do
    case validate_return(returned, problem.num_circles) do
      {:ok, circles, all_scores, details} ->
        score = details.sum_radii
        {score, circles, all_scores, details, feedback_for(score, details, problem)}

      {:error, reason, circles, all_scores, details} ->
        {0.0, circles, all_scores, details, reason}
    end
  end

  defp validate_return(%{} = returned, num_circles) do
    with {:ok, raw_circles} <- fetch_key(returned, :circles),
         {:ok, raw_scores} <- fetch_key(returned, :all_scores),
         {:ok, circles} <- normalize_circles(raw_circles),
         {:ok, all_scores} <- normalize_scores(raw_scores) do
      validate_circles(circles, all_scores, num_circles)
    else
      {:error, reason} -> {:error, reason, [], [0.0], %{sum_radii: 0.0}}
    end
  end

  defp validate_return(other, _num_circles) do
    {:error, "pack must return a map, got #{inspect(other)}", [], [0.0], %{sum_radii: 0.0}}
  end

  defp validate_circles(circles, all_scores, num_circles) do
    details = packing_details(circles, num_circles)

    if valid_packing?(details) do
      {:ok, circles, all_scores, details}
    else
      {:error, validation_feedback(details), circles, all_scores, details}
    end
  end

  defp packing_details(circles, num_circles) do
    shape_errors =
      if length(circles) == num_circles do
        []
      else
        ["expected #{num_circles} circles, got #{length(circles)}"]
      end

    boundary_violations =
      circles
      |> Enum.with_index()
      |> Enum.flat_map(fn {circle, index} ->
        if circle.x - circle.r < -@tolerance or circle.x + circle.r > 1.0 + @tolerance or
             circle.y - circle.r < -@tolerance or circle.y + circle.r > 1.0 + @tolerance do
          ["circle #{index} is outside the unit square"]
        else
          []
        end
      end)

    negative_radii =
      circles
      |> Enum.with_index()
      |> Enum.flat_map(fn {circle, index} ->
        if circle.r < 0.0, do: ["circle #{index} has negative radius #{circle.r}"], else: []
      end)

    overlaps =
      for {left, i} <- Enum.with_index(circles),
          {right, j} <- Enum.with_index(circles),
          i < j,
          overlap?(left, right) do
        "circles #{i} and #{j} overlap"
      end

    radii = Enum.map(circles, & &1.r)
    sum_radii = Enum.sum(radii)

    %{
      expected_circles: num_circles,
      actual_circles: length(circles),
      boundary_violations: boundary_violations,
      overlaps: overlaps,
      negative_radii: negative_radii,
      shape_errors: shape_errors,
      min_radius: Enum.min(radii, fn -> 0.0 end),
      max_radius: Enum.max(radii, fn -> 0.0 end),
      avg_radius: if(radii == [], do: 0.0, else: sum_radii / length(radii)),
      sum_radii: sum_radii
    }
  end

  defp valid_packing?(details) do
    details.shape_errors == [] and details.boundary_violations == [] and
      details.overlaps == [] and details.negative_radii == []
  end

  defp overlap?(left, right) do
    dx = left.x - right.x
    dy = left.y - right.y
    distance = :math.sqrt(dx * dx + dy * dy)
    distance < left.r + right.r - @tolerance
  end

  defp validation_feedback(details) do
    messages =
      details.shape_errors ++
        details.negative_radii ++ details.boundary_violations ++ details.overlaps

    "Validation failed: " <> Enum.join(Enum.take(messages, 6), "; ")
  end

  defp feedback_for(score, details, problem) do
    cond do
      score >= problem.target_sum_radii - @tolerance ->
        "Valid high-scoring packing. Preserve the constraints and concise code shape."

      details.overlaps != [] ->
        "Circles overlap. Reduce radii or move centers farther apart before increasing total radius."

      details.boundary_violations != [] ->
        "Some circles leave the unit square. Keep x-r, x+r, y-r, and y+r inside [0,1]."

      true ->
        "Valid packing with sum_radii #{Float.round(score, 4)}. Increase radii while preserving all unit-square and non-overlap constraints."
    end
  end

  defp best_circles(nil), do: nil

  defp best_circles(%{best_example_evals: evals}) when is_list(evals) do
    Enum.find_value(evals, fn eval ->
      side_info = Map.get(eval, :side_info, Map.get(eval, "side_info", %{}))
      raw_circles = Map.get(side_info, :circles, Map.get(side_info, "circles"))

      case normalize_circles(raw_circles) do
        {:ok, circles} -> circles
        {:error, _reason} -> nil
      end
    end)
  end

  defp best_circles(_opt_state), do: nil

  defp fetch_key(map, key) do
    string_key = to_string(key)

    case {Map.fetch(map, key), Map.fetch(map, string_key)} do
      {{:ok, value}, _} -> {:ok, value}
      {_, {:ok, value}} -> {:ok, value}
      _ -> {:error, "pack return map must contain #{inspect(string_key)}"}
    end
  end

  defp normalize_circles(nil), do: {:error, "pack must return circles"}

  defp normalize_circles(circles) when is_list(circles) do
    circles
    |> Enum.map(&normalize_circle/1)
    |> collect_results()
  end

  defp normalize_circles(_circles), do: {:error, "circles must be a list"}

  defp normalize_circle(%{} = circle) do
    with {:ok, x} <- number_field(circle, :x),
         {:ok, y} <- number_field(circle, :y),
         {:ok, r} <- number_field(circle, :r) do
      {:ok, %{x: x, y: y, r: r}}
    end
  end

  defp normalize_circle({x, y, r}), do: normalize_circle([x, y, r])

  defp normalize_circle([x, y, r]) do
    with {:ok, x} <- finite_number(x, "x"),
         {:ok, y} <- finite_number(y, "y"),
         {:ok, r} <- finite_number(r, "r") do
      {:ok, %{x: x, y: y, r: r}}
    end
  end

  defp normalize_circle(other), do: {:error, "invalid circle #{inspect(other)}"}

  defp number_field(map, key) do
    string_key = to_string(key)

    map
    |> Map.get(key, Map.get(map, string_key))
    |> finite_number(string_key)
  end

  defp finite_number(value, _field) when is_integer(value), do: {:ok, value * 1.0}

  defp finite_number(value, _field)
       when is_float(value) and value == value and value > -1.0e300 and value < 1.0e300 do
    {:ok, value}
  end

  defp finite_number(_value, field), do: {:error, "#{field} must be a finite number"}

  defp normalize_scores(scores) when is_list(scores) do
    scores
    |> Enum.map(&finite_number(&1, "score"))
    |> collect_results()
    |> case do
      {:ok, []} -> {:ok, [0.0]}
      other -> other
    end
  end

  defp normalize_scores(_scores), do: {:ok, [0.0]}

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, values} -> {:cont, {:ok, [value | values]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp metrics([]), do: metrics([0.0])

  defp metrics(all_scores) do
    alpha_fixed = 0.1

    ema_fixed =
      Enum.reduce(tl(all_scores), hd(all_scores), fn score, acc ->
        alpha_fixed * score + (1.0 - alpha_fixed) * acc
      end)

    alpha_adaptive = 2.0 / (length(all_scores) + 1)

    ema_adaptive =
      Enum.reduce(tl(all_scores), hd(all_scores), fn score, acc ->
        alpha_adaptive * score + (1.0 - alpha_adaptive) * acc
      end)

    %{
      max_score: Enum.max(all_scores),
      mean_score: Enum.sum(all_scores) / length(all_scores),
      ema_score_fixed: ema_fixed,
      ema_score_adaptive: ema_adaptive
    }
  end
end

example = [
  name: "Circle Packing Live Example",
  script: "examples/16_circle_packing.exs",
  summary: "Optimizes executable Elixir geometry code for unit-square circle packing.",
  required: []
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

problem = CirclePackingExample.problem(config.simple?)

{:ok, result} =
  GEPA.OptimizeAnything.optimize_anything(
    seed_candidate: CirclePackingExample.seed_code(),
    dataset: [problem],
    valset: [problem],
    evaluator: &CirclePackingExample.evaluate/3,
    objective:
      "Improve executable Elixir code that packs non-overlapping circles inside a unit square while maximizing the sum of radii.",
    background: """
    Candidate code must bind a pack function:

        pack = fn config, current_best_solution -> ... end

    The function receives %{num_circles: n, timeout_ms: ms} and the best valid
    prior circle list for the same problem, or nil. It must return
    %{circles: circles, all_scores: scores}. Each circle may be %{x: x, y: y, r: r}
    or [x, y, r]. All circles must stay inside [0,1] x [0,1], must not overlap,
    and should finish quickly. Higher sum_radii is better.

    Simple mode uses four circles for a short live smoke. Full mode uses
    twenty-six circles, matching the upstream problem size.
    """,
    engine: %{
      max_metric_calls: config.max_metric_calls,
      reflection_minibatch_size: config.minibatch_size,
      cache_evaluation: :memory,
      frontier_type: :objective
    },
    reflection: %{
      reflection_lm: config.client,
      structured_output: config.structured_output?,
      skip_perfect_score: false
    }
  )

IO.puts("""

Circle Packing Optimization Complete
====================================

Problem size: #{problem.num_circles} circles
Best sum_radii: #{Float.round(GEPA.Result.best_score(result), 4)}
Best code:
#{GEPA.Result.best_candidate(result)}
""")
