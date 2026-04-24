#!/usr/bin/env elixir

defmodule CustomSentimentAdapter do
  @behaviour GEPA.Adapter

  defstruct [:llm]

  def new(opts), do: %__MODULE__{llm: Keyword.fetch!(opts, :llm)}

  @impl true
  def evaluate(%__MODULE__{} = adapter, batch, candidate, capture_traces) do
    results =
      Enum.map(batch, fn example ->
        prompt = build_prompt(candidate["instruction"], example.text)
        {:ok, response} = GEPA.LLM.complete(adapter.llm, prompt)
        predicted = extract_sentiment(response)
        correct? = predicted == example.sentiment

        %{
          output: %{predicted: predicted, response: response},
          score: if(correct?, do: 1.0, else: 0.0),
          trace: %{
            prompt: prompt,
            response: response,
            expected: example.sentiment,
            component: "instruction"
          }
        }
      end)

    {:ok,
     %GEPA.EvaluationBatch{
       outputs: Enum.map(results, & &1.output),
       scores: Enum.map(results, & &1.score),
       trajectories: if(capture_traces, do: Enum.map(results, & &1.trace))
     }}
  end

  @impl true
  def make_reflective_dataset(_adapter, _candidate, eval_batch, components_to_update) do
    dataset =
      for component <- components_to_update, into: %{} do
        items =
          eval_batch.trajectories
          |> Enum.zip(eval_batch.scores)
          |> Enum.map(fn {trace, score} ->
            status = if score > 0.5, do: "Correct", else: "Wrong"

            %{
              "Inputs" => %{"prompt" => trace.prompt},
              "Generated Outputs" => trace.response,
              "Feedback" =>
                "#{status}. Expected #{trace.expected}, got #{extract_sentiment(trace.response)} using #{component}."
            }
          end)

        {component, items}
      end

    {:ok, dataset}
  end

  defp build_prompt(instruction, text) do
    """
    #{instruction}

    Text:
    #{text}

    Classify the sentiment as exactly one of: positive, negative, neutral.
    """
  end

  defp extract_sentiment(response) do
    response = String.downcase(response)

    cond do
      String.contains?(response, "positive") -> "positive"
      String.contains?(response, "negative") -> "negative"
      true -> "neutral"
    end
  end
end

example = [
  name: "GEPA Custom Sentiment Adapter Live Example",
  script: "examples/03_custom_adapter.exs",
  summary: "Runs a custom live sentiment adapter over your JSONL text/sentiment data.",
  required: [:train_jsonl, :val_jsonl]
]

config = GEPA.Examples.LiveCLI.parse_or_halt(System.argv(), example)
estimated_calls = max(config.max_metric_calls * 2, 1)

IO.puts(
  GEPA.Examples.LiveCLI.cost_warning(
    example[:name],
    config.adapter,
    config.provider,
    estimated_calls
  )
)

seed_candidate = %{
  "instruction" => "Classify the sentiment of the provided text."
}

adapter = CustomSentimentAdapter.new(llm: config.client)

IO.puts("""
GEPA Custom Sentiment Adapter Live Example
==========================================

Adapter/provider: #{config.adapter}/#{config.provider}
Model: #{config.model || "(provider default)"}
Training rows: #{length(config.trainset)}
Validation rows: #{length(config.valset)}
Max metric calls: #{config.max_metric_calls}
Reflection minibatch size: #{config.minibatch_size}
""")

{:ok, result} =
  GEPA.optimize(
    seed_candidate: seed_candidate,
    trainset: config.trainset,
    valset: config.valset,
    adapter: adapter,
    max_metric_calls: config.max_metric_calls,
    reflection_llm: config.client,
    reflection_minibatch_size: config.minibatch_size,
    structured_output: config.structured_output?
  )

IO.puts("""

Optimization Complete
=====================

Best validation score: #{Float.round(GEPA.Result.best_score(result), 4)}
Iterations: #{result.i}
Total evaluations: #{result.total_num_evals}

Best instruction:
#{GEPA.Result.best_candidate(result)["instruction"]}
""")
