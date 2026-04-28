#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

defmodule ADRCloudOptimizationExample do
  @moduledoc false

  def trainset do
    [
      %{
        family: :can_be_late,
        name: "tight deadline with unreliable spot capacity",
        risk: :tight,
        feedback:
          "Use on-demand capacity when deadline slack is low or spot capacity is unreliable."
      },
      %{
        family: :cloudcast,
        name: "cross-provider broadcast with constrained bandwidth",
        risk: :bandwidth,
        feedback:
          "Balance egress cost with throughput and split partitions only when bandwidth needs it."
      }
    ]
  end

  def valset do
    [
      %{
        family: :can_be_late,
        name: "safe deadline with cheap spot availability",
        risk: :slack,
        feedback:
          "Prefer spot while there is enough deadline slack, then fall back before the job is late."
      },
      %{
        family: :cloudcast,
        name: "multi-region cloudcast route selection",
        risk: :egress,
        feedback:
          "Choose routes that account for provider egress, region hops, and transfer throughput."
      }
    ]
  end

  def evaluate(candidate, scenario) do
    policy = candidate_policy(candidate)
    normalized = String.downcase(policy)

    {score, matched} =
      case scenario.family do
        :can_be_late -> score_can_be_late(normalized, scenario.risk)
        :cloudcast -> score_cloudcast(normalized)
      end

    {score,
     %{
       Input: scenario.name,
       Output: policy,
       Feedback: scenario.feedback,
       matched_requirements: matched,
       scores: %{Atom.to_string(scenario.family) => score},
       prompt_specific_info: %{
         Feedback:
           "The policy is graded for explicit cloud strategy tradeoffs, not for provider prose."
       }
     }}
  end

  defp candidate_policy(candidate) when is_map(candidate) do
    Map.get(candidate, :policy) || Map.get(candidate, "policy") || inspect(candidate)
  end

  defp candidate_policy(candidate), do: to_string(candidate)

  defp score_can_be_late(policy, risk) do
    checks = [
      {:deadline, contains_any?(policy, ["deadline", "late", "sla"])},
      {:spot, contains_any?(policy, ["spot", "preempt", "interrupt"])},
      {:on_demand, contains_any?(policy, ["on-demand", "on demand", "guaranteed"])},
      {:restart, contains_any?(policy, ["restart", "overhead", "switch"])},
      {:fallback, contains_any?(policy, ["fallback", "fall back", "escalate"])}
    ]

    risk_checks =
      case risk do
        :tight ->
          [{:tight_deadline_bias, contains_any?(policy, ["on-demand", "on demand", "guaranteed"])}]

        :slack ->
          [{:slack_spot_bias, contains_any?(policy, ["spot", "wait", "cheap"])}]
      end

    score_checks(checks ++ risk_checks)
  end

  defp score_cloudcast(policy) do
    [
      {:egress_cost, contains_any?(policy, ["egress", "cost", "price"])},
      {:throughput, contains_any?(policy, ["throughput", "bandwidth", "transfer time"])},
      {:partitions, contains_any?(policy, ["partition", "split", "shard"])},
      {:provider_regions, contains_any?(policy, ["provider", "region", "cloud"])},
      {:routing, contains_any?(policy, ["route", "path", "fallback"])}
    ]
    |> score_checks()
  end

  defp score_checks(checks) do
    matched =
      checks
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    score = Float.round(length(matched) / length(checks), 4)

    {score, matched}
  end

  defp contains_any?(text, terms) do
    Enum.any?(terms, &String.contains?(text, &1))
  end
end

example = [
  name: "ADR Cloud Optimization Live Example",
  script: "examples/13_adrs_cloud_optimization.exs",
  summary:
    "Optimizes a cloud architecture-decision policy for scheduling and broadcast routing.",
  required: []
]

config = LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 3, 1)

IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

{:ok, result} =
  GEPA.OptimizeAnything.optimize_anything(
    seed_candidate: %{
      policy:
        "Choose the cheapest cloud option first, then use a more reliable resource when risk rises."
    },
    dataset: ADRCloudOptimizationExample.trainset(),
    valset: ADRCloudOptimizationExample.valset(),
    evaluator: &ADRCloudOptimizationExample.evaluate/2,
    objective:
      "Improve a cloud architecture-decision policy for deadline-aware scheduling and cost-aware broadcast routing.",
    background: """
    This headless ADR example ports the core mechanism from upstream's Can't Be Late
    and Cloudcast examples. The evaluator scores the policy for explicit cloud
    tradeoffs: spot versus on-demand scheduling, deadline fallback behavior,
    provider egress cost, throughput, partitions, and route selection.
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

best = GEPA.Result.best_candidate(result)
best_policy = Map.get(best, :policy) || Map.get(best, "policy") || inspect(best)

IO.puts("""

ADR Cloud Optimization Complete
===============================

Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Best policy:
#{best_policy}
""")
