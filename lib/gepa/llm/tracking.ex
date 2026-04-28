defmodule GEPA.LLM.Tracking do
  @moduledoc """
  Wraps arbitrary callable LLMs with lightweight token/cost accounting.

  Elixir values are immutable, so counters are kept in an Agent owned by the
  wrapper. `GEPA.StopCondition.MaxReflectionCost` can read the live cost via
  `total_cost/1`.
  """

  defstruct [:callable, :counter]

  @type counters :: %{
          total_cost: float(),
          total_tokens_in: non_neg_integer(),
          total_tokens_out: non_neg_integer(),
          calls: non_neg_integer()
        }

  @type t :: %__MODULE__{callable: function(), counter: pid()}

  @chars_per_token 4

  @spec new(function()) :: t()
  def new(callable) when is_function(callable, 1) or is_function(callable, 2) do
    {:ok, counter} =
      Agent.start_link(fn ->
        %{total_cost: 0.0, total_tokens_in: 0, total_tokens_out: 0, calls: 0}
      end)

    %__MODULE__{callable: callable, counter: counter}
  end

  @spec complete(t(), GEPA.LLM.prompt(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(%__MODULE__{} = tracking, prompt, opts \\ []) do
    started_tokens = estimate_tokens(prompt)

    try do
      response =
        if is_function(tracking.callable, 2) do
          tracking.callable.(prompt, opts)
        else
          tracking.callable.(prompt)
        end
        |> normalize_response()

      case response do
        {:ok, text} ->
          update_counters(tracking, started_tokens, estimate_tokens(text))
          {:ok, text}

        {:error, _} = error ->
          update_counters(tracking, started_tokens, 0)
          error
      end
    rescue
      error ->
        update_counters(tracking, started_tokens, 0)
        {:error, Exception.message(error)}
    end
  end

  @spec total_cost(t()) :: float()
  def total_cost(%__MODULE__{counter: counter}), do: get(counter, :total_cost, 0.0)

  @spec total_tokens_in(t()) :: non_neg_integer()
  def total_tokens_in(%__MODULE__{counter: counter}), do: get(counter, :total_tokens_in, 0)

  @spec total_tokens_out(t()) :: non_neg_integer()
  def total_tokens_out(%__MODULE__{counter: counter}), do: get(counter, :total_tokens_out, 0)

  @spec calls(t()) :: non_neg_integer()
  def calls(%__MODULE__{counter: counter}), do: get(counter, :calls, 0)

  @spec counters(t()) :: counters()
  def counters(%__MODULE__{counter: counter}), do: Agent.get(counter, & &1)

  defp update_counters(%__MODULE__{counter: counter}, tokens_in, tokens_out) do
    Agent.update(counter, fn counters ->
      counters
      |> Map.update!(:total_tokens_in, &(&1 + tokens_in))
      |> Map.update!(:total_tokens_out, &(&1 + tokens_out))
      |> Map.update!(:calls, &(&1 + 1))
    end)
  end

  defp get(counter, key, default), do: Agent.get(counter, &Map.get(&1, key, default))

  defp estimate_tokens(prompt) when is_binary(prompt),
    do: max(1, div(String.length(prompt), @chars_per_token))

  defp estimate_tokens(prompt), do: prompt |> inspect() |> estimate_tokens()

  defp normalize_response({:ok, response}) when is_binary(response), do: {:ok, response}
  defp normalize_response({:ok, %{content: content}}) when is_binary(content), do: {:ok, content}
  defp normalize_response({:ok, %{text: text}}) when is_binary(text), do: {:ok, text}
  defp normalize_response({:error, _} = error), do: error
  defp normalize_response(response) when is_binary(response), do: {:ok, response}
  defp normalize_response(%{content: content}) when is_binary(content), do: {:ok, content}
  defp normalize_response(%{text: text}) when is_binary(text), do: {:ok, text}
  defp normalize_response(other), do: {:ok, to_string(other)}
end
