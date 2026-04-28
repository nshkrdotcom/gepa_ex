defmodule GEPA.LM do
  @moduledoc """
  Upstream-compatible LM wrapper for reflection models.

  Existing `gepa_ex` code should keep using `GEPA.LLM`.  This module provides a
  small compatibility layer for code ported from Python's `gepa.lm`: it tracks
  approximate token counts and delegates text generation to either a callable or
  a normalized `GEPA.LLM` client.
  """

  defstruct [:model, :client, :counter, defaults: []]

  @type t :: %__MODULE__{model: term(), client: term(), counter: pid(), defaults: keyword()}

  @spec new(term(), keyword()) :: t()
  def new(model, opts \\ []) do
    {:ok, counter} =
      Agent.start_link(fn ->
        %{total_cost: 0.0, total_tokens_in: 0, total_tokens_out: 0, calls: 0}
      end)

    %__MODULE__{
      model: model,
      client: Keyword.get(opts, :client, model),
      counter: counter,
      defaults: opts
    }
  end

  @spec complete(t() | term(), GEPA.LLM.prompt(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def complete(lm_or_other, prompt, opts \\ [])

  def complete(%__MODULE__{} = lm, prompt, opts) do
    tokens_in = estimate_tokens(prompt)

    result = GEPA.LLM.complete(lm.client, prompt, Keyword.merge(lm.defaults, opts))

    case result do
      {:ok, text} ->
        update(lm, tokens_in, estimate_tokens(text), 0.0)
        {:ok, text}

      {:error, _} = error ->
        update(lm, tokens_in, 0, 0.0)
        error
    end
  end

  def complete(other, prompt, opts), do: GEPA.LLM.complete(other, prompt, opts)

  @spec batch_complete(t(), [GEPA.LLM.prompt()], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def batch_complete(%__MODULE__{} = lm, prompts, opts \\ []) when is_list(prompts) do
    prompts
    |> Enum.map(&complete(lm, &1, opts))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, text}, {:ok, acc} -> {:cont, {:ok, [text | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      error -> error
    end
  end

  @spec total_cost(t()) :: float()
  def total_cost(%__MODULE__{counter: counter}), do: get(counter, :total_cost)

  @spec total_tokens_in(t()) :: non_neg_integer()
  def total_tokens_in(%__MODULE__{counter: counter}), do: get(counter, :total_tokens_in)

  @spec total_tokens_out(t()) :: non_neg_integer()
  def total_tokens_out(%__MODULE__{counter: counter}), do: get(counter, :total_tokens_out)

  @spec calls(t()) :: non_neg_integer()
  def calls(%__MODULE__{counter: counter}), do: get(counter, :calls)

  @spec counters(t()) :: map()
  def counters(%__MODULE__{counter: counter}), do: Agent.get(counter, & &1)

  defp update(%__MODULE__{counter: counter}, tokens_in, tokens_out, cost) do
    Agent.update(counter, fn counters ->
      counters
      |> Map.update!(:total_tokens_in, &(&1 + tokens_in))
      |> Map.update!(:total_tokens_out, &(&1 + tokens_out))
      |> Map.update!(:total_cost, &(&1 + cost))
      |> Map.update!(:calls, &(&1 + 1))
    end)
  end

  defp get(counter, key), do: Agent.get(counter, &Map.get(&1, key, 0))

  defp estimate_tokens(prompt) when is_binary(prompt), do: max(1, div(String.length(prompt), 4))
  defp estimate_tokens(prompt), do: prompt |> inspect() |> estimate_tokens()
end

defmodule GEPA.LM.Tracking do
  @moduledoc "Compatibility alias for tracking arbitrary callable LMs."

  @spec new(function()) :: GEPA.LLM.Tracking.t()
  defdelegate new(callable), to: GEPA.LLM.Tracking
  defdelegate complete(tracker, prompt, opts \\ []), to: GEPA.LLM.Tracking
  defdelegate total_cost(tracker), to: GEPA.LLM.Tracking
  defdelegate total_tokens_in(tracker), to: GEPA.LLM.Tracking
  defdelegate total_tokens_out(tracker), to: GEPA.LLM.Tracking
  defdelegate calls(tracker), to: GEPA.LLM.Tracking
  defdelegate counters(tracker), to: GEPA.LLM.Tracking
end
