defmodule GEPA.Proposer.MergeUtils do
  @moduledoc """
  Utility functions for the Merge Proposer.

  Handles genealogy tracking, ancestor detection, and merge candidate selection.
  """

  @doc """
  Gets all ancestors of a program by traversing the parent graph.

  ## Parameters
    - `program` - Program ID to find ancestors for
    - `parent_list` - Map of program_id => list of parent program IDs

  ## Returns
    - List of all ancestor program IDs (not including the program itself)

  ## Examples

      parent_list = %{
        0 => [],
        1 => [0],
        2 => [1],
        3 => [2]
      }

      get_ancestors(3, parent_list)
      # => [2, 1, 0]
  """
  @spec get_ancestors(
          program :: non_neg_integer(),
          parent_list :: %{non_neg_integer() => [non_neg_integer()]}
        ) :: [non_neg_integer()]
  def get_ancestors(program, parent_list) do
    do_get_ancestors(program, parent_list, [])
  end

  defp do_get_ancestors(program, parent_list, found) do
    parents = Map.get(parent_list, program, [])

    Enum.reduce(parents, found, fn parent, acc ->
      if Enum.member?(acc, parent) do
        # Already visited (cycle detection)
        acc
      else
        # Add this parent and recursively get its ancestors
        acc
        |> then(&[parent | &1])
        |> then(&do_get_ancestors(parent, parent_list, &1))
      end
    end)
  end

  @doc """
  Checks if a triplet (ancestor, id1, id2) has desirable predictors for merging.

  A triplet is desirable if at least one component (predictor) satisfies:
  - ancestor == id1 AND id1 != id2, OR
  - ancestor == id2 AND id1 != id2

  This means we can take the "improved" version from the child that differs.

  ## Parameters
    - `program_candidates` - List of candidate maps (component_name => text)
    - `ancestor` - Ancestor program index
    - `id1` - First descendant program index
    - `id2` - Second descendant program index

  ## Returns
    - `true` if at least one component has a useful difference
    - `false` if no useful merging opportunity exists
  """
  @spec does_triplet_have_desirable_predictors?(
          program_candidates :: [%{String.t() => String.t()}],
          ancestor :: non_neg_integer(),
          id1 :: non_neg_integer(),
          id2 :: non_neg_integer()
        ) :: boolean()
  def does_triplet_have_desirable_predictors?(program_candidates, ancestor, id1, id2) do
    ancestor_candidate = Enum.at(program_candidates, ancestor)
    id1_candidate = Enum.at(program_candidates, id1)
    id2_candidate = Enum.at(program_candidates, id2)

    # Get all component names
    component_names = Map.keys(ancestor_candidate)

    # Check if any component has a desirable pattern
    Enum.any?(component_names, fn comp_name ->
      anc_val = ancestor_candidate[comp_name]
      id1_val = id1_candidate[comp_name]
      id2_val = id2_candidate[comp_name]

      # Desirable if:
      # - ancestor == id1 AND id1 != id2 (can upgrade from id2)
      # - ancestor == id2 AND id1 != id2 (can upgrade from id1)
      (anc_val == id1_val or anc_val == id2_val) and id1_val != id2_val
    end)
  end

  @doc """
  Filters ancestors to find valid merge candidates.

  Removes ancestors that:
  1. Have already been used for merging this pair
  2. Have higher scores than descendants (shouldn't merge down)
  3. Don't have desirable predictors (no useful merge)

  ## Parameters
    - `id1` - First program ID
    - `id2` - Second program ID
    - `common_ancestors` - List of potential ancestor IDs
    - `merges_performed` - Tuple of {used_triplets, used_descriptors}
    - `scores` - Map of program_id => score
    - `program_candidates` - List of all candidate programs

  ## Returns
    - List of filtered, valid ancestors for merging
  """
  @spec filter_ancestors(
          id1 :: non_neg_integer(),
          id2 :: non_neg_integer(),
          common_ancestors :: [non_neg_integer()],
          merges_performed :: {[tuple()], [tuple()]},
          scores :: %{non_neg_integer() => float()},
          program_candidates :: [%{String.t() => String.t()}]
        ) :: [non_neg_integer()]
  def filter_ancestors(id1, id2, common_ancestors, merges_performed, scores, program_candidates) do
    {used_triplets, _used_descriptors} = merges_performed

    Enum.filter(common_ancestors, fn ancestor ->
      # Filter 1: Not already used
      triplet_used = {id1, id2, ancestor} in used_triplets

      # Filter 2: Ancestor score not higher than both descendants
      ancestor_score = Map.get(scores, ancestor, 0)
      id1_score = Map.get(scores, id1, 0)
      id2_score = Map.get(scores, id2, 0)
      ancestor_not_better = ancestor_score <= id1_score and ancestor_score <= id2_score

      # Filter 3: Has desirable predictors
      has_useful_predictors =
        does_triplet_have_desirable_predictors?(
          program_candidates,
          ancestor,
          id1,
          id2
        )

      not triplet_used and ancestor_not_better and has_useful_predictors
    end)
  end

  @doc """
  Finds a pair of programs with a common ancestor suitable for merging.

  ## Parameters
    - `program_indexes` - List of candidate program IDs
    - `parent_list` - Map of program_id => list of parent IDs
    - `scores` - Map of program_id => score

  ## Returns
    - `{id1, id2, common_ancestor}` if found
    - `nil` if no valid pair exists

  ## Algorithm
    1. Pick two programs from the candidate list
    2. Find their ancestors
    3. Check if they share a common ancestor
    4. Ensure neither is ancestor of the other
    5. Return first valid triplet found
  """
  @spec find_common_ancestor_pair(
          program_indexes :: [non_neg_integer()],
          parent_list :: %{non_neg_integer() => [non_neg_integer()]},
          scores :: %{non_neg_integer() => float()}
        ) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  def find_common_ancestor_pair(program_indexes, parent_list, scores, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 10)

    # Need at least 2 programs
    if length(program_indexes) < 2 do
      nil
    else
      do_find_pair(program_indexes, parent_list, scores, max_attempts)
    end
  end

  defp do_find_pair(_programs, _parent_list, _scores, 0), do: nil

  defp do_find_pair(programs, parent_list, scores, _attempts_left) do
    # Pick two random programs (for now, just take first two for determinism)
    # In production, we'd randomly sample
    case programs do
      [id1, id2 | _rest] when id1 != id2 ->
        # Get ancestors of each
        ancestors1 = get_ancestors(id1, parent_list) |> MapSet.new()
        ancestors2 = get_ancestors(id2, parent_list) |> MapSet.new()

        # Check if one is ancestor of the other
        cond do
          id1 in ancestors2 or id2 in ancestors1 ->
            # One is ancestor of other, can't merge
            nil

          true ->
            # Find common ancestors
            common = MapSet.intersection(ancestors1, ancestors2) |> MapSet.to_list()

            if length(common) > 0 do
              # Pick the highest-scoring common ancestor
              ancestor = Enum.max_by(common, fn a -> Map.get(scores, a, 0) end)
              {id1, id2, ancestor}
            else
              nil
            end
        end

      _ ->
        nil
    end
  end
end
