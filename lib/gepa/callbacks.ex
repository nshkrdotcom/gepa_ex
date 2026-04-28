defmodule GEPA.Callbacks do
  @moduledoc """
  Synchronous observational callbacks for GEPA optimization runs.

  This module accepts both Elixir-native event names (`:iteration_end`) and the
  upstream Python-style callback methods (`on_iteration_end/1`).  Callback
  entries may be functions, modules, or structs:

    * two-arity function: `fn event_name, event -> ... end`
    * one-arity function: `fn event -> ... end`
    * module exporting `event_name/1` or `on_event_name/1`
    * struct whose module exports `event_name/2` or `on_event_name/2`

  Callback failures are logged and do not prevent later callbacks from
  receiving the same event, matching the upstream GEPA callback contract.
  """

  require Logger

  @type event_name :: atom() | String.t()
  @type event :: map()
  @type callback :: function() | module() | struct()

  @doc "Notify each callback of an event."
  @spec notify([callback()] | callback() | nil, event_name(), event()) :: :ok
  def notify(nil, _event_name, _event), do: :ok
  def notify([], _event_name, _event), do: :ok

  def notify(callbacks, event_name, event) when is_list(callbacks) do
    event_name = normalize_event_name(event_name)

    Enum.each(callbacks, fn callback ->
      notify_one_safely(callback, event_name, event)
    end)

    :ok
  end

  def notify(callback, event_name, event), do: notify([callback], event_name, event)

  @doc "Return the upstream-style `on_*` method atom for an event name."
  @spec method_name(event_name()) :: atom()
  def method_name(event_name) when is_atom(event_name), do: String.to_atom("on_#{event_name}")
  def method_name("on_" <> _ = event_name), do: String.to_atom(event_name)
  def method_name(event_name) when is_binary(event_name), do: String.to_atom("on_#{event_name}")

  defp normalize_event_name(event_name) when is_atom(event_name), do: event_name

  defp normalize_event_name("on_" <> event_name) when is_binary(event_name) do
    String.to_atom(event_name)
  end

  defp normalize_event_name(event_name) when is_binary(event_name), do: String.to_atom(event_name)

  defp notify_one_safely(callback, event_name, event) do
    notify_one(callback, event_name, event)
  rescue
    exception ->
      Logger.warning(
        "GEPA callback #{inspect(callback)} failed on #{method_name(event_name)}: #{Exception.message(exception)}"
      )
  end

  defp notify_one(callback, event_name, event) when is_function(callback, 2) do
    callback.(event_name, event)
  end

  defp notify_one(callback, _event_name, event) when is_function(callback, 1) do
    callback.(event)
  end

  defp notify_one(callback, event_name, event) when is_atom(callback) do
    cond do
      Code.ensure_loaded?(callback) and function_exported?(callback, event_name, 1) ->
        apply(callback, event_name, [event])

      Code.ensure_loaded?(callback) and function_exported?(callback, method_name(event_name), 1) ->
        apply(callback, method_name(event_name), [event])

      true ->
        :ok
    end
  end

  defp notify_one(%module{} = callback, event_name, event) do
    method = method_name(event_name)

    cond do
      function_exported?(module, event_name, 2) ->
        apply(module, event_name, [callback, event])

      function_exported?(module, method, 2) ->
        apply(module, method, [callback, event])

      function_exported?(module, event_name, 1) ->
        apply(module, event_name, [event])

      function_exported?(module, method, 1) ->
        apply(module, method, [event])

      true ->
        :ok
    end
  end

  defp notify_one(_callback, _event_name, _event), do: :ok
end

defmodule GEPA.Callbacks.Composite do
  @moduledoc """
  Callback container that forwards events to each registered callback.
  """

  defstruct callbacks: []

  @type t :: %__MODULE__{callbacks: [GEPA.Callbacks.callback()]}

  @doc "Create a composite callback."
  @spec new([GEPA.Callbacks.callback()]) :: t()
  def new(callbacks \\ []), do: %__MODULE__{callbacks: List.wrap(callbacks)}

  @doc "Return a composite with one callback appended."
  @spec add(t(), GEPA.Callbacks.callback()) :: t()
  def add(%__MODULE__{} = composite, callback) do
    %{composite | callbacks: composite.callbacks ++ [callback]}
  end

  for event_name <- [
        :optimization_start,
        :optimization_end,
        :iteration_start,
        :iteration_end,
        :candidate_selected,
        :minibatch_sampled,
        :evaluation_start,
        :evaluation_end,
        :evaluation_skipped,
        :reflective_dataset_built,
        :proposal_start,
        :proposal_end,
        :candidate_accepted,
        :candidate_rejected,
        :merge_attempted,
        :merge_accepted,
        :merge_rejected,
        :pareto_front_updated,
        :state_saved,
        :budget_updated,
        :error,
        :valset_evaluated
      ] do
    method_name = String.to_atom("on_#{event_name}")

    def unquote(method_name)(%__MODULE__{} = composite, event) do
      GEPA.Callbacks.notify(composite.callbacks, unquote(event_name), event)
    end
  end
end
