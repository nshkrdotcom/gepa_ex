defmodule GEPA.State do
  @moduledoc """
  Persistent state tracking the complete optimization history.

  This is the heart of GEPA - all candidates, scores, Pareto fronts,
  and lineage are stored here.
  """

  alias GEPA.Types

  @type t :: %__MODULE__{
          # All discovered program candidates
          program_candidates: [Types.candidate()],

          # Parent relationships (genealogy) - list per program
          parent_program_for_candidate: [[Types.program_idx() | nil]],

          # Sparse validation scores (only evaluated examples)
          prog_candidate_val_subscores: [Types.sparse_scores()],

          # Pareto front tracking
          pareto_front_valset: %{Types.data_id() => float()},
          program_at_pareto_front_valset: Types.pareto_fronts(),

          # Component metadata
          list_of_named_predictors: [String.t()],
          named_predictor_id_to_update_next_for_program_candidate: [non_neg_integer()],

          # Iteration tracking
          i: non_neg_integer(),
          num_full_ds_evals: non_neg_integer(),
          total_num_evals: non_neg_integer(),
          num_metric_calls_by_discovery: [non_neg_integer()],

          # Trace and metadata
          full_program_trace: [map()],
          best_outputs_valset: %{Types.data_id() => [{Types.program_idx(), term()}]} | nil,
          validation_schema_version: pos_integer()
        }

  @enforce_keys [
    :program_candidates,
    :parent_program_for_candidate,
    :prog_candidate_val_subscores,
    :pareto_front_valset,
    :program_at_pareto_front_valset,
    :list_of_named_predictors
  ]

  defstruct [
    :program_candidates,
    :parent_program_for_candidate,
    :prog_candidate_val_subscores,
    :pareto_front_valset,
    :program_at_pareto_front_valset,
    :list_of_named_predictors,
    named_predictor_id_to_update_next_for_program_candidate: [],
    i: 0,
    num_full_ds_evals: 0,
    total_num_evals: 0,
    num_metric_calls_by_discovery: [],
    full_program_trace: [],
    best_outputs_valset: nil,
    validation_schema_version: 2
  ]

  @doc """
  Create new state from seed candidate and initial evaluation.

  ## Parameters

  - `seed_candidate`: Initial program as map of component name -> text
  - `eval_batch`: Results from evaluating seed on validation set
  - `valset_ids`: List of validation example IDs

  ## Returns

  New `GEPA.State` struct initialized with seed program
  """
  @spec new(Types.candidate(), GEPA.EvaluationBatch.t(), [Types.data_id()]) :: t()
  def new(seed_candidate, eval_batch, valset_ids) do
    # Get component names (sorted for determinism)
    component_names = Map.keys(seed_candidate) |> Enum.sort()

    # Create initial Pareto fronts from seed scores
    {pareto_front, program_at_pareto_front} =
      valset_ids
      |> Enum.zip(eval_batch.scores)
      |> Enum.reduce({%{}, %{}}, fn {val_id, score}, {fronts, programs} ->
        {
          Map.put(fronts, val_id, score),
          Map.put(programs, val_id, MapSet.new([0]))
        }
      end)

    # Create sparse scores map for seed program
    seed_scores =
      valset_ids
      |> Enum.zip(eval_batch.scores)
      |> Enum.into(%{})

    %__MODULE__{
      program_candidates: [seed_candidate],
      parent_program_for_candidate: [[nil]],
      prog_candidate_val_subscores: [seed_scores],
      pareto_front_valset: pareto_front,
      program_at_pareto_front_valset: program_at_pareto_front,
      list_of_named_predictors: component_names,
      named_predictor_id_to_update_next_for_program_candidate: [0],
      i: 0,
      num_full_ds_evals: 0,
      total_num_evals: length(valset_ids),
      num_metric_calls_by_discovery: [],
      full_program_trace: [],
      best_outputs_valset: nil,
      validation_schema_version: 2
    }
  end

  @doc """
  Add a new program to the state and update Pareto fronts.

  ## Parameters

  - `state`: Current state
  - `new_candidate`: New program to add
  - `parent_program_ids`: List of parent indices
  - `val_scores`: Map of val_id -> score for new program

  ## Returns

  `{new_state, new_program_idx}` tuple
  """
  @spec add_program(t(), Types.candidate(), [Types.program_idx()], Types.sparse_scores()) ::
          {t(), Types.program_idx()}
  def add_program(state, new_candidate, parent_program_ids, val_scores) do
    new_idx = length(state.program_candidates)

    # Update Pareto fronts for all scored validation examples
    {new_pareto_front, new_pareto_programs} =
      Enum.reduce(
        val_scores,
        {state.pareto_front_valset, state.program_at_pareto_front_valset},
        fn {val_id, score}, {fronts, programs} ->
          update_pareto_front_for_val(fronts, programs, val_id, score, new_idx)
        end
      )

    new_state = %{
      state
      | program_candidates: state.program_candidates ++ [new_candidate],
        parent_program_for_candidate: state.parent_program_for_candidate ++ [parent_program_ids],
        prog_candidate_val_subscores: state.prog_candidate_val_subscores ++ [val_scores],
        pareto_front_valset: new_pareto_front,
        program_at_pareto_front_valset: new_pareto_programs,
        named_predictor_id_to_update_next_for_program_candidate:
          state.named_predictor_id_to_update_next_for_program_candidate ++ [0],
        num_full_ds_evals: state.num_full_ds_evals + 1,
        total_num_evals: state.total_num_evals + map_size(val_scores),
        num_metric_calls_by_discovery:
          state.num_metric_calls_by_discovery ++ [state.total_num_evals]
    }

    {new_state, new_idx}
  end

  @doc """
  Get average score for a program across evaluated validation examples.

  ## Returns

  `{average_score, count}` tuple
  """
  @spec get_program_score(t(), Types.program_idx()) :: {float(), non_neg_integer()}
  def get_program_score(state, program_idx) do
    scores = Enum.at(state.prog_candidate_val_subscores, program_idx, %{})

    if map_size(scores) == 0 do
      {0.0, 0}
    else
      score_values = Map.values(scores)
      avg = Enum.sum(score_values) / length(score_values)
      {avg, length(score_values)}
    end
  end

  # Private helper to update Pareto front for a single validation example
  defp update_pareto_front_for_val(fronts, programs, val_id, score, program_idx) do
    prev_score = Map.get(fronts, val_id, :neg_infinity)

    cond do
      score > prev_score ->
        # New best score - replace front
        {
          Map.put(fronts, val_id, score),
          Map.put(programs, val_id, MapSet.new([program_idx]))
        }

      score == prev_score ->
        # Tie - add to front
        {
          fronts,
          Map.update(programs, val_id, MapSet.new([program_idx]), &MapSet.put(&1, program_idx))
        }

      true ->
        # Worse score - no update
        {fronts, programs}
    end
  end
end
