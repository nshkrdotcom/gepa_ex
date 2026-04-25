defmodule GEPA.Strategies.CandidateSelector.EpsilonGreedyTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Strategies.CandidateSelector.CurrentBest
  alias GEPA.Strategies.CandidateSelector.EpsilonGreedy

  describe "new/1" do
    test "creates with defaults" do
      selector = EpsilonGreedy.new()

      assert selector.epsilon == 0.1
      assert selector.epsilon_decay == 1.0
      assert selector.epsilon_min == 0.01
      assert selector.current_epsilon == 0.1
    end

    test "validates probability options" do
      assert_raise ArgumentError, fn -> EpsilonGreedy.new(epsilon: 1.5) end
      assert_raise ArgumentError, fn -> EpsilonGreedy.new(epsilon: -0.1) end
      assert_raise ArgumentError, fn -> EpsilonGreedy.new(epsilon: "nope") end
    end
  end

  describe "select/3" do
    test "always explores when epsilon is 1.0" do
      selector = EpsilonGreedy.new(epsilon: 1.0)
      state = mock_state_with_candidates(5)
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {results, _selector, _rand_state} =
        Enum.reduce(1..10, {[], selector, rand_state}, fn _, {acc, sel, rand} ->
          {idx, next_sel, next_rand} = EpsilonGreedy.select(sel, state, rand)
          {[idx | acc], next_sel, next_rand}
        end)

      assert length(Enum.uniq(results)) > 1
    end

    test "exploits when epsilon is zero" do
      selector = EpsilonGreedy.new(epsilon: 0.0, epsilon_min: 0.0)
      state = mock_state_with_candidates(3)
      rand_state = :rand.seed(:exsss, {1, 2, 3})
      best_idx = CurrentBest.best_candidate_idx(state)

      Enum.reduce(1..5, {selector, rand_state}, fn _, {sel, rand} ->
        {idx, next_sel, next_rand} = EpsilonGreedy.select(sel, state, rand)
        assert idx == best_idx
        {next_sel, next_rand}
      end)
    end

    test "decays epsilon after selection and respects minimum" do
      selector =
        EpsilonGreedy.new(
          epsilon: 0.5,
          epsilon_decay: 0.5,
          epsilon_min: 0.1
        )

      state = mock_state_with_candidates(2)
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {final_selector, _rand_state} =
        Enum.reduce(1..5, {selector, rand_state}, fn _, {sel, rand} ->
          {_idx, next_sel, next_rand} = EpsilonGreedy.select(sel, state, rand)
          {next_sel, next_rand}
        end)

      assert final_selector.current_epsilon >= 0.1
      assert final_selector.current_epsilon <= 0.5
    end
  end

  describe "reset/1" do
    test "restores epsilon to initial value" do
      selector = EpsilonGreedy.new(epsilon: 0.3, epsilon_decay: 0.5)
      state = mock_state_with_candidates(2)
      rand_state = :rand.seed(:exsss, {1, 2, 3})

      {_idx, decayed, _rand_state} = EpsilonGreedy.select(selector, state, rand_state)
      assert decayed.current_epsilon < selector.epsilon

      reset = EpsilonGreedy.reset(decayed)
      assert reset.current_epsilon == selector.epsilon
      assert reset.epsilon_decay == selector.epsilon_decay
    end
  end

  defp mock_state_with_candidates(n) do
    candidates = for i <- 1..n, do: %{"instruction" => "Candidate #{i}"}
    scores = for idx <- 0..(n - 1), do: %{idx => (idx + 1) / n}

    %GEPA.State{
      program_candidates: candidates,
      parent_program_for_candidate: List.duplicate([nil], n),
      prog_candidate_val_subscores: scores,
      pareto_front_valset: %{},
      program_at_pareto_front_valset: %{},
      list_of_named_predictors: ["instruction"]
    }
  end
end
