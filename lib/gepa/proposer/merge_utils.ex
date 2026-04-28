defmodule GEPA.Proposer.MergeUtils do
  @moduledoc """
  Genealogy and triplet-selection helpers for the merge proposer.
  """

  @doc "Return all ancestors of `program`, excluding the program itself."
  @spec get_ancestors(non_neg_integer(), map() | list()) :: [non_neg_integer()]
  def get_ancestors(program, parent_list) do
    do_get_ancestors(program, parent_list, [])
  end

  @spec do_get_ancestors(non_neg_integer(), map() | list(), [non_neg_integer()]) ::
          [non_neg_integer()]
  defp do_get_ancestors(program, parent_list, found) do
    parents = parents_for(parent_list, program)

    Enum.reduce(parents, found, fn
      nil, acc ->
        acc

      parent, acc ->
        if parent in acc do
          acc
        else
          do_get_ancestors(parent, parent_list, [parent | acc])
        end
    end)
  end

  defp parents_for(parent_list, program) when is_map(parent_list) do
    parent_list
    |> Map.get(program, [])
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp parents_for(parent_list, program) when is_list(parent_list) do
    parent_list
    |> Enum.at(program, [])
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  @doc "Return true when a common-ancestor triplet can produce a useful merged predictor."
  @spec does_triplet_have_desirable_predictors?(
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          boolean()
  def does_triplet_have_desirable_predictors?(program_candidates, ancestor, id1, id2) do
    with ancestor_candidate when is_map(ancestor_candidate) <-
           Enum.at(program_candidates, ancestor),
         id1_candidate when is_map(id1_candidate) <- Enum.at(program_candidates, id1),
         id2_candidate when is_map(id2_candidate) <- Enum.at(program_candidates, id2) do
      ancestor_candidate
      |> Map.keys()
      |> Enum.any?(fn component_name ->
        anc_val = Map.get(ancestor_candidate, component_name)
        id1_val = Map.get(id1_candidate, component_name)
        id2_val = Map.get(id2_candidate, component_name)

        (anc_val == id1_val or anc_val == id2_val) and id1_val != id2_val
      end)
    else
      _ -> false
    end
  end

  @doc "Filter common ancestors to official-compatible merge triplet candidates."
  @spec filter_ancestors(
          non_neg_integer(),
          non_neg_integer(),
          [non_neg_integer()],
          {[tuple()], [tuple()]},
          map(),
          [map()]
        ) ::
          [non_neg_integer()]
  def filter_ancestors(id1, id2, common_ancestors, merges_performed, scores, program_candidates) do
    {used_triplets, _used_descriptors} = merges_performed
    {left, right} = ordered_pair(id1, id2)

    common_ancestors
    |> Enum.uniq()
    |> Enum.filter(fn ancestor ->
      triplet_used? =
        {left, right, ancestor} in used_triplets or {id1, id2, ancestor} in used_triplets

      ancestor_score = score_for(scores, ancestor)
      id1_score = score_for(scores, id1)
      id2_score = score_for(scores, id2)

      ancestor_not_better? = ancestor_score <= id1_score and ancestor_score <= id2_score

      useful? = does_triplet_have_desirable_predictors?(program_candidates, ancestor, id1, id2)

      not triplet_used? and ancestor_not_better? and useful?
    end)
  end

  @doc "Find a non-ancestor pair of programs with a valid common ancestor."
  @spec find_common_ancestor_pair([non_neg_integer()], map() | list(), map(), keyword()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  def find_common_ancestor_pair(program_indexes, parent_list, scores, opts \\ []) do
    program_indexes
    |> Enum.uniq()
    |> candidate_pairs(scores)
    |> Enum.find_value(fn {id1, id2} ->
      ancestors1 = get_ancestors(id1, parent_list)
      ancestors2 = get_ancestors(id2, parent_list)

      if id1 not in ancestors2 and id2 not in ancestors1 do
        find_valid_triplet(id1, id2, ancestors1, ancestors2, scores, opts)
      end
    end)
  end

  defp find_valid_triplet(id1, id2, ancestors1, ancestors2, scores, opts) do
    common =
      MapSet.intersection(MapSet.new(ancestors1), MapSet.new(ancestors2))
      |> MapSet.to_list()

    filtered = maybe_filter_common_ancestors(common, id1, id2, scores, opts)

    case select_ancestor(filtered, scores) do
      nil -> nil
      ancestor -> {id1, id2, ancestor}
    end
  end

  @doc "Canonical tuple for recording a merge triplet irrespective of pair ordering."
  @spec canonical_triplet(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: tuple()
  def canonical_triplet(id1, id2, ancestor) do
    {left, right} = ordered_pair(id1, id2)
    {left, right, ancestor}
  end

  defp candidate_pairs(program_indexes, scores) do
    for {id1, idx} <- Enum.with_index(program_indexes),
        id2 <- Enum.drop(program_indexes, idx + 1) do
      {id1, id2}
    end
    |> Enum.sort_by(fn {id1, id2} ->
      total_score = score_for(scores, id1) + score_for(scores, id2)
      {-total_score, min(id1, id2), max(id1, id2)}
    end)
  end

  defp maybe_filter_common_ancestors(common, id1, id2, scores, opts) do
    program_candidates = Keyword.get(opts, :program_candidates)

    if is_list(program_candidates) do
      __MODULE__.filter_ancestors(
        id1,
        id2,
        common,
        Keyword.get(opts, :merges_performed, {[], []}),
        scores,
        program_candidates
      )
    else
      common
    end
  end

  defp select_ancestor([], _scores), do: nil

  defp select_ancestor(ancestors, scores) do
    Enum.max_by(ancestors, fn ancestor -> {score_for(scores, ancestor), -ancestor} end)
  end

  defp score_for(scores, idx) when is_map(scores), do: Map.get(scores, idx, 0.0)
  defp score_for(scores, idx) when is_list(scores), do: Enum.at(scores, idx, 0.0) || 0.0
  defp score_for(_scores, _idx), do: 0.0

  defp ordered_pair(id1, id2) when id1 <= id2, do: {id1, id2}
  defp ordered_pair(id1, id2), do: {id2, id1}
end
