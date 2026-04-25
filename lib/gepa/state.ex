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
          prog_candidate_objective_scores: [%{String.t() => float()}],

          # Pareto front tracking
          frontier_type: :instance | :objective | :hybrid | :cartesian,
          pareto_front_valset: %{Types.data_id() => float()},
          program_at_pareto_front_valset: Types.pareto_fronts(),
          objective_pareto_front: %{String.t() => float()},
          program_at_pareto_front_objectives: %{String.t() => MapSet.t(Types.program_idx())},
          pareto_front_cartesian: %{{Types.data_id(), String.t()} => float()},
          program_at_pareto_front_cartesian: %{
            {Types.data_id(), String.t()} => MapSet.t(Types.program_idx())
          },

          # Component metadata
          list_of_named_predictors: [String.t()],
          named_predictor_id_to_update_next_for_program_candidate: [non_neg_integer()],

          # Iteration tracking
          i: integer(),
          num_full_ds_evals: non_neg_integer(),
          total_num_evals: non_neg_integer(),
          num_metric_calls_by_discovery: [non_neg_integer()],

          # Trace and metadata
          full_program_trace: [map()],
          best_outputs_valset: %{Types.data_id() => [{Types.program_idx(), term()}]} | nil,
          evaluation_cache: term() | nil,
          adapter_state: map(),
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
    prog_candidate_objective_scores: [],
    frontier_type: :instance,
    objective_pareto_front: %{},
    program_at_pareto_front_objectives: %{},
    pareto_front_cartesian: %{},
    program_at_pareto_front_cartesian: %{},
    named_predictor_id_to_update_next_for_program_candidate: [],
    i: -1,
    num_full_ds_evals: 1,
    total_num_evals: 0,
    num_metric_calls_by_discovery: [0],
    full_program_trace: [],
    best_outputs_valset: nil,
    evaluation_cache: nil,
    adapter_state: %{},
    validation_schema_version: 5
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
  @spec new(Types.candidate(), GEPA.EvaluationBatch.t(), [Types.data_id()], Keyword.t()) :: t()
  def new(seed_candidate, eval_batch, valset_ids, opts \\ []) do
    frontier_type = Keyword.get(opts, :frontier_type, :instance)
    objective_scores_by_val_id = objective_scores_by_val_id(eval_batch, valset_ids)
    validate_frontier_objective_scores!(frontier_type, objective_scores_by_val_id)

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

    objective_scores = aggregate_objective_scores(objective_scores_by_val_id)

    {cartesian_front, cartesian_programs} =
      cartesian_frontier(objective_scores_by_val_id, frontier_type, 0)

    best_outputs =
      if Keyword.get(opts, :track_best_outputs, false) do
        valset_ids
        |> Enum.zip(eval_batch.outputs)
        |> Map.new(fn {val_id, output} -> {val_id, [{0, output}]} end)
      end

    %__MODULE__{
      program_candidates: [seed_candidate],
      parent_program_for_candidate: [[nil]],
      prog_candidate_val_subscores: [seed_scores],
      prog_candidate_objective_scores: [objective_scores],
      frontier_type: frontier_type,
      pareto_front_valset: pareto_front,
      program_at_pareto_front_valset: program_at_pareto_front,
      objective_pareto_front: objective_scores,
      program_at_pareto_front_objectives:
        Map.new(objective_scores, fn {objective, _score} -> {objective, MapSet.new([0])} end),
      pareto_front_cartesian: cartesian_front,
      program_at_pareto_front_cartesian: cartesian_programs,
      list_of_named_predictors: component_names,
      named_predictor_id_to_update_next_for_program_candidate: [0],
      i: -1,
      num_full_ds_evals: 1,
      total_num_evals: eval_batch.num_metric_calls || length(valset_ids),
      num_metric_calls_by_discovery: [0],
      full_program_trace: [],
      best_outputs_valset: best_outputs,
      evaluation_cache: Keyword.get(opts, :evaluation_cache),
      adapter_state: Keyword.get(opts, :adapter_state, %{}),
      validation_schema_version: 5
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
  @spec add_program(
          t(),
          Types.candidate(),
          [Types.program_idx()],
          Types.sparse_scores(),
          Keyword.t()
        ) ::
          {t(), Types.program_idx()}
  def add_program(state, new_candidate, parent_program_ids, val_scores, opts \\ []) do
    new_idx = length(state.program_candidates)
    objective_scores_by_val_id = Keyword.get(opts, :objective_scores_by_val_id)
    validate_frontier_objective_scores!(state.frontier_type, objective_scores_by_val_id)
    objective_scores = aggregate_objective_scores(objective_scores_by_val_id)
    outputs_by_val_id = Keyword.get(opts, :outputs_by_val_id, %{})
    metric_calls = Keyword.get(opts, :metric_calls, map_size(val_scores))

    # Update Pareto fronts for all scored validation examples
    {new_pareto_front, new_pareto_programs, best_outputs} =
      Enum.reduce(
        val_scores,
        {state.pareto_front_valset, state.program_at_pareto_front_valset,
         state.best_outputs_valset},
        fn {val_id, score}, {fronts, programs, best_outputs_acc} ->
          output = Map.get(outputs_by_val_id, val_id)

          {fronts, programs, best_outputs_acc} =
            update_pareto_front_for_val(
              fronts,
              programs,
              best_outputs_acc,
              val_id,
              score,
              new_idx,
              output
            )

          {fronts, programs, best_outputs_acc}
        end
      )

    {objective_front, objective_programs} =
      update_objective_pareto_front(
        state.objective_pareto_front,
        state.program_at_pareto_front_objectives,
        objective_scores,
        new_idx
      )

    {cartesian_front, cartesian_programs} =
      update_cartesian_pareto_front(
        state.pareto_front_cartesian,
        state.program_at_pareto_front_cartesian,
        objective_scores_by_val_id,
        state.frontier_type,
        new_idx
      )

    next_component_pointer =
      parent_program_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Enum.at(state.named_predictor_id_to_update_next_for_program_candidate, &1, 0))
      |> Enum.max(fn -> 0 end)

    new_state = %{
      state
      | program_candidates: state.program_candidates ++ [new_candidate],
        parent_program_for_candidate: state.parent_program_for_candidate ++ [parent_program_ids],
        prog_candidate_val_subscores: state.prog_candidate_val_subscores ++ [val_scores],
        prog_candidate_objective_scores:
          state.prog_candidate_objective_scores ++ [objective_scores],
        pareto_front_valset: new_pareto_front,
        program_at_pareto_front_valset: new_pareto_programs,
        objective_pareto_front: objective_front,
        program_at_pareto_front_objectives: objective_programs,
        pareto_front_cartesian: cartesian_front,
        program_at_pareto_front_cartesian: cartesian_programs,
        best_outputs_valset: best_outputs,
        named_predictor_id_to_update_next_for_program_candidate:
          state.named_predictor_id_to_update_next_for_program_candidate ++
            [next_component_pointer],
        num_full_ds_evals: state.num_full_ds_evals + 1,
        total_num_evals: state.total_num_evals + metric_calls,
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
  defp objective_scores_by_val_id(%GEPA.EvaluationBatch{objective_scores: nil}, _valset_ids),
    do: nil

  defp objective_scores_by_val_id(%GEPA.EvaluationBatch{objective_scores: scores}, valset_ids)
       when is_list(scores) do
    valset_ids
    |> Enum.zip(scores)
    |> Map.new()
  end

  defp aggregate_objective_scores(nil), do: %{}

  defp aggregate_objective_scores(objective_scores_by_val_id)
       when objective_scores_by_val_id == %{},
       do: %{}

  defp aggregate_objective_scores(objective_scores_by_val_id)
       when is_map(objective_scores_by_val_id) do
    {totals, counts} =
      Enum.reduce(objective_scores_by_val_id, {%{}, %{}}, fn {_val_id, scores},
                                                             {totals, counts} ->
        Enum.reduce(scores, {totals, counts}, fn {objective, score}, {totals_acc, counts_acc} ->
          {
            Map.update(totals_acc, objective, score, &(&1 + score)),
            Map.update(counts_acc, objective, 1, &(&1 + 1))
          }
        end)
      end)

    Map.new(totals, fn {objective, total} -> {objective, total / counts[objective]} end)
  end

  defp validate_frontier_objective_scores!(frontier_type, objective_scores_by_val_id)
       when frontier_type in [:objective, :hybrid, :cartesian] do
    if objective_scores_by_val_id in [nil, %{}] do
      raise ArgumentError,
            "frontier_type=#{inspect(frontier_type)} requires objective_scores to be provided"
    end
  end

  defp validate_frontier_objective_scores!(_frontier_type, _objective_scores_by_val_id), do: :ok

  defp cartesian_frontier(objective_scores_by_val_id, :cartesian, program_idx)
       when is_map(objective_scores_by_val_id) do
    Enum.reduce(objective_scores_by_val_id, {%{}, %{}}, fn {val_id, scores}, {fronts, programs} ->
      Enum.reduce(scores, {fronts, programs}, fn {objective, score}, {fronts_acc, programs_acc} ->
        key = {val_id, objective}
        {Map.put(fronts_acc, key, score), Map.put(programs_acc, key, MapSet.new([program_idx]))}
      end)
    end)
  end

  defp cartesian_frontier(_objective_scores_by_val_id, _frontier_type, _program_idx),
    do: {%{}, %{}}

  defp update_pareto_front_for_val(
         fronts,
         programs,
         best_outputs,
         val_id,
         score,
         program_idx,
         output
       ) do
    prev_score = Map.get(fronts, val_id, :neg_infinity)

    cond do
      score > prev_score ->
        # New best score - replace front
        {
          Map.put(fronts, val_id, score),
          Map.put(programs, val_id, MapSet.new([program_idx])),
          put_best_output(best_outputs, val_id, program_idx, output, :replace)
        }

      score == prev_score ->
        # Tie - add to front
        {
          fronts,
          Map.update(programs, val_id, MapSet.new([program_idx]), &MapSet.put(&1, program_idx)),
          put_best_output(best_outputs, val_id, program_idx, output, :append)
        }

      true ->
        # Worse score - no update
        {fronts, programs, best_outputs}
    end
  end

  defp put_best_output(nil, _val_id, _program_idx, _output, _mode), do: nil
  defp put_best_output(best_outputs, _val_id, _program_idx, nil, _mode), do: best_outputs

  defp put_best_output(best_outputs, val_id, program_idx, output, :replace) do
    Map.put(best_outputs, val_id, [{program_idx, output}])
  end

  defp put_best_output(best_outputs, val_id, program_idx, output, :append) do
    Map.update(best_outputs, val_id, [{program_idx, output}], &(&1 ++ [{program_idx, output}]))
  end

  defp update_objective_pareto_front(fronts, programs, objective_scores, program_idx) do
    Enum.reduce(objective_scores, {fronts, programs}, fn {objective, score},
                                                         {fronts_acc, programs_acc} ->
      prev_score = Map.get(fronts_acc, objective, :neg_infinity)

      cond do
        score > prev_score ->
          {Map.put(fronts_acc, objective, score),
           Map.put(programs_acc, objective, MapSet.new([program_idx]))}

        score == prev_score ->
          {fronts_acc,
           Map.update(
             programs_acc,
             objective,
             MapSet.new([program_idx]),
             &MapSet.put(&1, program_idx)
           )}

        true ->
          {fronts_acc, programs_acc}
      end
    end)
  end

  defp update_cartesian_pareto_front(
         fronts,
         programs,
         objective_scores_by_val_id,
         :cartesian,
         program_idx
       )
       when is_map(objective_scores_by_val_id) do
    Enum.reduce(objective_scores_by_val_id, {fronts, programs}, fn {val_id, objective_scores},
                                                                   acc ->
      Enum.reduce(objective_scores, acc, fn {objective, score}, inner_acc ->
        update_cartesian_objective(inner_acc, {val_id, objective}, score, program_idx)
      end)
    end)
  end

  defp update_cartesian_pareto_front(
         fronts,
         programs,
         _objective_scores_by_val_id,
         _frontier_type,
         _program_idx
       ) do
    {fronts, programs}
  end

  defp update_cartesian_objective({fronts, programs}, key, score, program_idx) do
    prev_score = Map.get(fronts, key, :neg_infinity)

    cond do
      score > prev_score ->
        {Map.put(fronts, key, score), Map.put(programs, key, MapSet.new([program_idx]))}

      score == prev_score ->
        {fronts,
         Map.update(programs, key, MapSet.new([program_idx]), &MapSet.put(&1, program_idx))}

      true ->
        {fronts, programs}
    end
  end
end
