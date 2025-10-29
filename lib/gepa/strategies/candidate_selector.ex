defmodule GEPA.Strategies.CandidateSelector do
  @moduledoc """
  Behavior for selecting which program candidate to mutate.

  Candidate selection strategies balance exploration and exploitation in
  the optimization search space.
  """

  @doc """
  Select a candidate program index for mutation.

  ## Parameters

  - `state`: Current optimization state
  - `rand_state`: Erlang random state (optional, for stochastic selectors)

  ## Returns

  For deterministic selectors: `program_idx`
  For stochastic selectors: `{program_idx, new_rand_state}`
  """
  @callback select(GEPA.State.t(), :rand.state() | nil) ::
              GEPA.Types.program_idx() | {GEPA.Types.program_idx(), :rand.state()}
end

defmodule GEPA.Strategies.CandidateSelector.Pareto do
  @moduledoc """
  Selects candidates from Pareto front using frequency-weighted sampling.

  Programs appearing in more Pareto fronts have higher selection probability.
  This naturally balances specialization (programs good at specific examples)
  with generalization (programs good across many examples).
  """

  @behaviour GEPA.Strategies.CandidateSelector

  alias GEPA.Utils.Pareto

  @impl true
  def select(state, rand_state) do
    # Build scores map for Pareto utilities
    scores =
      state.prog_candidate_val_subscores
      |> Enum.with_index()
      |> Enum.into(%{}, fn {score_map, idx} ->
        if map_size(score_map) > 0 do
          avg = Enum.sum(Map.values(score_map)) / map_size(score_map)
          {idx, avg}
        else
          {idx, 0.0}
        end
      end)

    # Use Pareto utilities to select
    Pareto.select_from_pareto_front(
      state.program_at_pareto_front_valset,
      scores,
      rand_state
    )
  end
end

defmodule GEPA.Strategies.CandidateSelector.CurrentBest do
  @moduledoc """
  Greedy selector - always picks the highest-scoring program.

  Uses exploitation without exploration. Good for final refinement phase.
  """

  @behaviour GEPA.Strategies.CandidateSelector

  @impl true
  def select(state, rand_state) do
    # Find program with highest average score
    best_idx =
      state.prog_candidate_val_subscores
      |> Enum.with_index()
      |> Enum.max_by(fn {scores, _idx} ->
        if map_size(scores) > 0 do
          Enum.sum(Map.values(scores)) / map_size(scores)
        else
          0.0
        end
      end)
      |> elem(1)

    # Return tuple for consistency (pass through rand_state or use default)
    {best_idx, rand_state || :rand.seed(:exsss, {1, 2, 3})}
  end
end
