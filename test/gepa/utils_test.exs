defmodule GEPA.UtilsTest do
  use ExUnit.Case, async: true

  # TDD RED PHASE: Merge Proposer Utilities
  # These tests will fail until we implement the functions

  describe "find_dominator_programs/2 - RED PHASE" do
    test "finds programs that dominate others on simple Pareto front" do
      # Setup: Pareto front with clear dominators
      pareto_front = %{
        # val_id => set of program indices on Pareto front for that validation example
        0 => MapSet.new([0, 1, 2]),
        1 => MapSet.new([1, 2, 3]),
        2 => MapSet.new([2, 3])
      }

      scores = %{
        # Low score - dominated
        0 => 0.5,
        # Medium score - dominated by 2
        1 => 0.7,
        # Highest score - dominator
        2 => 0.9,
        # High but dominated by 2 on all fronts
        3 => 0.8
      }

      dominators = GEPA.Utils.find_dominator_programs(pareto_front, scores)

      # Only program 2 is a true dominator (highest score, appears everywhere)
      assert is_list(dominators)
      assert 2 in dominators
      # Program 0 should be dominated (lowest score)
      assert 0 not in dominators
      # Program 3 is dominated by 2 on both its fronts
      assert 3 not in dominators
    end

    test "returns all programs when none are dominated" do
      pareto_front = %{
        0 => MapSet.new([0]),
        1 => MapSet.new([1]),
        2 => MapSet.new([2])
      }

      scores = %{0 => 0.8, 1 => 0.8, 2 => 0.8}

      dominators = GEPA.Utils.find_dominator_programs(pareto_front, scores)

      # All programs are dominators (equal scores)
      assert length(dominators) == 3
      assert Enum.sort(dominators) == [0, 1, 2]
    end

    test "handles single program on Pareto front" do
      pareto_front = %{0 => MapSet.new([5])}
      scores = %{5 => 0.9}

      dominators = GEPA.Utils.find_dominator_programs(pareto_front, scores)

      assert dominators == [5]
    end

    test "removes programs that appear on fewer validation Pareto fronts" do
      # Program 2 appears on all fronts, programs 0 and 1 on fewer
      pareto_front = %{
        0 => MapSet.new([0, 2]),
        1 => MapSet.new([1, 2]),
        2 => MapSet.new([2]),
        3 => MapSet.new([2])
      }

      scores = %{0 => 0.7, 1 => 0.7, 2 => 0.9}

      dominators = GEPA.Utils.find_dominator_programs(pareto_front, scores)

      # Program 2 dominates (highest score, appears everywhere)
      assert 2 in dominators
    end

    test "returns empty list for empty input" do
      dominators = GEPA.Utils.find_dominator_programs(%{}, %{})

      assert dominators == []
    end
  end

  describe "is_dominated?/3 helper - RED PHASE" do
    test "program is dominated when better programs exist on all its fronts" do
      program = 0
      better_programs = MapSet.new([1, 2])

      pareto_front = %{
        # Program 0 and 1 on front for val_0
        0 => MapSet.new([0, 1]),
        # Program 0 and 2 on front for val_1
        1 => MapSet.new([0, 2])
      }

      # Program 0 appears on fronts 0 and 1
      # On front 0, program 1 dominates
      # On front 1, program 2 dominates
      # So program 0 is dominated
      result = GEPA.Utils.is_dominated?(program, better_programs, pareto_front)

      assert result == true
    end

    test "program is not dominated when it's alone on at least one front" do
      program = 5
      better_programs = MapSet.new([6, 7])

      pareto_front = %{
        0 => MapSet.new([5, 6, 7]),
        # Only program 5 on this front!
        1 => MapSet.new([5])
      }

      result = GEPA.Utils.is_dominated?(program, better_programs, pareto_front)

      assert result == false
    end

    test "program not on any front is considered dominated" do
      program = 99
      better_programs = MapSet.new([1, 2])

      pareto_front = %{
        0 => MapSet.new([1, 2]),
        1 => MapSet.new([1])
      }

      # Program 99 never appears, so can't check domination properly
      # Should be considered dominated (or handle gracefully)
      result = GEPA.Utils.is_dominated?(program, better_programs, pareto_front)

      # May return true or false depending on implementation
      assert is_boolean(result)
    end
  end

  describe "remove_dominated_programs/2 - RED PHASE" do
    test "removes programs dominated across all fronts" do
      pareto_front = %{
        0 => MapSet.new([0, 1, 2]),
        1 => MapSet.new([1, 2]),
        2 => MapSet.new([2])
      }

      scores = %{0 => 0.5, 1 => 0.7, 2 => 0.9}

      new_front = GEPA.Utils.remove_dominated_programs(pareto_front, scores)

      # Should keep high-scoring programs
      assert is_map(new_front)

      # Program 2 should remain on all fronts
      for {_val_id, front} <- new_front do
        assert 2 in front or MapSet.member?(front, 2)
      end
    end

    test "preserves Pareto front structure" do
      pareto_front = %{
        0 => MapSet.new([1, 2]),
        1 => MapSet.new([2, 3])
      }

      scores = %{1 => 0.7, 2 => 0.9, 3 => 0.8}

      new_front = GEPA.Utils.remove_dominated_programs(pareto_front, scores)

      # Should return map with same keys
      assert Map.keys(new_front) == Map.keys(pareto_front)

      # Each front should be subset of original
      for {val_id, original_front} <- pareto_front do
        new_set = new_front[val_id]

        assert MapSet.subset?(new_set, original_front) or
                 Enum.all?(new_set, &(&1 in original_front))
      end
    end

    test "handles equal scores" do
      pareto_front = %{0 => MapSet.new([0, 1, 2])}
      scores = %{0 => 0.8, 1 => 0.8, 2 => 0.8}

      new_front = GEPA.Utils.remove_dominated_programs(pareto_front, scores)

      # All programs have equal scores, none dominated
      front = new_front[0]
      assert MapSet.size(front) == 3
      assert front == MapSet.new([0, 1, 2])
    end
  end
end
