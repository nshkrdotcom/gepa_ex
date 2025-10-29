defmodule GEPA.Utils.ParetoTest do
  use ExUnit.Case, async: true

  alias GEPA.Utils.Pareto

  describe "is_dominated?/3" do
    test "returns true when program is on all same fronts as another program" do
      # Program 1 appears in fronts for val1 and val2
      # Program 0 also appears in both fronts
      # Therefore, program 1 is dominated by program 0
      fronts = %{
        "val1" => MapSet.new([0, 1]),
        "val2" => MapSet.new([0, 1])
      }

      assert Pareto.is_dominated?(1, [0], fronts)
    end

    test "returns false when program has a unique front" do
      # Program 1 appears in val1 and val2
      # Program 0 only appears in val1
      # Program 1 is NOT dominated because it's alone on val2
      fronts = %{
        "val1" => MapSet.new([0, 1]),
        "val2" => MapSet.new([1])
      }

      refute Pareto.is_dominated?(1, [0], fronts)
    end

    test "returns false when program is the only one" do
      fronts = %{
        "val1" => MapSet.new([0])
      }

      refute Pareto.is_dominated?(0, [], fronts)
    end

    test "returns false when programs list is empty" do
      fronts = %{
        "val1" => MapSet.new([0, 1])
      }

      refute Pareto.is_dominated?(1, [], fronts)
    end

    test "handles multiple candidate programs" do
      # Program 2 is on val1 and val2
      # Programs 0 and 1 together cover both fronts
      # So program 2 is dominated by the combination
      fronts = %{
        "val1" => MapSet.new([0, 2]),
        "val2" => MapSet.new([1, 2])
      }

      assert Pareto.is_dominated?(2, [0, 1], fronts)
    end
  end

  describe "remove_dominated_programs/2" do
    test "removes dominated programs from fronts" do
      scores = %{0 => 0.85, 1 => 0.80, 2 => 0.90}

      # Program 1 is dominated (appears with 0 and 2 everywhere)
      fronts = %{
        "val1" => MapSet.new([0, 1]),
        "val2" => MapSet.new([1, 2])
      }

      result = Pareto.remove_dominated_programs(fronts, scores)

      # Program 1 should be removed
      refute MapSet.member?(result["val1"], 1)
      refute MapSet.member?(result["val2"], 1)

      # Programs 0 and 2 should remain
      assert MapSet.member?(result["val1"], 0)
      assert MapSet.member?(result["val2"], 2)
    end

    test "keeps all programs when none are dominated" do
      scores = %{0 => 0.9, 1 => 0.8}

      fronts = %{
        "val1" => MapSet.new([0]),
        "val2" => MapSet.new([1])
      }

      result = Pareto.remove_dominated_programs(fronts, scores)

      assert MapSet.member?(result["val1"], 0)
      assert MapSet.member?(result["val2"], 1)
    end

    test "preserves at least one program per front" do
      scores = %{0 => 0.9, 1 => 0.8, 2 => 0.7}

      fronts = %{
        "val1" => MapSet.new([0, 1, 2])
      }

      result = Pareto.remove_dominated_programs(fronts, scores)

      # At least program 0 (highest score) should remain
      assert MapSet.size(result["val1"]) >= 1
    end
  end

  describe "select_from_pareto_front/3" do
    test "selects a program from the pareto front" do
      scores = %{0 => 0.9, 1 => 0.8}

      fronts = %{
        "val1" => MapSet.new([0]),
        "val2" => MapSet.new([0, 1]),
        "val3" => MapSet.new([1])
      }

      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {selected, _new_rand} = Pareto.select_from_pareto_front(fronts, scores, rand_state)

      # Selected program must be 0 or 1
      assert selected in [0, 1]

      # Selected program must be in at least one front
      assert Enum.any?(fronts, fn {_id, front} ->
               MapSet.member?(front, selected)
             end)
    end

    test "program on more fronts has higher selection probability" do
      # Program 0 is on 3 fronts, program 1 is on 1 front
      # Program 0 should be selected more often
      scores = %{0 => 0.9, 1 => 0.8}

      fronts = %{
        "val1" => MapSet.new([0]),
        "val2" => MapSet.new([0]),
        "val3" => MapSet.new([0]),
        "val4" => MapSet.new([1])
      }

      # Run 100 selections with different seeds
      selections =
        for seed <- 1..100 do
          rand_state = :rand.seed(:exsss, {seed, 2, 3})
          {selected, _} = Pareto.select_from_pareto_front(fronts, scores, rand_state)
          selected
        end

      # Program 0 should be selected more than 50% of the time
      count_0 = Enum.count(selections, &(&1 == 0))
      assert count_0 > 50
    end
  end

  describe "find_dominator_programs/2" do
    test "returns list of non-dominated program indices" do
      scores = %{0 => 0.9, 1 => 0.8, 2 => 0.95}

      fronts = %{
        "val1" => MapSet.new([0, 1]),
        "val2" => MapSet.new([1, 2])
      }

      dominators = Pareto.find_dominator_programs(fronts, scores)

      # Should return unique list of program indices
      assert is_list(dominators)
      assert 0 in dominators or 2 in dominators
    end
  end
end
