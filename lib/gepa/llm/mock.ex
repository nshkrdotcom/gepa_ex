defmodule GEPA.LLM.Mock do
  @moduledoc """
  Mock LLM client for testing.

  Returns deterministic "improved" responses for testing the optimization loop.
  """

  @doc """
  Generate a mock LLM response.

  Always returns an "improved" version of the instruction.
  """
  def generate(prompt) when is_binary(prompt) do
    # Extract current instruction if present
    improved =
      if String.contains?(prompt, "```") do
        "Improved instruction based on feedback:\n" <>
          "- Address identified issues\n" <>
          "- Incorporate successful patterns\n" <>
          "- Provide clear guidance"
      else
        "Generic improved instruction"
      end

    {:ok, "```\n#{improved}\n```"}
  end

  @doc """
  Simple completion for basic use cases.
  """
  def complete(messages) when is_list(messages) do
    # Extract user message
    user_msg =
      Enum.find_value(messages, "", fn
        %{role: "user", content: content} -> content
        _ -> nil
      end)

    # Simple mock: return part of the question as answer
    answer =
      user_msg
      |> String.split()
      |> Enum.take(3)
      |> Enum.join(" ")

    {:ok, %{content: "Answer: #{answer}"}}
  end
end
