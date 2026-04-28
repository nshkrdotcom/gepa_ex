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

  Callback failures are not swallowed.  GEPA uses callbacks for observability;
  fail-fast behavior keeps instrumentation bugs visible during development.
  """

  @type event_name :: atom()
  @type event :: map()
  @type callback :: function() | module() | struct()

  @doc "Notify each callback of an event."
  @spec notify([callback()] | callback() | nil, event_name(), event()) :: :ok
  def notify(nil, _event_name, _event), do: :ok
  def notify([], _event_name, _event), do: :ok

  def notify(callbacks, event_name, event) when is_list(callbacks) do
    Enum.each(callbacks, &notify_one(&1, event_name, event))
    :ok
  end

  def notify(callback, event_name, event), do: notify([callback], event_name, event)

  @doc "Return the upstream-style `on_*` method atom for an event name."
  @spec method_name(event_name()) :: atom()
  def method_name(event_name) when is_atom(event_name), do: String.to_atom("on_#{event_name}")

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
