#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

defmodule ConfidenceAdapterExample do
  @moduledoc false

  @schema [
    category: [
      type: :string,
      required: true,
      doc: "One of billing, product, or shipping"
    ]
  ]

  @seed_prompt """
  Classify the support message into exactly one category:
  - billing: invoices, refunds, payments, credits, or charges
  - shipping: delivery, tracking, damaged packages, or missing packages
  - product: setup, usage, bugs, compatibility, or feature questions

  Return only the category in the JSON field category.
  """

  def schema, do: @schema
  def seed_prompt, do: @seed_prompt

  def dataset(true, :train, _trainset) do
    [
      %{
        input: "The invoice shows two charges for the same subscription renewal.",
        answer: "billing"
      },
      %{
        input: "The tracking page says delivered, but there is no package at my door.",
        answer: "shipping"
      },
      %{
        input: "How do I connect the dashboard to the new workspace API?",
        answer: "product"
      }
    ]
  end

  def dataset(true, :val, _valset) do
    [
      %{
        input: "I need a refund because my credit card was charged after cancellation.",
        answer: "billing"
      },
      %{
        input: "The box arrived crushed and the replacement unit is missing.",
        answer: "shipping"
      }
    ]
  end

  def dataset(false, :train, trainset), do: trainset
  def dataset(false, :val, valset), do: valset
end

example = [
  name: "GEPA Confidence Adapter Live Example",
  script: "examples/18_confidence_adapter.exs",
  summary: "Runs live structured-output classification through GEPA.Adapters.Confidence.",
  required: [:train_jsonl, :val_jsonl]
]

config = LiveCLI.parse_or_halt(System.argv(), example)

if config.adapter != :req_llm do
  IO.puts(:stderr, """
  Error:
    Confidence adapter live example requires --adapter req_llm because it uses
    structured output. Agent Session Manager structured output is intentionally
    unsupported until ASM exposes a native structured-output contract.
  """)

  System.halt(64)
end

estimated_calls = max(config.max_metric_calls * 2, 1)
IO.puts(LiveCLI.cost_warning(example[:name], config.adapter, config.provider, estimated_calls))

trainset =
  ConfidenceAdapterExample.dataset(
    config.simple?,
    :train,
    config.trainset
  )

valset =
  ConfidenceAdapterExample.dataset(
    config.simple?,
    :val,
    config.valset
  )

adapter =
  GEPA.Adapters.Confidence.new(
    model: config.client,
    field_path: "category",
    schema: ConfidenceAdapterExample.schema(),
    normalizer: fn value ->
      value
      |> to_string()
      |> String.downcase()
      |> String.trim()
    end,
    scoring_strategy:
      GEPA.Adapters.Confidence.Scoring.LinearBlend.new(
        low_confidence_threshold: 0.5,
        min_score_on_correct: 0.4
      )
  )

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{"system_prompt" => ConfidenceAdapterExample.seed_prompt()},
    trainset: trainset,
    valset: valset,
    adapter: adapter,
    reflection_llm: config.client,
    max_metric_calls: config.max_metric_calls,
    reflection_minibatch_size: config.minibatch_size,
    structured_output: config.structured_output?,
    track_best_outputs: true,
    cache_evaluation: :memory
  )

best_eval =
  result
  |> Map.get(:best_outputs_valset, %{})
  |> Map.values()
  |> List.flatten()
  |> List.first()

prediction =
  case best_eval do
    {_program_idx, %{prediction: value}} -> value
    {_program_idx, %{parsed_value: value}} -> value
    {_program_idx, %{"prediction" => value}} -> value
    {_program_idx, %{"parsed_value" => value}} -> value
    %{prediction: value} -> value
    %{parsed_value: value} -> value
    %{"prediction" => value} -> value
    %{"parsed_value" => value} -> value
    _other -> "n/a"
  end

IO.puts("""

Confidence Adapter Optimization Complete
========================================

Adapter/provider: #{config.adapter}/#{config.provider}
Structured output: ReqLLM schema-backed JSON object
Confidence source: provider logprobs when available; unavailable logprobs remain explicit nil
Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
Best prediction sample: #{prediction}
Best prompt:
#{GEPA.Result.best_candidate(result)["system_prompt"]}
""")
