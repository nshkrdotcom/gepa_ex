defmodule GEPA.LLM.Mock do
  @moduledoc """
  Mock LLM implementation for testing.

  Returns deterministic responses for testing the optimization loop without
  making actual API calls. Useful for:
  - Unit testing
  - Integration testing
  - CI/CD pipelines
  - Development without API keys

  ## Examples

      # With fixed responses
      llm = GEPA.LLM.Mock.new(responses: ["Response 1", "Response 2"])
      {:ok, "Response 1"} = GEPA.LLM.complete(llm, "Any prompt")
      {:ok, "Response 2"} = GEPA.LLM.complete(llm, "Any prompt")

      # With dynamic response function
      llm = GEPA.LLM.Mock.new(response_fn: fn p -> "Echo: " <> p end)
      {:ok, "Echo: Hello"} = GEPA.LLM.complete(llm, "Hello")

      # Default behavior (improved instructions)
      llm = GEPA.LLM.Mock.new()
      {:ok, response} = GEPA.LLM.complete(llm, "test prompt")
  """

  @behaviour GEPA.LLM

  defstruct [
    :responses,
    :response_fn,
    :call_count
  ]

  @type t :: %__MODULE__{
          responses: [String.t()] | nil,
          response_fn: (String.t() -> String.t()) | nil,
          call_count: non_neg_integer()
        }

  @doc """
  Creates a new Mock LLM instance.

  ## Options

    - `:responses` - List of fixed responses to cycle through
    - `:response_fn` - Function to generate dynamic responses (prompt -> response)
    - If neither is provided, uses default improvement behavior

  ## Examples

      # Fixed responses
      llm = GEPA.LLM.Mock.new(responses: ["Yes", "No", "Maybe"])

      # Dynamic responses
      llm = GEPA.LLM.Mock.new(response_fn: fn p -> "Processed: " <> String.upcase(p) end)

      # Default behavior
      llm = GEPA.LLM.Mock.new()
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      responses: Keyword.get(opts, :responses),
      response_fn: Keyword.get(opts, :response_fn),
      call_count: 0
    }
  end

  @impl GEPA.LLM
  def complete(%__MODULE__{} = llm, prompt, _opts \\ []) when is_binary(prompt) do
    response =
      cond do
        # Use provided response function
        is_function(llm.response_fn, 1) ->
          llm.response_fn.(prompt)

        # Use fixed response (always returns first one for simplicity)
        # For cycling responses, use a response_fn with closure state
        is_list(llm.responses) and length(llm.responses) > 0 ->
          hd(llm.responses)

        # Default: generate improved instruction
        true ->
          generate_improved_instruction(prompt)
      end

    {:ok, response}
  end

  ## Legacy API (for backward compatibility)

  @doc """
  Legacy generate function for backward compatibility.

  Prefer using `GEPA.LLM.complete/3` instead.
  """
  def generate(prompt) when is_binary(prompt) do
    llm = new()
    complete(llm, prompt)
  end

  @doc """
  Legacy complete function for backward compatibility.

  Prefer using `GEPA.LLM.complete/3` instead.
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

  ## Private Functions

  defp generate_improved_instruction(prompt) do
    # Extract current instruction if present in the prompt
    improved =
      if String.contains?(prompt, "```") do
        """
        ```
        Improved instruction based on feedback:
        - Address identified issues from the examples
        - Incorporate successful patterns observed
        - Provide clear, actionable guidance
        - Include domain-specific knowledge
        ```
        """
      else
        """
        ```
        Generic improved instruction:
        - Analyze the input carefully
        - Apply relevant strategies
        - Provide accurate results
        ```
        """
      end

    String.trim(improved)
  end
end
