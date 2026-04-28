defmodule GEPA.Proposer.Merge do
  @moduledoc """
  Official-compatible merge proposer.

  Merge is scheduled after an accepted reflective mutation. The proposer finds
  two Pareto-front programs with a useful common ancestor, merges component
  changes relative to that ancestor, and evaluates the merged candidate on a
  balanced validation subsample. Counter consumption and final acceptance are
  handled by the engine, matching the Python implementation.
  """

  alias GEPA.{CandidateProposal, DataLoader, State}
  alias GEPA.CandidateProposal.SubsampleEvaluation
  alias GEPA.Proposer.MergeUtils

  defstruct [
    :valset,
    :evaluator,
    :use_merge,
    :max_merge_invocations,
    :val_overlap_floor,
    :seed,
    :merges_due,
    :total_merges_tested,
    :merges_performed,
    :last_iter_found_new_program
  ]

  @type t :: %__MODULE__{
          valset: DataLoader.t(),
          evaluator: function(),
          use_merge: boolean(),
          max_merge_invocations: non_neg_integer(),
          val_overlap_floor: pos_integer(),
          seed: integer(),
          merges_due: non_neg_integer(),
          total_merges_tested: non_neg_integer(),
          merges_performed: {[tuple()], [tuple()]},
          last_iter_found_new_program: boolean()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    valset = Keyword.fetch!(opts, :valset)
    evaluator = Keyword.fetch!(opts, :evaluator)
    max_merge_invocations = Keyword.fetch!(opts, :max_merge_invocations)
    val_overlap_floor = Keyword.get(opts, :val_overlap_floor, 5)

    if not (is_integer(val_overlap_floor) and val_overlap_floor > 0) do
      raise ArgumentError, "val_overlap_floor should be a positive integer"
    end

    %__MODULE__{
      valset: valset,
      evaluator: evaluator,
      use_merge: Keyword.get(opts, :use_merge, true),
      max_merge_invocations: max_merge_invocations,
      val_overlap_floor: val_overlap_floor,
      seed: Keyword.get(opts, :seed, 0),
      merges_due: 0,
      total_merges_tested: 0,
      merges_performed: {[], []},
      last_iter_found_new_program: false
    }
  end

  @spec schedule_if_needed(t()) :: t()
  def schedule_if_needed(%__MODULE__{} = proposer) do
    if proposer.use_merge and proposer.total_merges_tested < proposer.max_merge_invocations do
      %{proposer | merges_due: proposer.merges_due + 1}
    else
      proposer
    end
  end

  @spec select_eval_subsample_for_merged_program(t(), map(), map(), keyword()) :: [term()]
  def select_eval_subsample_for_merged_program(
        %__MODULE__{} = proposer,
        scores1,
        scores2,
        opts \\ []
      ) do
    num_subsample_ids = Keyword.get(opts, :num_subsample_ids, 5)

    common_ids =
      scores1
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Map.keys(scores2)))
      |> MapSet.to_list()
      |> Enum.sort()

    cond do
      num_subsample_ids <= 0 ->
        []

      common_ids == [] ->
        []

      true ->
        buckets = partition_common_ids(common_ids, scores1, scores2)
        n_each = max(1, div(num_subsample_ids + 2, 3))

        selected =
          buckets
          |> Enum.with_index()
          |> Enum.reduce([], fn {bucket, bucket_idx}, acc ->
            remaining = num_subsample_ids - length(acc)

            if remaining <= 0 do
              acc
            else
              available = Enum.reject(bucket, &(&1 in acc))
              take = min(min(length(available), n_each), remaining)
              acc ++ deterministic_take(available, take, {proposer.seed, bucket_idx, :bucket})
            end
          end)

        remaining = num_subsample_ids - length(selected)

        fill =
          cond do
            remaining <= 0 ->
              []

            length(Enum.reject(common_ids, &(&1 in selected))) >= remaining ->
              common_ids
              |> Enum.reject(&(&1 in selected))
              |> deterministic_take(remaining, {proposer.seed, length(selected), :fill})

            true ->
              sample_with_replacement(
                common_ids,
                remaining,
                {proposer.seed, length(selected), :repeat}
              )
          end

        Enum.take(selected ++ fill, num_subsample_ids)
    end
  end

  @spec propose(t(), State.t()) :: {CandidateProposal.t() | nil, t()}
  def propose(%__MODULE__{} = proposer, %State{} = state) do
    should_merge? =
      proposer.use_merge and proposer.last_iter_found_new_program and proposer.merges_due > 0 and
        proposer.total_merges_tested < proposer.max_merge_invocations

    if should_merge? do
      attempt_merge(proposer, state)
    else
      {nil, proposer}
    end
  end

  defp attempt_merge(proposer, state) do
    program_scores = calculate_aggregate_scores(state)

    merge_candidates =
      state
      |> State.get_pareto_front_mapping()
      |> GEPA.Utils.find_dominator_programs(program_scores)

    if length(merge_candidates) < 2 do
      {nil, proposer}
    else
      with {id1, id2, ancestor} <-
             MergeUtils.find_common_ancestor_pair(
               merge_candidates,
               state.parent_program_for_candidate,
               program_scores,
               merges_performed: proposer.merges_performed,
               program_candidates: state.program_candidates
             ),
           true <- has_val_support_overlap?(proposer, state, id1, id2),
           {merged_candidate, descriptor} <- merge_predictors(state, ancestor, id1, id2),
           false <- descriptor_already_used?(descriptor, proposer.merges_performed),
           subsample_ids when subsample_ids != [] <-
             select_eval_subsample_for_merged_program(
               proposer,
               Enum.at(state.prog_candidate_val_subscores, id1, %{}),
               Enum.at(state.prog_candidate_val_subscores, id2, %{}),
               num_subsample_ids: 5
             ),
           {:ok, outputs, scores, objective_scores} <-
             evaluate_merge(proposer, subsample_ids, merged_candidate) do
        parent1_scores = parent_scores(state, id1, subsample_ids)
        parent2_scores = parent_scores(state, id2, subsample_ids)

        proposal = %CandidateProposal{
          candidate: merged_candidate,
          parent_program_ids: [id1, id2],
          subsample_indices: subsample_ids,
          subsample_scores_before: [Enum.sum(parent1_scores), Enum.sum(parent2_scores)],
          subsample_scores_after: scores,
          eval_after: %SubsampleEvaluation{
            scores: scores,
            outputs: outputs,
            objective_scores: objective_scores
          },
          tag: "merge",
          metadata: %{
            ancestor: ancestor,
            outputs: outputs,
            objective_scores: objective_scores,
            num_metric_calls: length(scores),
            parent1_scores: parent1_scores,
            parent2_scores: parent2_scores
          }
        }

        proposer = record_merge_attempt(proposer, id1, id2, ancestor, descriptor)
        {proposal, proposer}
      else
        _ -> {nil, proposer}
      end
    end
  end

  defp partition_common_ids(common_ids, scores1, scores2) do
    parent1_better = Enum.filter(common_ids, &(Map.fetch!(scores1, &1) > Map.fetch!(scores2, &1)))
    parent2_better = Enum.filter(common_ids, &(Map.fetch!(scores2, &1) > Map.fetch!(scores1, &1)))

    equal_or_tied =
      Enum.filter(common_ids, fn id ->
        Map.fetch!(scores1, id) == Map.fetch!(scores2, id)
      end)

    [parent1_better, parent2_better, equal_or_tied]
  end

  defp deterministic_take(_items, count, _salt) when count <= 0, do: []

  defp deterministic_take(items, count, salt) do
    items
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, idx} -> :erlang.phash2({salt, item, idx}) end)
    |> Enum.take(count)
    |> Enum.map(&elem(&1, 0))
  end

  defp sample_with_replacement([], _count, _salt), do: []
  defp sample_with_replacement(_items, count, _salt) when count <= 0, do: []

  defp sample_with_replacement(items, count, salt) do
    shuffled = deterministic_take(items, length(items), salt)

    0..(count - 1)
    |> Enum.map(fn idx -> Enum.at(shuffled, rem(idx, length(shuffled))) end)
  end

  defp evaluate_merge(proposer, subsample_ids, candidate) do
    batch = DataLoader.fetch(proposer.valset, subsample_ids)

    case proposer.evaluator.(batch, candidate) do
      {outputs, scores} when is_list(outputs) and is_list(scores) ->
        {:ok, outputs, Enum.map(scores, &(&1 * 1.0)), nil}

      {outputs, scores, objective_scores} when is_list(outputs) and is_list(scores) ->
        {:ok, outputs, Enum.map(scores, &(&1 * 1.0)), objective_scores}

      {:ok, %GEPA.EvaluationBatch{} = eval_batch} ->
        {:ok, eval_batch.outputs, eval_batch.scores, eval_batch.objective_scores}

      %GEPA.EvaluationBatch{} = eval_batch ->
        {:ok, eval_batch.outputs, eval_batch.scores, eval_batch.objective_scores}

      other ->
        {:error, {:invalid_merge_evaluator_result, other}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp has_val_support_overlap?(proposer, state, id1, id2) do
    common_ids =
      MapSet.intersection(
        Enum.at(state.prog_candidate_val_subscores, id1, %{}) |> Map.keys() |> MapSet.new(),
        Enum.at(state.prog_candidate_val_subscores, id2, %{}) |> Map.keys() |> MapSet.new()
      )

    MapSet.size(common_ids) >= proposer.val_overlap_floor
  end

  defp calculate_aggregate_scores(state) do
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {_score_map, idx} ->
      {avg, _count} = State.get_program_score(state, idx)
      {idx, avg}
    end)
    |> Map.new()
  end

  defp parent_scores(state, parent_idx, subsample_ids) do
    score_map = Enum.at(state.prog_candidate_val_subscores, parent_idx, %{})
    Enum.map(subsample_ids, &Map.get(score_map, &1, 0.0))
  end

  defp merge_predictors(state, ancestor, id1, id2) do
    ancestor_candidate = Enum.at(state.program_candidates, ancestor)
    id1_candidate = Enum.at(state.program_candidates, id1)
    id2_candidate = Enum.at(state.program_candidates, id2)
    {id1_score, _} = State.get_program_score(state, id1)
    {id2_score, _} = State.get_program_score(state, id2)

    Enum.reduce(Map.keys(ancestor_candidate), {ancestor_candidate, []}, fn component_name,
                                                                           {merged, descriptor} ->
      anc_val = Map.get(ancestor_candidate, component_name)
      id1_val = Map.get(id1_candidate, component_name)
      id2_val = Map.get(id2_candidate, component_name)

      {selected_value, selected_from} =
        cond do
          anc_val == id1_val and id1_val != id2_val ->
            {id2_val, {component_name, id2}}

          anc_val == id2_val and id1_val != id2_val ->
            {id1_val, {component_name, id1}}

          anc_val != id1_val and anc_val != id2_val and id1_val != id2_val ->
            if id1_score > id2_score do
              {id1_val, {component_name, id1}}
            else
              {id2_val, {component_name, id2}}
            end

          true ->
            {id1_val, {component_name, :unchanged}}
        end

      {Map.put(merged, component_name, selected_value), [selected_from | descriptor]}
    end)
  end

  defp descriptor_already_used?(descriptor, {_used_triplets, used_descriptors}) do
    Enum.sort(descriptor) in used_descriptors
  end

  defp record_merge_attempt(proposer, id1, id2, ancestor, descriptor) do
    {used_triplets, used_descriptors} = proposer.merges_performed
    triplet = MergeUtils.canonical_triplet(id1, id2, ancestor)
    descriptor = Enum.sort(descriptor)

    %{
      proposer
      | merges_performed: {[triplet | used_triplets], [descriptor | used_descriptors]}
    }
  end
end
