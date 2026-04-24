defmodule GEPA.Callbacks do
  @moduledoc """
  Synchronous observational callbacks for GEPA optimization runs.

  Callback entries may be:

    * a two-arity function receiving `{event_name, event}`
    * a one-arity function receiving `event`
    * a module exporting `event_name/1`
    * a struct whose module exports `event_name/2`

  Callback failures are allowed to raise. This keeps failures visible and
  matches the current engine's fail-fast behavior for systemic errors.
  """

  @type event_name ::
          :optimization_start
          | :optimization_end
          | :iteration_start
          | :iteration_end
          | :candidate_accepted
          | :candidate_rejected

  @type event :: map()
  @type callback :: function() | module() | struct()

  @doc """
  Notify each callback of an event.
  """
  @spec notify([callback()] | nil, event_name(), event()) :: :ok
  def notify(nil, _event_name, _event), do: :ok
  def notify([], _event_name, _event), do: :ok

  def notify(callbacks, event_name, event) when is_list(callbacks) do
    Enum.each(callbacks, &notify_one(&1, event_name, event))
    :ok
  end

  def notify(callback, event_name, event) do
    notify([callback], event_name, event)
  end

  defp notify_one(callback, event_name, event) when is_function(callback, 2) do
    callback.(event_name, event)
  end

  defp notify_one(callback, _event_name, event) when is_function(callback, 1) do
    callback.(event)
  end

  defp notify_one(callback, event_name, event) when is_atom(callback) do
    if Code.ensure_loaded?(callback) and function_exported?(callback, event_name, 1) do
      apply(callback, event_name, [event])
    end
  end

  defp notify_one(%module{} = callback, event_name, event) do
    if function_exported?(module, event_name, 2) do
      apply(module, event_name, [callback, event])
    end
  end

  defp notify_one(_callback, _event_name, _event), do: :ok
end
