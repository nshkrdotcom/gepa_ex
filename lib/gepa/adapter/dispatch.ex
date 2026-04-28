defmodule GEPA.Adapter.Dispatch do
  @moduledoc """
  Adapter dispatch helpers used by the Elixir GEPA engine.

  The Python reference has a single `GEPAAdapter` protocol.  The Elixir port
  intentionally keeps a lightweight behaviour-based mechanism, but this module
  makes that mechanism tolerant of all adapter shapes users naturally provide:

    * structs implementing `evaluate/4` and `make_reflective_dataset/4`
    * modules implementing `evaluate/4` or official-style `evaluate/3`
    * structs/modules that optionally expose `propose_new_texts`,
      `get_adapter_state`, and `set_adapter_state`

  All helpers normalize return values to the `{:ok, value} | {:error, reason}`
  shape expected by the engine.
  """

  alias GEPA.EvaluationBatch

  @type candidate :: %{String.t() => String.t()}
  @type adapter :: module() | struct()

  @doc "Return the module that should receive adapter callbacks."
  @spec module_for(adapter()) :: module() | nil
  def module_for(%module{}), do: module
  def module_for(module) when is_atom(module), do: module
  def module_for(_adapter), do: nil

  @doc "Evaluate a candidate through the configured adapter."
  @spec evaluate(adapter(), [term()], candidate(), boolean()) ::
          {:ok, EvaluationBatch.t()} | {:error, term()}
  def evaluate(adapter, batch, candidate, capture_traces) do
    module = module_for(adapter)

    cond do
      module != nil and function_exported?(module, :evaluate, 4) ->
        module.evaluate(adapter, batch, candidate, capture_traces)
        |> normalize_eval_batch()

      module != nil and function_exported?(module, :evaluate, 3) ->
        module.evaluate(batch, candidate, capture_traces)
        |> normalize_eval_batch()

      module != nil and function_exported?(module, :evaluate, 2) ->
        module.evaluate(batch, candidate)
        |> normalize_eval_batch()

      true ->
        {:error, {:adapter_callback_missing, module || adapter, :evaluate}}
    end
  rescue
    exception -> {:error, exception}
  end

  @doc "Build a reflective dataset through the adapter."
  @spec make_reflective_dataset(adapter(), candidate(), EvaluationBatch.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def make_reflective_dataset(adapter, candidate, %EvaluationBatch{} = eval_batch, components) do
    module = module_for(adapter)

    cond do
      module != nil and function_exported?(module, :make_reflective_dataset, 4) ->
        module.make_reflective_dataset(adapter, candidate, eval_batch, components)
        |> normalize_dataset()

      module != nil and function_exported?(module, :make_reflective_dataset, 3) ->
        module.make_reflective_dataset(candidate, eval_batch, components)
        |> normalize_dataset()

      true ->
        {:error, {:adapter_callback_missing, module || adapter, :make_reflective_dataset}}
    end
  rescue
    exception -> {:error, exception}
  end

  @doc "Ask an adapter to propose replacement text, when it owns custom proposal logic."
  @spec propose_new_texts(adapter(), candidate(), map(), [String.t()]) ::
          {:ok, map(), map(), map()} | {:error, term()} | :missing
  def propose_new_texts(adapter, candidate, reflective_dataset, components) do
    module = module_for(adapter)

    cond do
      module != nil and function_exported?(module, :propose_new_texts, 4) ->
        module.propose_new_texts(adapter, candidate, reflective_dataset, components)
        |> normalize_new_texts()

      module != nil and function_exported?(module, :propose_new_texts, 3) ->
        module.propose_new_texts(candidate, reflective_dataset, components)
        |> normalize_new_texts()

      true ->
        :missing
    end
  rescue
    exception -> {:error, exception}
  end

  @doc "Read opaque adapter state for checkpointing."
  @spec get_adapter_state(adapter()) :: map()
  def get_adapter_state(adapter) do
    module = module_for(adapter)

    if module != nil and function_exported?(module, :get_adapter_state, 1) do
      case module.get_adapter_state(adapter) do
        {:ok, state} when is_map(state) -> state
        state when is_map(state) -> state
        _other -> %{}
      end
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  @doc "Restore opaque adapter state after loading a checkpoint."
  @spec set_adapter_state(adapter(), map()) :: :ok | {:ok, term()} | term()
  def set_adapter_state(adapter, state) when is_map(state) do
    module = module_for(adapter)

    if module != nil and function_exported?(module, :set_adapter_state, 2) do
      module.set_adapter_state(adapter, state)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp normalize_eval_batch({:ok, %EvaluationBatch{} = batch}), do: {:ok, batch}
  defp normalize_eval_batch(%EvaluationBatch{} = batch), do: {:ok, batch}
  defp normalize_eval_batch({:error, reason}), do: {:error, reason}

  defp normalize_eval_batch({outputs, scores}) when is_list(outputs) and is_list(scores) do
    {:ok, %EvaluationBatch{outputs: outputs, scores: Enum.map(scores, &(&1 * 1.0))}}
  end

  defp normalize_eval_batch({outputs, scores, objective_scores})
       when is_list(outputs) and is_list(scores) do
    {:ok,
     %EvaluationBatch{
       outputs: outputs,
       scores: Enum.map(scores, &(&1 * 1.0)),
       objective_scores: objective_scores
     }}
  end

  defp normalize_eval_batch(other), do: {:error, {:invalid_evaluation_result, other}}

  defp normalize_dataset({:ok, dataset}) when is_map(dataset), do: {:ok, dataset}
  defp normalize_dataset(dataset) when is_map(dataset), do: {:ok, dataset}
  defp normalize_dataset({:error, reason}), do: {:error, reason}
  defp normalize_dataset(other), do: {:error, {:invalid_reflective_dataset, other}}

  defp normalize_new_texts({:ok, new_texts}) when is_map(new_texts),
    do: {:ok, new_texts, %{}, %{}}

  defp normalize_new_texts({:ok, new_texts, prompts, raw_outputs})
       when is_map(new_texts) and is_map(prompts) and is_map(raw_outputs),
       do: {:ok, new_texts, prompts, raw_outputs}

  defp normalize_new_texts(new_texts) when is_map(new_texts), do: {:ok, new_texts, %{}, %{}}
  defp normalize_new_texts({:error, reason}), do: {:error, reason}
  defp normalize_new_texts(other), do: {:error, {:invalid_proposal_result, other}}
end
