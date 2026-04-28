defmodule GEPA.LM do
  require Logger

  alias GEPA.LLM.{Client, Request, Response}

  @moduledoc """
  Upstream-compatible LM wrapper for reflection models.

  Existing `gepa_ex` code should keep using `GEPA.LLM`.  This module provides a
  small compatibility layer for code ported from Python's `gepa.lm`: it tracks
  approximate token counts and delegates text generation to either a callable or
  a normalized `GEPA.LLM` client.
  """

  defstruct [:model, :client, :counter, defaults: [], completion_kwargs: []]

  @type t :: %__MODULE__{
          model: term(),
          client: term(),
          counter: pid(),
          defaults: keyword(),
          completion_kwargs: keyword()
        }

  @request_opt_keys [
    :messages,
    :system,
    :schema,
    :tools,
    :tool_choice,
    :stream?,
    :temperature,
    :model,
    :max_tokens,
    :top_p,
    :timeout,
    :session,
    :provider_opts,
    :metadata
  ]

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
      defaults: Keyword.delete(opts, :client),
      completion_kwargs: Keyword.delete(opts, :client)
    }
  end

  @spec complete(t() | term(), GEPA.LLM.prompt(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def complete(lm_or_other, prompt, opts \\ [])

  def complete(%__MODULE__{} = lm, prompt, opts) do
    estimated_tokens_in = estimate_tokens(prompt)
    opts = Keyword.merge(lm.defaults, opts)

    result = complete_with_client(lm.client, lm.model, prompt, opts)

    case result do
      {:ok, %Response{} = response} ->
        text = response |> Response.text() |> String.trim()
        estimated_tokens_out = estimate_tokens(text)

        {tokens_in, tokens_out} =
          response_token_counts(response, estimated_tokens_in, estimated_tokens_out)

        update(lm, tokens_in, tokens_out, response_cost(response))
        {:ok, text}

      {:ok, text} ->
        text = String.trim(text)
        update(lm, estimated_tokens_in, estimate_tokens(text), 0.0)
        {:ok, text}

      {:error, _} = error ->
        update(lm, estimated_tokens_in, 0, 0.0)
        error
    end
  end

  def complete(other, prompt, opts), do: GEPA.LLM.complete(other, prompt, opts)

  defp complete_with_client(%Client{} = client, model, prompt, opts) do
    request =
      prompt
      |> Request.from_prompt(prepare_request_opts(model, opts))

    with {:ok, %Response{} = response} <- client.adapter.complete(client, request) do
      warn_if_truncated(response)
      {:ok, response}
    end
  end

  defp complete_with_client(client, _model, prompt, opts),
    do: GEPA.LLM.complete(client, prompt, opts)

  defp prepare_request_opts(model, opts) do
    provider_opts = Keyword.get(opts, :provider_opts, [])
    request_opts = Keyword.take(opts, @request_opt_keys)

    extra_provider_opts =
      opts
      |> Keyword.drop(@request_opt_keys)
      |> Keyword.delete(:client)

    request_opts
    |> Keyword.put(:provider_opts, Keyword.merge(provider_opts, extra_provider_opts))
    |> maybe_put_model(model)
  end

  defp maybe_put_model(opts, model) when is_binary(model),
    do: Keyword.put_new(opts, :model, model)

  defp maybe_put_model(opts, _model), do: opts

  defp warn_if_truncated(%Response{stop_reason: reason}) when reason in [:length, "length"] do
    Logger.warning("LM response was truncated by the provider")
  end

  defp warn_if_truncated(_response), do: :ok

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

  defp response_token_counts(%Response{usage: nil}, _estimated_tokens_in, _estimated_tokens_out),
    do: {0, 0}

  defp response_token_counts(%Response{usage: usage}, estimated_tokens_in, estimated_tokens_out) do
    usage = mapish(usage)

    tokens_in =
      usage_value(usage, [:prompt_tokens, "prompt_tokens", :input_tokens, "input_tokens"]) ||
        estimated_tokens_in

    tokens_out =
      usage_value(usage, [
        :completion_tokens,
        "completion_tokens",
        :output_tokens,
        "output_tokens"
      ]) || estimated_tokens_out

    {tokens_in, tokens_out}
  end

  defp response_cost(%Response{cost: cost}) when is_number(cost), do: cost * 1.0

  defp response_cost(%Response{cost: cost}) do
    cost
    |> mapish()
    |> usage_value([:total_cost, "total_cost", :cost, "cost", :total, "total"])
    |> case do
      value when is_number(value) -> value * 1.0
      _value -> 0.0
    end
  end

  defp mapish(nil), do: nil
  defp mapish(%_struct{} = value), do: Map.from_struct(value)
  defp mapish(%{} = value), do: value

  defp usage_value(nil, _keys), do: nil

  defp usage_value(%{} = usage, keys) do
    Enum.find_value(keys, &Map.get(usage, &1))
  end
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
