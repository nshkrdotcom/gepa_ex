defmodule GEPA.Strategies.ComponentSelector do
  @moduledoc """
  Behaviour for selecting which named candidate components should be updated.
  """

  @callback select(GEPA.State.t(), non_neg_integer(), map()) :: {[String.t()], GEPA.State.t()}
end

defmodule GEPA.Strategies.ComponentSelector.RoundRobin do
  @moduledoc """
  Official-style round-robin component selector.

  Each candidate tracks its own next component pointer. This lets a candidate
  resume where it left off after descendants are accepted, matching the Python
  optimizer's per-program component schedule.
  """

  @behaviour GEPA.Strategies.ComponentSelector

  @impl true
  def select(state, candidate_idx, candidate) do
    components = selectable_components(state, candidate)

    case components do
      [] ->
        {[], state}

      _ ->
        tracking =
          ensure_tracking_slot(
            state.named_predictor_id_to_update_next_for_program_candidate,
            candidate_idx
          )

        current_pos = Enum.at(tracking, candidate_idx, 0)
        component_name = Enum.at(components, rem(current_pos, length(components)))
        next_pos = rem(current_pos + 1, length(components))
        new_tracking = List.replace_at(tracking, candidate_idx, next_pos)

        new_state = %{
          state
          | named_predictor_id_to_update_next_for_program_candidate: new_tracking
        }

        {[component_name], new_state}
    end
  end

  defp selectable_components(state, candidate) do
    state.list_of_named_predictors
    |> Enum.filter(&Map.has_key?(candidate, &1))
    |> case do
      [] -> candidate |> Map.keys() |> Enum.sort()
      names -> names
    end
  end

  defp ensure_tracking_slot(tracking, candidate_idx) do
    if candidate_idx < length(tracking) do
      tracking
    else
      tracking ++ List.duplicate(0, candidate_idx - length(tracking) + 1)
    end
  end
end

defmodule GEPA.Strategies.ComponentSelector.All do
  @moduledoc "Update all candidate components together."

  @behaviour GEPA.Strategies.ComponentSelector

  @impl true
  def select(state, _candidate_idx, candidate) do
    component_names =
      state.list_of_named_predictors
      |> Enum.filter(&Map.has_key?(candidate, &1))
      |> case do
        [] -> Map.keys(candidate) |> Enum.sort()
        names -> names
      end

    {component_names, state}
  end
end
