defmodule GEPA.Strategies.CandidateSelectorTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Strategies.CandidateSelector
  alias GEPA.Strategies.CandidateSelector.EpsilonGreedy

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

  describe "upstream candidate selector parity" do
    test "current-best selects best candidate" do
      state = upstream_mock_state()
      rand_state = :rand.seed(:exsss, {42, 42, 42})

      {selected_idx, _rand_state} = CandidateSelector.CurrentBest.select(state, rand_state)
      {score, coverage} = GEPA.State.get_program_score(state, selected_idx)

      assert selected_idx == 2
      assert_in_delta score, 0.8, 1.0e-12
      assert coverage == 3
    end

    test "current-best is deterministic" do
      state = upstream_mock_state()

      results =
        for _ <- 1..10 do
          {selected_idx, _rand_state} =
            CandidateSelector.CurrentBest.select(state, :rand.seed(:exsss, {1, 2, 3}))

          selected_idx
        end

      assert Enum.all?(results, &(&1 == hd(results)))
    end

    test "pareto samples from pareto-front candidates" do
      state = upstream_mock_state()
      rand_state = :rand.seed(:exsss, {42, 42, 42})

      {samples, _rand_state} =
        Enum.reduce(1..20, {[], rand_state}, fn _, {acc, rand} ->
          {selected_idx, next_rand} = CandidateSelector.Pareto.select(state, rand)
          {[selected_idx | acc], next_rand}
        end)

      assert Enum.all?(samples, &(&1 in 0..2))
    end

    test "pareto seeding produces deterministic sequence" do
      state = upstream_mock_state()
      rand_state_1 = :rand.seed(:exsss, {42, 42, 42})
      rand_state_2 = :rand.seed(:exsss, {42, 42, 42})

      {results_1, _rand_state} = pareto_sequence(state, rand_state_1, 10)
      {results_2, _rand_state} = pareto_sequence(state, rand_state_2, 10)

      assert results_1 == results_2
    end

    test "pareto default rng uses deterministic seed zero" do
      state = upstream_mock_state()

      {first_idx, first_rand} = CandidateSelector.Pareto.select(state, nil)

      {explicit_idx, explicit_rand} =
        CandidateSelector.Pareto.select(state, :rand.seed(:exsss, {0, 0, 0}))

      {default_results, _rand_state} = pareto_sequence(state, first_rand, 4, [first_idx])
      {explicit_results, _rand_state} = pareto_sequence(state, explicit_rand, 4, [explicit_idx])

      assert default_results == explicit_results
    end

    test "epsilon zero always exploits" do
      state = upstream_mock_state()
      selector = EpsilonGreedy.new(epsilon: 0.0)
      rand_state = :rand.seed(:exsss, {42, 42, 42})

      {results, _selector, _rand_state} = epsilon_sequence(selector, state, rand_state, 20)

      assert Enum.all?(results, &(&1 == 2))
    end

    test "epsilon one always explores" do
      state = upstream_mock_state()
      selector = EpsilonGreedy.new(epsilon: 1.0)
      rand_state = :rand.seed(:exsss, {42, 42, 42})

      {results, _selector, _rand_state} = epsilon_sequence(selector, state, rand_state, 50)

      assert MapSet.size(MapSet.new(results)) > 1
      assert Enum.all?(results, &(&1 in 0..2))
    end

    test "epsilon seeding produces deterministic sequence" do
      state = upstream_mock_state()
      selector_1 = EpsilonGreedy.new(epsilon: 0.3)
      selector_2 = EpsilonGreedy.new(epsilon: 0.3)
      rand_state_1 = :rand.seed(:exsss, {42, 42, 42})
      rand_state_2 = :rand.seed(:exsss, {42, 42, 42})

      {results_1, _selector, _rand_state} = epsilon_sequence(selector_1, state, rand_state_1, 10)
      {results_2, _selector, _rand_state} = epsilon_sequence(selector_2, state, rand_state_2, 10)

      assert results_1 == results_2
    end

    test "invalid epsilon raises" do
      assert_raise ArgumentError, fn -> EpsilonGreedy.new(epsilon: -0.1) end
      assert_raise ArgumentError, fn -> EpsilonGreedy.new(epsilon: 1.5) end
    end

    test "epsilon boundary values are accepted" do
      assert EpsilonGreedy.new(epsilon: 0.0).epsilon == 0.0
      assert EpsilonGreedy.new(epsilon: 1.0).epsilon == 1.0
    end

    test "epsilon selects best when not exploring" do
      state = upstream_mock_state()
      selector = EpsilonGreedy.new(epsilon: 0.01)
      rand_state = :rand.seed(:exsss, {42, 42, 42})

      {results, _selector, _rand_state} = epsilon_sequence(selector, state, rand_state, 100)
      best_count = Enum.count(results, &(&1 == 2))

      assert best_count >= 90
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

  defp upstream_mock_state do
    %GEPA.State{
      program_candidates: [
        %{"system_prompt" => "test"},
        %{"system_prompt" => "test2"},
        %{"system_prompt" => "test3"}
      ],
      parent_program_for_candidate: [[nil], [0], [1]],
      prog_candidate_val_subscores: [
        %{0 => 0.5, 1 => 0.3, 2 => 0.7},
        %{0 => 0.6, 1 => 0.6, 2 => 0.6},
        %{0 => 0.8, 1 => 0.8, 2 => 0.8}
      ],
      prog_candidate_objective_scores: [%{}, %{}, %{}],
      pareto_front_valset: %{0 => 0.8, 1 => 0.8, 2 => 0.8},
      program_at_pareto_front_valset: %{
        0 => MapSet.new([0, 1, 2]),
        1 => MapSet.new([0, 1, 2]),
        2 => MapSet.new([0, 1, 2])
      },
      list_of_named_predictors: ["system_prompt"],
      named_predictor_id_to_update_next_for_program_candidate: [0, 0, 0],
      num_metric_calls_by_discovery: [0, 0, 0]
    }
  end

  defp pareto_sequence(state, rand_state, count, acc \\ []) do
    Enum.reduce(1..count, {acc, rand_state}, fn _, {results, rand} ->
      {selected_idx, next_rand} = CandidateSelector.Pareto.select(state, rand)
      {results ++ [selected_idx], next_rand}
    end)
  end

  defp epsilon_sequence(selector, state, rand_state, count) do
    Enum.reduce(1..count, {[], selector, rand_state}, fn _, {results, current_selector, rand} ->
      {selected_idx, next_selector, next_rand} =
        EpsilonGreedy.select(current_selector, state, rand)

      {results ++ [selected_idx], next_selector, next_rand}
    end)
  end
end
