defmodule GEPA.Proposer.MergeUtilsOfficialTest do
  use ExUnit.Case, async: true

  alias GEPA.Proposer.MergeUtils

  test "triplet has desirable predictors when descendants diverge from a common ancestor" do
    program_candidates = [
      %{"pred" => "A"},
      %{"pred" => "A"},
      %{"pred" => "B"}
    ]

    assert MergeUtils.does_triplet_have_desirable_predictors?(program_candidates, 0, 1, 2)
  end

  test "triplet is not desirable when descendants are identical" do
    program_candidates = [
      %{"pred" => "A"},
      %{"pred" => "A"},
      %{"pred" => "A"}
    ]

    refute MergeUtils.does_triplet_have_desirable_predictors?(program_candidates, 0, 1, 2)
  end

  test "filter ancestors skips previously merged triplets" do
    program_candidates = [
      %{"pred" => "A"},
      %{"pred" => "A"},
      %{"pred" => "B"}
    ]

    assert MergeUtils.filter_ancestors(
             1,
             2,
             [0],
             {[{1, 2, 0}], []},
             %{0 => 0.1, 1 => 0.5, 2 => 0.6},
             program_candidates
           ) == []
  end

  test "filter ancestors skips when ancestor outscores descendants" do
    program_candidates = [
      %{"pred" => "A"},
      %{"pred" => "A"},
      %{"pred" => "B"}
    ]

    assert MergeUtils.filter_ancestors(
             1,
             2,
             [0],
             {[], []},
             %{0 => 0.9, 1 => 0.5, 2 => 0.6},
             program_candidates
           ) == []
  end

  test "filter ancestors returns viable common ancestor" do
    program_candidates = [
      %{"pred" => "A"},
      %{"pred" => "A"},
      %{"pred" => "B"}
    ]

    assert MergeUtils.filter_ancestors(
             1,
             2,
             [0],
             {[], []},
             %{0 => 0.1, 1 => 0.6, 2 => 0.7},
             program_candidates
           ) == [0]
  end

  test "ancestor traversal supports map and list parent structures" do
    parent_map = %{0 => [], 1 => [0], 2 => [1], 3 => [1]}
    parent_list = [[], [0], [1], [1]]

    assert MapSet.new(MergeUtils.get_ancestors(2, parent_map)) == MapSet.new([0, 1])
    assert MapSet.new(MergeUtils.get_ancestors(2, parent_list)) == MapSet.new([0, 1])
  end

  test "common ancestor pair rejects direct ancestor-descendant pairs" do
    parent_list = %{0 => [], 1 => [0], 2 => [1]}
    scores = %{0 => 0.2, 1 => 0.5, 2 => 0.8}

    assert MergeUtils.find_common_ancestor_pair([1, 2], parent_list, scores) == nil
  end

  test "common ancestor pair finds mergeable siblings and chooses a valid ancestor" do
    parent_list = %{0 => [], 1 => [0], 2 => [0], 3 => [1], 4 => [2]}
    scores = %{0 => 0.1, 1 => 0.3, 2 => 0.4, 3 => 0.8, 4 => 0.7}

    assert {3, 4, 0} = MergeUtils.find_common_ancestor_pair([3, 4], parent_list, scores)
  end

  test "common ancestor pair returns expected official triplet" do
    parent_list = [[], [0], [0]]
    program_candidates = [%{"pred" => "A"}, %{"pred" => "A"}, %{"pred" => "B"}]
    scores = %{0 => 0.1, 1 => 0.6, 2 => 0.7}

    assert MergeUtils.find_common_ancestor_pair([1, 2], parent_list, scores,
             merges_performed: {[], []},
             program_candidates: program_candidates
           ) == {1, 2, 0}
  end

  test "common ancestor pair returns nil when already merged" do
    parent_list = [[], [0], [0]]
    program_candidates = [%{"pred" => "A"}, %{"pred" => "A"}, %{"pred" => "B"}]
    scores = %{0 => 0.1, 1 => 0.6, 2 => 0.7}

    assert MergeUtils.find_common_ancestor_pair([1, 2], parent_list, scores,
             merges_performed: {[{1, 2, 0}], []},
             program_candidates: program_candidates
           ) == nil
  end
end
