defmodule GEPA.Proposer.MergePropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Property-based tests for merge proposer invariants

  alias GEPA.Proposer.MergeUtils
  alias GEPA.Utils

  describe "find_dominator_programs properties" do
    property "dominators are always in the input programs" do
      check all(
              num_programs <- integer(1..10),
              num_val_examples <- integer(1..5),
              max_runs: 100
            ) do
        # Generate Pareto front
        pareto_front =
          0..(num_val_examples - 1)
          |> Enum.map(fn val_id ->
            # Random subset of programs on this front
            num_on_front = :rand.uniform(num_programs)
            programs = Enum.take_random(0..(num_programs - 1), num_on_front)
            {val_id, MapSet.new(programs)}
          end)
          |> Enum.into(%{})

        # Generate scores
        scores =
          0..(num_programs - 1)
          |> Enum.map(fn idx -> {idx, :rand.uniform()} end)
          |> Enum.into(%{})

        # Find dominators
        dominators = Utils.find_dominator_programs(pareto_front, scores)

        # Property: All dominators must be in at least one front
        all_programs_in_fronts =
          pareto_front
          |> Map.values()
          |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        assert Enum.all?(dominators, &MapSet.member?(all_programs_in_fronts, &1))
      end
    end

    property "dominators are sorted by score descending" do
      check all(
              num_programs <- integer(2..8),
              max_runs: 50
            ) do
        # Create simple front with all programs
        pareto_front = %{0 => MapSet.new(0..(num_programs - 1))}

        # Generate distinct scores
        scores =
          0..(num_programs - 1)
          |> Enum.map(fn idx -> {idx, idx * 0.1 + 0.1} end)
          |> Enum.into(%{})

        dominators = Utils.find_dominator_programs(pareto_front, scores)

        # Property: Dominators should be in descending score order
        if length(dominators) > 1 do
          dominator_scores = Enum.map(dominators, &scores[&1])
          assert dominator_scores == Enum.sort(dominator_scores, &>=/2)
        end
      end
    end
  end

  describe "get_ancestors properties" do
    property "ancestors never include the program itself" do
      check all(
              num_programs <- integer(2..10),
              max_runs: 100
            ) do
        # Build random parent structure (ensuring no cycles)
        parent_list =
          0..(num_programs - 1)
          |> Enum.map(fn idx ->
            if idx == 0 do
              {idx, []}
            else
              # Parent can be any program with smaller index (ensures no cycles)
              parent = :rand.uniform(idx) - 1
              {idx, [parent]}
            end
          end)
          |> Enum.into(%{})

        # Pick random program
        program = :rand.uniform(num_programs) - 1

        ancestors = MergeUtils.get_ancestors(program, parent_list)

        # Property: Program never in its own ancestors
        assert program not in ancestors
      end
    end

    property "root program has no ancestors" do
      check all(num_programs <- integer(1..10), max_runs: 50) do
        parent_list =
          0..(num_programs - 1)
          |> Enum.map(fn idx ->
            {idx, if(idx == 0, do: [], else: [0])}
          end)
          |> Enum.into(%{})

        ancestors = MergeUtils.get_ancestors(0, parent_list)

        assert ancestors == []
      end
    end

    property "all ancestors have indices less than program (in linear genealogy)" do
      check all(num_programs <- integer(2..10), max_runs: 100) do
        # Linear: 0 -> 1 -> 2 -> 3 -> ...
        parent_list =
          0..(num_programs - 1)
          |> Enum.map(fn idx ->
            {idx, if(idx == 0, do: [], else: [idx - 1])}
          end)
          |> Enum.into(%{})

        program = :rand.uniform(num_programs) - 1
        ancestors = MergeUtils.get_ancestors(program, parent_list)

        # All ancestors should have smaller indices
        assert Enum.all?(ancestors, &(&1 < program))
      end
    end
  end

  describe "does_triplet_have_desirable_predictors properties" do
    property "returns false when all three programs are identical" do
      check all(
              num_components <- integer(1..5),
              max_runs: 50
            ) do
        # All programs have same components
        value = "SameValue"

        candidates =
          List.duplicate(
            Map.new(1..num_components, fn i -> {"comp#{i}", value} end),
            3
          )

        result = MergeUtils.does_triplet_have_desirable_predictors?(candidates, 0, 1, 2)

        assert result == false
      end
    end

    property "returns true when at least one component differs usefully" do
      check all(_num_components <- integer(1..3), max_runs: 50) do
        # Create candidates where first component has useful difference
        candidates = [
          # ancestor
          %{"comp1" => "A", "comp2" => "X"},
          # id1 same as ancestor
          %{"comp1" => "A", "comp2" => "X"},
          # id2 differs on comp1
          %{"comp1" => "B", "comp2" => "X"}
        ]

        result = MergeUtils.does_triplet_have_desirable_predictors?(candidates, 0, 1, 2)

        assert result == true
      end
    end
  end

  describe "filter_ancestors properties" do
    property "filtered ancestors always subset of input ancestors" do
      check all(
              num_ancestors <- integer(1..5),
              max_runs: 50
            ) do
        ancestor_list = Enum.to_list(0..(num_ancestors - 1))

        # Create simple candidates
        candidates = List.duplicate(%{"inst" => "A"}, 10)
        scores = Map.new(0..9, fn i -> {i, i * 0.1} end)
        merges_performed = {[], []}

        filtered =
          MergeUtils.filter_ancestors(
            5,
            6,
            ancestor_list,
            merges_performed,
            scores,
            candidates
          )

        # Property: filtered is subset of input
        assert Enum.all?(filtered, &(&1 in ancestor_list))
      end
    end
  end

  describe "remove_dominated_programs properties" do
    property "result fronts are subsets of input fronts" do
      check all(
              num_programs <- integer(1..8),
              num_val <- integer(1..4),
              max_runs: 100
            ) do
        # Generate random Pareto fronts
        pareto_front =
          0..(num_val - 1)
          |> Enum.map(fn val_id ->
            count = :rand.uniform(num_programs)
            programs = Enum.take_random(0..(num_programs - 1), count)
            {val_id, MapSet.new(programs)}
          end)
          |> Enum.into(%{})

        scores =
          0..(num_programs - 1)
          |> Enum.map(fn i -> {i, :rand.uniform()} end)
          |> Enum.into(%{})

        result = Utils.remove_dominated_programs(pareto_front, scores)

        # Property: Each result front is subset of corresponding input front
        for {val_id, original_front} <- pareto_front do
          result_front = Map.get(result, val_id, MapSet.new())
          assert MapSet.subset?(result_front, original_front)
        end
      end
    end

    property "at least one program remains on each non-empty front" do
      check all(
              num_programs <- integer(2..8),
              max_runs: 100
            ) do
        # Create front with multiple programs
        pareto_front = %{
          0 => MapSet.new(0..(num_programs - 1))
        }

        scores = Map.new(0..(num_programs - 1), fn i -> {i, :rand.uniform()} end)

        result = Utils.remove_dominated_programs(pareto_front, scores)

        # Property: At least one program remains
        assert MapSet.size(result[0]) >= 1
      end
    end
  end
end
