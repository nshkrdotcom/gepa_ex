defmodule GEPA.Strategies.CandidateSelectorTest do
  use ExUnit.Case, async: true

  alias GEPA.Strategies.CandidateSelector

  describe "Pareto selector" do
    test "selects from Pareto front" do
      state = create_state_with_pareto()
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {selected_idx, _new_rand} = CandidateSelector.Pareto.select(state, rand_state)

      # Should select program 0 or 1 (both on fronts)
      assert selected_idx in [0, 1]
    end

    test "uses frequency weighting" do
      # Program 0 is on 3 fronts, program 1 is on 1 front
      state = create_state_with_skewed_fronts()

      # Run many times to test distribution
      selections =
        for seed <- 1..50 do
          rand_state = :rand.seed(:exsss, {seed, 2, 3})
          {idx, _} = CandidateSelector.Pareto.select(state, rand_state)
          idx
        end

      # Program 0 should be selected more often
      count_0 = Enum.count(selections, &(&1 == 0))
      # Should be ~75% but allow variance
      assert count_0 > 25
    end
  end

  describe "CurrentBest selector" do
    test "selects highest scoring program" do
      state = create_state_with_scores([0.7, 0.9, 0.8])
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {selected_idx, _} = CandidateSelector.CurrentBest.select(state, rand_state)

      # Highest score (0.9)
      assert selected_idx == 1
    end

    test "selects first program when all scores equal" do
      state = create_state_with_scores([0.8, 0.8, 0.8])
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {selected_idx, _} = CandidateSelector.CurrentBest.select(state, rand_state)

      assert selected_idx == 0
    end
  end

  # Helper functions
  defp create_state_with_pareto do
    %GEPA.State{
      program_candidates: [%{"i" => "a"}, %{"i" => "b"}],
      parent_program_for_candidate: [[nil], [0]],
      prog_candidate_val_subscores: [%{0 => 0.8, 1 => 0.9}, %{0 => 0.9, 1 => 0.7}],
      pareto_front_valset: %{0 => 0.9, 1 => 0.9},
      program_at_pareto_front_valset: %{
        0 => MapSet.new([1]),
        1 => MapSet.new([0])
      },
      list_of_named_predictors: ["i"]
    }
  end

  defp create_state_with_skewed_fronts do
    %GEPA.State{
      program_candidates: [%{"i" => "a"}, %{"i" => "b"}],
      parent_program_for_candidate: [[nil], [0]],
      prog_candidate_val_subscores: [
        %{0 => 0.9, 1 => 0.9, 2 => 0.9},
        %{3 => 0.8}
      ],
      pareto_front_valset: %{0 => 0.9, 1 => 0.9, 2 => 0.9, 3 => 0.8},
      program_at_pareto_front_valset: %{
        0 => MapSet.new([0]),
        1 => MapSet.new([0]),
        2 => MapSet.new([0]),
        3 => MapSet.new([1])
      },
      list_of_named_predictors: ["i"]
    }
  end

  defp create_state_with_scores(scores) do
    n = length(scores)

    # Create prog_candidate_val_subscores from scores
    subscores =
      Enum.with_index(scores)
      |> Enum.map(fn {score, idx} ->
        %{idx => score}
      end)

    %GEPA.State{
      program_candidates: List.duplicate(%{"i" => "x"}, n),
      parent_program_for_candidate: List.duplicate([nil], n),
      prog_candidate_val_subscores: subscores,
      pareto_front_valset: %{},
      program_at_pareto_front_valset: %{},
      list_of_named_predictors: ["i"]
    }
  end
end
