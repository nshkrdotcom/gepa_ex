defmodule GEPA.Strategies.CandidateSelector do
  @moduledoc """
  Behavior for selecting which program candidate to mutate.

  Candidate selection strategies balance exploration and exploitation in
  the optimization search space.
  """

  @doc """
  Select a candidate program index for mutation.

  ## Parameters

  - `selector_state`: Struct or module implementing the selection logic
  - `state`: Current optimization state
  - `rand_state`: Erlang random state (optional, for stochastic selectors)

  ## Returns

  Stateless selectors: `{program_idx, new_rand_state}`
  Stateful selectors: `{program_idx, updated_selector, new_rand_state}`
  """
  @callback select(term(), GEPA.State.t(), :rand.state() | nil) ::
              {GEPA.Types.program_idx(), :rand.state()}
              | {GEPA.Types.program_idx(), term(), :rand.state()}
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

  @spec select(GEPA.State.t(), :rand.state() | nil) ::
          {GEPA.Types.program_idx(), :rand.state()}
  def select(state, rand_state), do: select(nil, state, rand_state)

  @impl true
  @spec select(term(), GEPA.State.t(), :rand.state() | nil) ::
          {GEPA.Types.program_idx(), :rand.state()}
  def select(_selector, state, rand_state) do
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

  alias GEPA.Strategies.EvaluationPolicy.Full

  @doc """
  Return the index of the best-scoring program using average score and coverage.
  """
  @spec best_candidate_idx(GEPA.State.t()) :: GEPA.Types.program_idx()
  def best_candidate_idx(state) do
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {scores, idx} ->
      {avg, count} = Full.calculate_avg_and_coverage(scores)
      {idx, avg, count}
    end)
    |> Enum.max_by(fn {_idx, avg, coverage} -> {avg, coverage} end, fn -> {0, 0.0, 0} end)
    |> elem(0)
  end

  @spec select(GEPA.State.t(), :rand.state() | nil) ::
          {GEPA.Types.program_idx(), :rand.state()}
  def select(state, rand_state), do: select(nil, state, rand_state)

  @impl true
  @spec select(term(), GEPA.State.t(), :rand.state() | nil) ::
          {GEPA.Types.program_idx(), :rand.state()}
  def select(_selector, state, rand_state) do
    best_idx = best_candidate_idx(state)

    # Return tuple for consistency (pass through rand_state or use default)
    {best_idx, rand_state || :rand.seed(:exsss, {1, 2, 3})}
  end
end
