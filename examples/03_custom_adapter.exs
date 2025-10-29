#!/usr/bin/env elixir

# GEPA Custom Adapter Example
# ============================
#
# This example shows how to create a custom adapter for your specific use case.
# You'll learn to:
# - Implement the GEPA.Adapter behavior
# - Define custom evaluation logic
# - Extract component-specific traces
# - Integrate with your own systems
#
# ## To run:
#   mix run examples/03_custom_adapter.exs

# Mix.install([{:gepa_ex, path: "."}])

defmodule CustomSentimentAdapter do
  @moduledoc """
  Custom adapter for sentiment classification tasks.

  This demonstrates how to create an adapter for a specific domain:
  - Custom evaluation (accuracy for sentiment)
  - Component extraction
  - Trace handling
  """

  @behaviour GEPA.Adapter

  defstruct [:llm]

  def new(opts \\ []) do
    %__MODULE__{
      llm: Keyword.get(opts, :llm, GEPA.LLM.Mock.new())
    }
  end

  @impl true
  def evaluate(%__MODULE__{} = adapter, candidate, batch, _opts) do
    # For each example, use the LLM with the candidate instruction
    results =
      Enum.map(batch, fn example ->
        prompt = build_prompt(candidate["instruction"], example.text)

        # Get LLM response
        {:ok, response} = GEPA.LLM.complete(adapter.llm, prompt)

        # Parse sentiment from response
        predicted = extract_sentiment(response)
        correct = predicted == example.sentiment

        # Return evaluation result
        %{
          input: example.text,
          expected: example.sentiment,
          predicted: predicted,
          correct?: correct,
          score: if(correct, do: 1.0, else: 0.0),
          trace: %{
            prompt: prompt,
            response: response,
            component: "instruction"
          }
        }
      end)

    outputs = Enum.map(results, &Map.take(&1, [:predicted, :response]))
    scores = Enum.map(results, & &1.score)
    traces = Enum.map(results, & &1.trace)

    %GEPA.EvaluationBatch{
      outputs: outputs,
      scores: scores,
      traces: traces
    }
  end

  @impl true
  def extract_component_context(
        _adapter,
        _candidate,
        _component_name,
        _batch,
        traces,
        scores
      ) do
    # Build feedback for the instruction component
    feedback =
      Enum.zip(traces, scores)
      |> Enum.map(fn {trace, score} ->
        status = if score > 0.5, do: "✓ Correct", else: "✗ Wrong"

        """
        #{status}
        Input: #{trace.prompt |> String.slice(0, 100)}...
        Predicted: #{extract_sentiment(trace.response)}
        """
      end)
      |> Enum.join("\n\n")

    {:ok, feedback}
  end

  # Helper functions

  defp build_prompt(instruction, text) do
    """
    #{instruction}

    Text: #{text}

    Classify the sentiment as: positive, negative, or neutral
    """
  end

  defp extract_sentiment(response) do
    cond do
      String.contains?(String.downcase(response), "positive") -> "positive"
      String.contains?(String.downcase(response), "negative") -> "negative"
      true -> "neutral"
    end
  end
end

# Example data
trainset = [
  %{text: "I love this product! It's amazing!", sentiment: "positive"},
  %{text: "Terrible experience. Very disappointed.", sentiment: "negative"},
  %{text: "It's okay, nothing special.", sentiment: "neutral"},
  %{text: "Best purchase ever! Highly recommend.", sentiment: "positive"},
  %{text: "Waste of money. Do not buy.", sentiment: "negative"}
]

valset = [
  %{text: "Great quality and fast shipping!", sentiment: "positive"},
  %{text: "Not worth the price at all.", sentiment: "negative"}
]

seed_candidate = %{
  "instruction" => "Analyze the sentiment of the following text."
}

IO.puts("""
💭 GEPA Custom Adapter Example
==============================

This example demonstrates a custom sentiment classification adapter.

Training examples: #{length(trainset)}
Validation examples: #{length(valset)}

Initial instruction:
"#{seed_candidate["instruction"]}"

""")

# Create custom adapter
adapter =
  CustomSentimentAdapter.new(
    llm:
      GEPA.LLM.Mock.new(
        response_fn: fn prompt ->
          cond do
            String.contains?(prompt, "love") or String.contains?(prompt, "amazing") or
              String.contains?(prompt, "Great") or String.contains?(prompt, "Best") ->
              "The sentiment is positive."

            String.contains?(prompt, "Terrible") or String.contains?(prompt, "disappointed") or
              String.contains?(prompt, "Waste") or String.contains?(prompt, "Not worth") ->
              "The sentiment is negative."

            true ->
              "The sentiment is neutral."
          end
        end
      )
  )

IO.puts("⚙️  Running optimization with custom adapter...\n")

{:ok, result} =
  GEPA.optimize(
    seed_candidate: seed_candidate,
    trainset: trainset,
    valset: valset,
    adapter: adapter,
    max_metric_calls: 15
  )

IO.puts("""

✅ Optimization Complete!
========================

Best validation score: #{Float.round(GEPA.Result.best_score(result), 3)}
Iterations: #{result.i}

Optimized instruction:
#{GEPA.Result.best_candidate(result)["instruction"]}

📚 What you learned:
- How to implement the GEPA.Adapter behavior
- Custom evaluation logic for your domain
- Trace extraction for component feedback
- Integration with domain-specific scoring

🔧 Customization points:
1. evaluate/4 - Define how to score candidate on your task
2. extract_component_context/6 - Extract feedback for reflection
3. Build prompts specific to your domain
4. Define success metrics for your use case

💡 Your turn:
- Adapt this for your own task (classification, generation, etc.)
- Add more sophisticated evaluation metrics
- Integrate with your existing systems
- See examples/04_state_persistence.exs for long-running optimizations
""")
