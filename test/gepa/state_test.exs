defmodule GEPA.StateTest do
  use ExUnit.Case, async: true

  alias GEPA.State

  describe "new/2" do
    test "creates initial state from seed candidate and eval batch" do
      seed_candidate = %{"instruction" => "You are helpful"}

      eval_batch = %GEPA.EvaluationBatch{
        outputs: ["out1", "out2"],
        scores: [0.8, 0.9]
      }

      valset_ids = [0, 1]

      state = State.new(seed_candidate, eval_batch, valset_ids)

      assert state.program_candidates == [seed_candidate]
      assert state.parent_program_for_candidate == [[nil]]
      assert state.list_of_named_predictors == ["instruction"]
      assert state.i == 0
      assert state.total_num_evals == 2
    end

    test "initializes Pareto fronts with seed scores" do
      seed = %{"comp1" => "text1"}

      eval_batch = %GEPA.EvaluationBatch{
        outputs: ["a", "b"],
        scores: [0.7, 0.9]
      }

      state = State.new(seed, eval_batch, [10, 20])

      assert state.pareto_front_valset[10] == 0.7
      assert state.pareto_front_valset[20] == 0.9
      assert MapSet.member?(state.program_at_pareto_front_valset[10], 0)
      assert MapSet.member?(state.program_at_pareto_front_valset[20], 0)
    end

    test "handles multi-component candidates" do
      seed = %{"comp1" => "text1", "comp2" => "text2"}
      eval_batch = %GEPA.EvaluationBatch{outputs: ["a"], scores: [1.0]}

      state = State.new(seed, eval_batch, [0])

      assert Enum.sort(state.list_of_named_predictors) == ["comp1", "comp2"]
      assert length(state.named_predictor_id_to_update_next_for_program_candidate) == 1
    end
  end

  describe "add_program/4" do
    test "adds new program and updates state" do
      state = create_initial_state()

      new_candidate = %{"instruction" => "improved"}
      parent_ids = [0]
      val_scores = %{0 => 0.95, 1 => 0.85}

      {new_state, new_idx} = State.add_program(state, new_candidate, parent_ids, val_scores)

      assert length(new_state.program_candidates) == 2
      assert new_idx == 1
      assert Enum.at(new_state.program_candidates, 1) == new_candidate
      assert Enum.at(new_state.parent_program_for_candidate, 1) == [0]
    end

    test "updates Pareto fronts when new program improves" do
      state = create_initial_state_with_scores(%{0 => 0.7, 1 => 0.8})

      new_candidate = %{"instruction" => "better"}
      val_scores = %{0 => 0.95, 1 => 0.85}

      {new_state, new_idx} = State.add_program(state, new_candidate, [0], val_scores)

      # New program should be on Pareto fronts
      assert new_state.pareto_front_valset[0] == 0.95
      assert new_state.pareto_front_valset[1] == 0.85
      assert MapSet.member?(new_state.program_at_pareto_front_valset[0], new_idx)
      assert MapSet.member?(new_state.program_at_pareto_front_valset[1], new_idx)
    end

    test "handles ties on Pareto front" do
      state = create_initial_state_with_scores(%{0 => 0.9})

      new_candidate = %{"instruction" => "also good"}
      # Same score as seed
      val_scores = %{0 => 0.9}

      {new_state, new_idx} = State.add_program(state, new_candidate, [0], val_scores)

      # Both programs should be on front
      assert MapSet.size(new_state.program_at_pareto_front_valset[0]) == 2
      assert MapSet.member?(new_state.program_at_pareto_front_valset[0], 0)
      assert MapSet.member?(new_state.program_at_pareto_front_valset[0], new_idx)
    end

    test "increments evaluation counters" do
      state = create_initial_state()

      {new_state, _} =
        State.add_program(state, %{"instruction" => "new"}, [0], %{0 => 0.8, 1 => 0.9})

      assert new_state.num_full_ds_evals == 1
      assert new_state.total_num_evals == state.total_num_evals + 2
    end
  end

  describe "get_program_score/2" do
    test "returns average score for program" do
      state = create_initial_state_with_scores(%{0 => 0.8, 1 => 0.9, 2 => 0.7})

      {avg, count} = State.get_program_score(state, 0)

      assert avg == (0.8 + 0.9 + 0.7) / 3
      assert count == 3
    end

    test "returns 0.0 for program with no scores" do
      state = %GEPA.State{
        program_candidates: [%{"instruction" => "seed"}],
        parent_program_for_candidate: [[nil]],
        prog_candidate_val_subscores: [%{}],
        pareto_front_valset: %{},
        program_at_pareto_front_valset: %{},
        list_of_named_predictors: ["instruction"]
      }

      {avg, count} = State.get_program_score(state, 0)

      assert avg == 0.0
      assert count == 0
    end
  end

  # Helper functions
  defp create_initial_state do
    seed = %{"instruction" => "seed"}
    eval_batch = %GEPA.EvaluationBatch{outputs: ["a", "b"], scores: [0.7, 0.8]}
    State.new(seed, eval_batch, [0, 1])
  end

  defp create_initial_state_with_scores(scores) do
    seed = %{"instruction" => "seed"}
    valset_ids = Map.keys(scores)
    score_list = Enum.map(valset_ids, &scores[&1])

    eval_batch = %GEPA.EvaluationBatch{
      outputs: List.duplicate("out", length(score_list)),
      scores: score_list
    }

    State.new(seed, eval_batch, valset_ids)
  end
end
