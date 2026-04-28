defmodule GEPA.Adapter.Dispatch do
  @moduledoc """
  Adapter dispatch helpers used by the Elixir GEPA engine.

  Python GEPA exposes one `GEPAAdapter` protocol. This Elixir port keeps a
  lightweight behaviour/duck-typing boundary, but centralizes all dispatch so
  the engine receives normalized `EvaluationBatch` values and consistent error
  tuples.
  """

  alias GEPA.EvaluationBatch

  @type candidate :: %{String.t() => String.t()}
  @type adapter :: module() | struct() | map()

  @doc "Return the module that should receive adapter callbacks, when any."
  @spec module_for(adapter()) :: module() | nil
  def module_for(%module{}), do: module
  def module_for(module) when is_atom(module), do: module
  def module_for(_adapter), do: nil

  @doc "Whether an adapter provides its own official-style proposal hook."
  @spec has_propose_new_texts?(adapter()) :: boolean()
  def has_propose_new_texts?(adapter) do
    module = module_for(adapter)

    cond do
      module != nil and function_exported?(module, :propose_new_texts, 4) -> true
      module != nil and function_exported?(module, :propose_new_texts, 3) -> true
      is_map(adapter) and is_function(Map.get(adapter, :propose_new_texts), 4) -> true
      is_map(adapter) and is_function(Map.get(adapter, :propose_new_texts), 3) -> true
      is_map(adapter) and is_function(Map.get(adapter, "propose_new_texts"), 4) -> true
      is_map(adapter) and is_function(Map.get(adapter, "propose_new_texts"), 3) -> true
      true -> false
    end
  end

  @doc "Evaluate a candidate through the configured adapter."
  @spec evaluate(adapter(), [term()], candidate(), boolean()) ::
          {:ok, EvaluationBatch.t()} | {:error, term()}
  def evaluate(adapter, batch, candidate, capture_traces) do
    module = module_for(adapter)

    result =
      cond do
        module != nil and function_exported?(module, :evaluate, 4) ->
          module.evaluate(adapter, batch, candidate, capture_traces)

        module != nil and function_exported?(module, :evaluate, 3) ->
          module.evaluate(batch, candidate, capture_traces)

        module != nil and function_exported?(module, :evaluate, 2) ->
          module.evaluate(batch, candidate)

        is_map(adapter) and is_function(Map.get(adapter, :evaluate), 4) ->
          adapter.evaluate.(adapter, batch, candidate, capture_traces)

        is_map(adapter) and is_function(Map.get(adapter, :evaluate), 3) ->
          adapter.evaluate.(batch, candidate, capture_traces)

        is_map(adapter) and is_function(Map.get(adapter, "evaluate"), 4) ->
          Map.fetch!(adapter, "evaluate").(adapter, batch, candidate, capture_traces)

        is_map(adapter) and is_function(Map.get(adapter, "evaluate"), 3) ->
          Map.fetch!(adapter, "evaluate").(batch, candidate, capture_traces)

        true ->
          {:error, {:adapter_callback_missing, module || adapter, :evaluate}}
      end

    normalize_eval_batch(result, expected_count: length(batch), capture_traces: capture_traces)
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

      module != nil and function_exported?(module, :make_reflective_dataset, 3) ->
        module.make_reflective_dataset(candidate, eval_batch, components)

      is_map(adapter) and is_function(Map.get(adapter, :make_reflective_dataset), 4) ->
        adapter.make_reflective_dataset.(adapter, candidate, eval_batch, components)

      is_map(adapter) and is_function(Map.get(adapter, :make_reflective_dataset), 3) ->
        adapter.make_reflective_dataset.(candidate, eval_batch, components)

      true ->
        {:error, {:adapter_callback_missing, module || adapter, :make_reflective_dataset}}
    end
    |> normalize_dataset()
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

      module != nil and function_exported?(module, :propose_new_texts, 3) ->
        module.propose_new_texts(candidate, reflective_dataset, components)

      is_map(adapter) and is_function(Map.get(adapter, :propose_new_texts), 4) ->
        adapter.propose_new_texts.(adapter, candidate, reflective_dataset, components)

      is_map(adapter) and is_function(Map.get(adapter, :propose_new_texts), 3) ->
        adapter.propose_new_texts.(candidate, reflective_dataset, components)

      is_map(adapter) and is_function(Map.get(adapter, "propose_new_texts"), 4) ->
        Map.fetch!(adapter, "propose_new_texts").(
          adapter,
          candidate,
          reflective_dataset,
          components
        )

      is_map(adapter) and is_function(Map.get(adapter, "propose_new_texts"), 3) ->
        Map.fetch!(adapter, "propose_new_texts").(candidate, reflective_dataset, components)

      true ->
        :missing
    end
    |> normalize_new_texts()
  rescue
    exception -> {:error, exception}
  end

  @doc "Read opaque adapter state for checkpointing."
  @spec get_adapter_state(adapter()) :: map()
  def get_adapter_state(adapter) do
    module = module_for(adapter)

    cond do
      module != nil and function_exported?(module, :get_adapter_state, 1) ->
        module.get_adapter_state(adapter)

      is_map(adapter) and is_function(Map.get(adapter, :get_adapter_state), 1) ->
        adapter.get_adapter_state.(adapter)

      is_map(adapter) and is_function(Map.get(adapter, :get_adapter_state), 0) ->
        adapter.get_adapter_state.()

      true ->
        %{}
    end
    |> normalize_state()
  rescue
    _ -> %{}
  end

  @doc "Restore opaque adapter state after loading a checkpoint."
  @spec set_adapter_state(adapter(), map()) :: :ok | {:ok, term()} | term()
  def set_adapter_state(adapter, state) when is_map(state) do
    module = module_for(adapter)

    cond do
      module != nil and function_exported?(module, :set_adapter_state, 2) ->
        module.set_adapter_state(adapter, state)

      is_map(adapter) and is_function(Map.get(adapter, :set_adapter_state), 2) ->
        adapter.set_adapter_state.(adapter, state)

      is_map(adapter) and is_function(Map.get(adapter, :set_adapter_state), 1) ->
        adapter.set_adapter_state.(state)

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp normalize_eval_batch(result, opts) do
    case result do
      {:ok, %EvaluationBatch{} = batch} ->
        validate_eval_batch(batch, opts)

      %EvaluationBatch{} = batch ->
        validate_eval_batch(batch, opts)

      {:error, reason} ->
        {:error, reason}

      {outputs, scores} when is_list(outputs) and is_list(scores) ->
        %EvaluationBatch{outputs: outputs, scores: Enum.map(scores, &(&1 * 1.0))}
        |> validate_eval_batch(opts)

      {outputs, scores, objective_scores} when is_list(outputs) and is_list(scores) ->
        %EvaluationBatch{
          outputs: outputs,
          scores: Enum.map(scores, &(&1 * 1.0)),
          objective_scores: objective_scores
        }
        |> validate_eval_batch(opts)

      other ->
        {:error, {:invalid_evaluation_result, other}}
    end
  end

  defp validate_eval_batch(%EvaluationBatch{} = batch, opts) do
    batch = EvaluationBatch.normalize_scores(batch)

    case EvaluationBatch.validate(batch, opts) do
      :ok -> {:ok, batch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_dataset({:ok, dataset}) when is_map(dataset), do: {:ok, dataset}
  defp normalize_dataset(dataset) when is_map(dataset), do: {:ok, dataset}
  defp normalize_dataset({:error, reason}), do: {:error, reason}
  defp normalize_dataset(other), do: {:error, {:invalid_reflective_dataset, other}}

  defp normalize_new_texts(:missing), do: :missing

  defp normalize_new_texts({:ok, new_texts}) when is_map(new_texts),
    do: {:ok, new_texts, %{}, %{}}

  defp normalize_new_texts({:ok, new_texts, prompts, raw_outputs})
       when is_map(new_texts) and is_map(prompts) and is_map(raw_outputs),
       do: {:ok, new_texts, prompts, raw_outputs}

  defp normalize_new_texts(new_texts) when is_map(new_texts), do: {:ok, new_texts, %{}, %{}}
  defp normalize_new_texts({:error, reason}), do: {:error, reason}
  defp normalize_new_texts(other), do: {:error, {:invalid_proposal_result, other}}

  defp normalize_state({:ok, state}) when is_map(state), do: Map.new(state)
  defp normalize_state(state) when is_map(state), do: Map.new(state)
  defp normalize_state(_other), do: %{}
end
