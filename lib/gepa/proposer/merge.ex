defmodule GEPA.Proposer.Merge do
  @moduledoc """
  Merge Proposer for GEPA optimization.

  Implements genealogy-based candidate merging:
  - Finds merge candidates among Pareto front dominators
  - Attempts merges via common ancestor selection
  - Evaluates merged candidates on subsamples
  - Returns proposals when merges improve over parents

  ## Usage

      proposer = GEPA.Proposer.Merge.new(
        valset: valset,
        evaluator: evaluator_fn,
        use_merge: true,
        max_merge_invocations: 5
      )

      {proposal, new_proposer} = GEPA.Proposer.Merge.propose(proposer, state)
  """

  alias GEPA.{CandidateProposal, DataLoader, State}
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

  @doc """
  Creates a new Merge Proposer.

  ## Options
    - `:valset` - Validation data loader (required)
    - `:evaluator` - Function to evaluate candidates (required)
    - `:use_merge` - Enable/disable merge proposer (default: true)
    - `:max_merge_invocations` - Maximum number of merge attempts (required)
    - `:val_overlap_floor` - Minimum common validation IDs (default: 5)
    - `:seed` - Random seed (default: 0)

  ## Examples

      proposer = Merge.new(
        valset: valset,
        evaluator: fn batch, candidate -> {outputs, scores} end,
        max_merge_invocations: 5
      )
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    valset = Keyword.fetch!(opts, :valset)
    evaluator = Keyword.fetch!(opts, :evaluator)
    max_merge_invocations = Keyword.fetch!(opts, :max_merge_invocations)

    use_merge = Keyword.get(opts, :use_merge, true)
    val_overlap_floor = Keyword.get(opts, :val_overlap_floor, 5)
    seed = Keyword.get(opts, :seed, 0)

    # Validate
    if val_overlap_floor <= 0 do
      raise ArgumentError, "val_overlap_floor should be a positive integer"
    end

    %__MODULE__{
      valset: valset,
      evaluator: evaluator,
      use_merge: use_merge,
      max_merge_invocations: max_merge_invocations,
      val_overlap_floor: val_overlap_floor,
      seed: seed,
      merges_due: 0,
      total_merges_tested: 0,
      merges_performed: {[], []},
      last_iter_found_new_program: false
    }
  end

  @doc """
  Schedules a merge attempt if conditions are met.

  Increments merges_due counter when:
  - Merge is enabled
  - Budget not exhausted

  Called by Engine after each iteration that finds a new program.
  """
  @spec schedule_if_needed(t()) :: t()
  def schedule_if_needed(%__MODULE__{} = proposer) do
    if proposer.use_merge and proposer.total_merges_tested < proposer.max_merge_invocations do
      %{proposer | merges_due: proposer.merges_due + 1}
    else
      proposer
    end
  end

  @doc """
  Selects evaluation subsample for merged program.

  Balances sample selection across three categories:
  1. Where parent1 scores higher
  2. Where parent2 scores higher
  3. Where scores are equal

  This provides a representative sample for quick merge evaluation.
  """
  @spec select_eval_subsample_for_merged_program(
          t(),
          scores1 :: %{term() => float()},
          scores2 :: %{term() => float()},
          keyword()
        ) :: [term()]
  def select_eval_subsample_for_merged_program(proposer, scores1, scores2, opts \\ []) do
    num_subsample_ids = Keyword.get(opts, :num_subsample_ids, 5)

    # Find common validation IDs
    common_ids =
      MapSet.intersection(
        MapSet.new(Map.keys(scores1)),
        MapSet.new(Map.keys(scores2))
      )
      |> MapSet.to_list()

    # Partition by score differences
    p1 = Enum.filter(common_ids, fn id -> scores1[id] > scores2[id] end)
    p2 = Enum.filter(common_ids, fn id -> scores2[id] > scores1[id] end)
    p3 = Enum.filter(common_ids, fn id -> id not in p1 and id not in p2 end)

    # Take balanced samples
    n_each = max(1, ceil(num_subsample_ids / 3))

    selected =
      [p1, p2, p3]
      |> Enum.reduce([], fn bucket, acc ->
        if length(acc) >= num_subsample_ids do
          acc
        else
          available = Enum.filter(bucket, &(&1 not in acc))
          take = [length(available), n_each, num_subsample_ids - length(acc)] |> Enum.min()

          if take > 0 do
            # Use seed for determinism
            :rand.seed(:exsss, {proposer.seed, length(acc), 0})
            sampled = Enum.take_random(available, take)
            acc ++ sampled
          else
            acc
          end
        end
      end)

    # Fill remaining if needed
    remaining = num_subsample_ids - length(selected)

    selected =
      if remaining > 0 do
        unused = Enum.filter(common_ids, &(&1 not in selected))

        if length(unused) >= remaining do
          :rand.seed(:exsss, {proposer.seed, length(selected), 1})
          selected ++ Enum.take_random(unused, remaining)
        else
          # Need to allow repeats
          :rand.seed(:exsss, {proposer.seed, length(selected), 2})
          selected ++ Enum.take_random(common_ids, remaining)
        end
      else
        selected
      end

    Enum.take(selected, num_subsample_ids)
  end

  @doc """
  Proposes a merged candidate if conditions are met.

  Returns `{proposal, new_proposer}` where proposal may be nil if:
  - Merge not enabled
  - No merge scheduled
  - No valid merge candidates found
  - Merge doesn't improve over parents

  ## Parameters
    - `proposer` - Merge proposer state
    - `state` - Current GEPA state

  ## Returns
    - `{%CandidateProposal{}, proposer}` if merge successful
    - `{nil, proposer}` if no merge performed
  """
  @spec propose(t(), State.t()) :: {CandidateProposal.t() | nil, t()}
  def propose(%__MODULE__{} = proposer, %State{} = state) do
    # Check if merge should be attempted
    should_merge =
      proposer.use_merge and
        proposer.last_iter_found_new_program and
        proposer.merges_due > 0

    if not should_merge do
      {nil, proposer}
    else
      attempt_merge(proposer, state)
    end
  end

  defp attempt_merge(proposer, state) do
    # Calculate aggregate scores for all programs
    program_scores = calculate_aggregate_scores(state)

    # Find dominator programs on Pareto front
    merge_candidates =
      GEPA.Utils.find_dominator_programs(
        state.program_at_pareto_front_valset,
        program_scores
      )

    # Try to find a valid merge
    merge_result =
      attempt_merge_by_common_predictors(
        proposer,
        merge_candidates,
        state
      )

    case merge_result do
      nil ->
        {nil, proposer}

      {merged_candidate, id1, id2, ancestor, subsample_ids} ->
        # Evaluate merged candidate on subsample
        batch = DataLoader.fetch(proposer.valset, subsample_ids)
        {_outputs, scores} = proposer.evaluator.(batch, merged_candidate)

        # Get parent scores on same subsample
        parent1_scores = Enum.map(subsample_ids, &state.prog_candidate_val_subscores[id1][&1])
        parent2_scores = Enum.map(subsample_ids, &state.prog_candidate_val_subscores[id2][&1])

        # Create proposal
        proposal = %CandidateProposal{
          candidate: merged_candidate,
          parent_program_ids: [id1, id2],
          subsample_indices: subsample_ids,
          subsample_scores_before: [Enum.sum(parent1_scores), Enum.sum(parent2_scores)],
          subsample_scores_after: scores,
          tag: "merge",
          metadata: %{ancestor: ancestor}
        }

        # Update proposer state
        new_proposer = %{
          proposer
          | merges_due: proposer.merges_due - 1,
            total_merges_tested: proposer.total_merges_tested + 1
        }

        # Record merge attempt
        {used_triplets, used_descriptors} = new_proposer.merges_performed

        new_proposer = %{
          new_proposer
          | merges_performed: {[{id1, id2, ancestor} | used_triplets], used_descriptors}
        }

        {proposal, new_proposer}
    end
  end

  defp attempt_merge_by_common_predictors(proposer, merge_candidates, state) do
    if length(merge_candidates) < 2 do
      nil
    else
      # Calculate aggregate scores
      program_scores = calculate_aggregate_scores(state)

      # Try to find a common ancestor pair
      case MergeUtils.find_common_ancestor_pair(
             merge_candidates,
             state.parent_program_for_candidate,
             program_scores
           ) do
        nil ->
          nil

        {id1, id2, ancestor} ->
          # Check for validation overlap
          if has_val_support_overlap?(proposer, state, id1, id2) do
            # Filter ancestors
            filtered =
              MergeUtils.filter_ancestors(
                id1,
                id2,
                [ancestor],
                proposer.merges_performed,
                program_scores,
                state.program_candidates
              )

            if ancestor in filtered do
              # Perform the merge
              merged_candidate = merge_predictors(state, ancestor, id1, id2)

              # Select subsample for evaluation
              subsample_ids =
                select_eval_subsample_for_merged_program(
                  proposer,
                  state.prog_candidate_val_subscores[id1],
                  state.prog_candidate_val_subscores[id2],
                  num_subsample_ids: 5
                )

              {merged_candidate, id1, id2, ancestor, subsample_ids}
            else
              nil
            end
          else
            nil
          end
      end
    end
  end

  defp has_val_support_overlap?(proposer, state, id1, id2) do
    common_ids =
      MapSet.intersection(
        MapSet.new(Map.keys(state.prog_candidate_val_subscores[id1])),
        MapSet.new(Map.keys(state.prog_candidate_val_subscores[id2]))
      )

    MapSet.size(common_ids) >= proposer.val_overlap_floor
  end

  # Calculate aggregate validation scores for all programs
  defp calculate_aggregate_scores(state) do
    # prog_candidate_val_subscores is a list indexed by program ID
    # Each element is a map of val_id => score
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {score_map, idx} ->
      {avg, _count} = State.get_program_score(state, idx)
      {idx, avg}
    end)
    |> Enum.into(%{})
  end

  defp merge_predictors(state, ancestor, id1, id2) do
    ancestor_candidate = Enum.at(state.program_candidates, ancestor)
    id1_candidate = Enum.at(state.program_candidates, id1)
    id2_candidate = Enum.at(state.program_candidates, id2)

    # Calculate scores for comparison
    {id1_score, _} = State.get_program_score(state, id1)
    {id2_score, _} = State.get_program_score(state, id2)

    # Start with ancestor's predictors
    merged = ancestor_candidate

    # For each component, intelligently select from parents
    Enum.reduce(Map.keys(ancestor_candidate), merged, fn component_name, acc ->
      anc_val = ancestor_candidate[component_name]
      id1_val = id1_candidate[component_name]
      id2_val = id2_candidate[component_name]

      # Merging logic:
      cond do
        # If one child kept ancestor's value, try the other's change
        anc_val == id1_val and id1_val != id2_val ->
          Map.put(acc, component_name, id2_val)

        anc_val == id2_val and id1_val != id2_val ->
          Map.put(acc, component_name, id1_val)

        # Both differ from ancestor: pick higher-scoring parent
        anc_val != id1_val and anc_val != id2_val ->
          if id1_score > id2_score do
            Map.put(acc, component_name, id1_val)
          else
            Map.put(acc, component_name, id2_val)
          end

        # All same, or id1 == id2: keep id1's value
        true ->
          Map.put(acc, component_name, id1_val)
      end
    end)
  end
end
