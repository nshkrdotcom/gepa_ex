defmodule GEPA.Strategies.ComponentSelector do
  @moduledoc """
  Behavior for selecting which components to update during mutation.

  In multi-component optimization, this determines which components
  of the program to mutate in each iteration.
  """

  @doc """
  Select component names to update.

  ## Parameters

  - `state`: Current optimization state
  - `candidate_idx`: Index of the candidate being mutated
  - `candidate`: The candidate program

  ## Returns

  `{component_names, updated_state}` where component_names is a list of
  component names to update, and updated_state has tracking info updated.
  """
  @callback select(GEPA.State.t(), non_neg_integer(), map()) ::
              {[String.t()], GEPA.State.t()}
end

defmodule GEPA.Strategies.ComponentSelector.RoundRobin do
  @moduledoc """
  Cycles through components one at a time.

  Each candidate maintains its own position in the cycle, allowing
  independent component update schedules for different candidates.
  """

  @behaviour GEPA.Strategies.ComponentSelector

  @impl true
  @spec select(GEPA.State.t(), non_neg_integer(), map()) ::
          {[String.t()], GEPA.State.t()}
  def select(state, candidate_idx, _candidate) do
    # Get current position for this candidate
    current_pos =
      Enum.at(state.named_predictor_id_to_update_next_for_program_candidate, candidate_idx, 0)

    # Get component name at this position
    component_name = Enum.at(state.list_of_named_predictors, current_pos)

    # Calculate next position (circular)
    next_pos = rem(current_pos + 1, length(state.list_of_named_predictors))

    # Update state with next position
    new_tracking =
      List.replace_at(
        state.named_predictor_id_to_update_next_for_program_candidate,
        candidate_idx,
        next_pos
      )

    new_state = %{state | named_predictor_id_to_update_next_for_program_candidate: new_tracking}

    {[component_name], new_state}
  end
end

defmodule GEPA.Strategies.ComponentSelector.All do
  @moduledoc """
  Updates all components simultaneously.

  Good for holistic optimization where components have interdependencies.
  """

  @behaviour GEPA.Strategies.ComponentSelector

  @impl true
  @spec select(GEPA.State.t(), non_neg_integer(), map()) ::
          {[String.t()], GEPA.State.t()}
  def select(state, _candidate_idx, candidate) do
    # Return all component names
    {Map.keys(candidate), state}
  end
end
