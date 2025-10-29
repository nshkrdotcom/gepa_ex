defmodule GEPA.Proposer.MergeUtilsTest do
  use ExUnit.Case, async: true

  # TDD RED PHASE: Genealogy Tracking Utilities
  # These tests define the behavior we need for merge proposer

  alias GEPA.Proposer.MergeUtils

  describe "find_common_ancestor_pair/3 - RED PHASE" do
    test "finds two programs with a common ancestor" do
      # Genealogy: 0 -> 1 -> 3
      #            0 -> 2 -> 4
      # Programs 3 and 4 share ancestor 0
      parent_list = %{
        # Root, no parents
        0 => [],
        # Parent is 0
        1 => [0],
        # Parent is 0
        2 => [0],
        # Parent is 1
        3 => [1],
        # Parent is 2
        4 => [2]
      }

      # Candidates for merging
      program_indexes = [3, 4]
      scores = %{0 => 0.5, 1 => 0.7, 2 => 0.7, 3 => 0.8, 4 => 0.8}

      result =
        MergeUtils.find_common_ancestor_pair(
          program_indexes,
          parent_list,
          scores
        )

      # Should find (3, 4, 0) - programs 3 and 4 with common ancestor 0
      assert {prog1, prog2, ancestor} = result
      assert {prog1, prog2} == {3, 4} or {prog1, prog2} == {4, 3}
      assert ancestor == 0
    end

    test "returns nil when no common ancestor exists" do
      # No shared ancestry
      parent_list = %{
        0 => [],
        1 => [],
        2 => [0],
        3 => [1]
      }

      program_indexes = [2, 3]
      scores = %{0 => 0.5, 1 => 0.5, 2 => 0.7, 3 => 0.7}

      result =
        MergeUtils.find_common_ancestor_pair(
          program_indexes,
          parent_list,
          scores
        )

      assert result == nil
    end

    test "returns nil when one program is ancestor of another" do
      # Linear: 0 -> 1 -> 2
      parent_list = %{
        0 => [],
        1 => [0],
        2 => [1]
      }

      program_indexes = [1, 2]
      scores = %{0 => 0.5, 1 => 0.7, 2 => 0.8}

      # Can't merge parent with child
      result =
        MergeUtils.find_common_ancestor_pair(
          program_indexes,
          parent_list,
          scores
        )

      assert result == nil
    end

    test "handles multiple common ancestors, picks valid one" do
      # Diamond pattern: 0, 1 -> 2, 3 (both 2 and 3 have parents 0 and 1)
      parent_list = %{
        0 => [],
        1 => [],
        2 => [0, 1],
        3 => [0, 1]
      }

      program_indexes = [2, 3]
      scores = %{0 => 0.5, 1 => 0.5, 2 => 0.8, 3 => 0.8}

      result =
        MergeUtils.find_common_ancestor_pair(
          program_indexes,
          parent_list,
          scores
        )

      # Should find common ancestor (0 or 1)
      assert {2, 3, ancestor} = result
      assert ancestor in [0, 1]
    end
  end

  describe "get_ancestors/2 - RED PHASE" do
    test "returns all ancestors for a program" do
      parent_list = %{
        0 => [],
        1 => [0],
        2 => [1],
        3 => [2]
      }

      ancestors = MergeUtils.get_ancestors(3, parent_list)

      # Ancestors of 3: 2, 1, 0
      assert is_list(ancestors)
      assert 2 in ancestors
      assert 1 in ancestors
      assert 0 in ancestors
      # Not its own ancestor
      assert 3 not in ancestors
    end

    test "returns empty list for root program" do
      parent_list = %{
        0 => [],
        1 => [0]
      }

      ancestors = MergeUtils.get_ancestors(0, parent_list)

      assert ancestors == []
    end

    test "handles multiple parents" do
      parent_list = %{
        0 => [],
        1 => [],
        2 => [0, 1]
      }

      ancestors = MergeUtils.get_ancestors(2, parent_list)

      assert 0 in ancestors
      assert 1 in ancestors
    end
  end

  describe "does_triplet_have_desirable_predictors/4 - RED PHASE" do
    test "returns true when predictors differ usefully" do
      program_candidates = [
        # 0: ancestor
        %{"instruction" => "A"},
        # 1: same as ancestor
        %{"instruction" => "A"},
        # 2: different from ancestor
        %{"instruction" => "B"}
      ]

      ancestor = 0
      id1 = 1
      id2 = 2

      # Triplet (0, 1, 2) has desirable predictor:
      # - ancestor has "A"
      # - id1 has "A" (same as ancestor)
      # - id2 has "B" (different)
      # We can merge: keep "A" from ancestor/id1, or try "B" from id2

      result =
        MergeUtils.does_triplet_have_desirable_predictors?(
          program_candidates,
          ancestor,
          id1,
          id2
        )

      assert result == true
    end

    test "returns false when all predictors are identical" do
      program_candidates = [
        # ancestor
        %{"instruction" => "A"},
        # id1
        %{"instruction" => "A"},
        # id2
        %{"instruction" => "A"}
      ]

      result =
        MergeUtils.does_triplet_have_desirable_predictors?(
          program_candidates,
          0,
          1,
          2
        )

      assert result == false
    end

    test "returns true with multiple components, at least one differs" do
      program_candidates = [
        # ancestor
        %{"instruction" => "A", "format" => "X"},
        # id1 - same
        %{"instruction" => "A", "format" => "X"},
        # id2 - instruction differs
        %{"instruction" => "B", "format" => "X"}
      ]

      result =
        MergeUtils.does_triplet_have_desirable_predictors?(
          program_candidates,
          0,
          1,
          2
        )

      assert result == true
    end

    test "returns false when both children differ from ancestor but identical to each other" do
      program_candidates = [
        # ancestor
        %{"instruction" => "A"},
        # id1 - different from ancestor
        %{"instruction" => "B"},
        # id2 - same as id1
        %{"instruction" => "B"}
      ]

      # No useful merge: both children have the same change
      result =
        MergeUtils.does_triplet_have_desirable_predictors?(
          program_candidates,
          0,
          1,
          2
        )

      assert result == false
    end
  end

  describe "filter_ancestors/5 - RED PHASE" do
    test "filters ancestors that have already been used for merging" do
      common_ancestors = [0, 1]
      # Already merged 3, 4 via ancestor 0
      merges_performed = {[{3, 4, 0}], []}

      program_candidates = [
        # 0: ancestor
        %{"inst" => "A"},
        # 1: ancestor (same as 0)
        %{"inst" => "A"},
        # 2
        %{"inst" => "B"},
        # 3: id1 (same as ancestor 1)
        %{"inst" => "A"},
        # 4: id2 (different from ancestor)
        %{"inst" => "C"}
      ]

      scores = %{0 => 0.5, 1 => 0.5, 3 => 0.7, 4 => 0.7}

      filtered =
        MergeUtils.filter_ancestors(
          # id1
          3,
          # id2
          4,
          common_ancestors,
          merges_performed,
          scores,
          program_candidates
        )

      # Ancestor 0 was already used for this pair
      assert 0 not in filtered
      # Ancestor 1 is still valid (has desirable predictors: 1=="A", 3=="A", 4=="C")
      assert 1 in filtered
    end

    test "filters ancestors with higher scores than descendants" do
      common_ancestors = [0, 1]
      merges_performed = {[], []}

      program_candidates = [
        # 0: high score but bad ancestor
        %{"inst" => "A"},
        # 1: low score, good ancestor
        %{"inst" => "A"},
        # 2: id1 (same as ancestors)
        %{"inst" => "A"},
        # 3: id2 (different)
        %{"inst" => "B"}
      ]

      scores = %{
        # Higher than descendants!
        0 => 0.9,
        # Lower than descendants
        1 => 0.6,
        # id1
        2 => 0.7,
        # id2
        3 => 0.8
      }

      filtered =
        MergeUtils.filter_ancestors(
          # id1
          2,
          # id2
          3,
          common_ancestors,
          merges_performed,
          scores,
          program_candidates
        )

      # Ancestor 0 has score 0.9 > both 0.7 and 0.8, so skip it
      assert 0 not in filtered
      # Ancestor 1 has score 0.6 < both, so keep it (and has desirable predictors)
      assert 1 in filtered
    end

    test "filters ancestors without desirable predictors" do
      common_ancestors = [0]
      merges_performed = {[], []}

      program_candidates = [
        # ancestor
        %{"inst" => "A"},
        # id1 - same
        %{"inst" => "A"},
        # id2 - same
        %{"inst" => "A"}
      ]

      scores = %{0 => 0.5, 1 => 0.7, 2 => 0.8}

      filtered =
        MergeUtils.filter_ancestors(
          1,
          2,
          common_ancestors,
          merges_performed,
          scores,
          program_candidates
        )

      # No useful predictors (all same)
      assert filtered == []
    end
  end
end
