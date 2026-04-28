defmodule GEPA.Proposer.MergeUtilsOfficialTest do
  use ExUnit.Case, async: true

  alias GEPA.Proposer.MergeUtils

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
end
