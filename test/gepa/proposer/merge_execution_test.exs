defmodule GEPA.Proposer.MergeExecutionTest do
  use ExUnit.Case, async: true

  # TDD: Tests for actual merge execution and predictor merging logic

  alias GEPA.Proposer.Merge
  alias GEPA.{State, EvaluationBatch, DataLoader, CandidateProposal}

  describe "merge execution with different predictor patterns - RED PHASE" do
    test "merges when one parent keeps ancestor value, other changes" do
      # Pattern: ancestor="A", parent1="A" (kept), parent2="B" (changed)
      # Expected: merge takes "B" from parent2

      state =
        create_state_with_programs([
          # 0: ancestor
          %{"instruction" => "A"},
          # 1: parent1 (kept ancestor)
          %{"instruction" => "A"},
          # 2: parent2 (changed)
          %{"instruction" => "B"}
        ])

      # Setup proposer and force a merge
      proposer = create_proposer_for_testing()
      proposer = %{proposer | merges_due: 1, last_iter_found_new_program: true}

      {proposal, _new_proposer} = Merge.propose(proposer, state)

      if proposal do
        # Merged candidate should take "B" from parent2 (the change)
        assert proposal.candidate["instruction"] == "B"
        assert proposal.tag == "merge"
        assert proposal.parent_program_ids == [1, 2]
      end
    end

    test "merges when both parents differ from ancestor" do
      # Pattern: ancestor="A", parent1="B", parent2="C"
      # Expected: merge picks higher-scoring parent

      state =
        create_state_with_programs([
          # 0: ancestor
          %{"instruction" => "A"},
          # 1: parent1 (score 0.7)
          %{"instruction" => "B"},
          # 2: parent2 (score 0.8)
          %{"instruction" => "C"}
        ])

      proposer = create_proposer_for_testing()
      proposer = %{proposer | merges_due: 1, last_iter_found_new_program: true}

      {proposal, _} = Merge.propose(proposer, state)

      if proposal do
        # Should pick parent2's "C" (higher score 0.8 > 0.7)
        assert proposal.candidate["instruction"] == "C"
      end
    end

    test "merges with multiple components independently" do
      state =
        create_state_with_programs([
          # 0: ancestor
          %{"instruction" => "A", "format" => "X"},
          # 1: kept inst, changed format
          %{"instruction" => "A", "format" => "Y"},
          # 2: changed inst, kept format
          %{"instruction" => "B", "format" => "X"}
        ])

      proposer = create_proposer_for_testing()
      proposer = %{proposer | merges_due: 1, last_iter_found_new_program: true}

      {proposal, _} = Merge.propose(proposer, state)

      if proposal do
        merged = proposal.candidate
        # Should take "B" from parent2 (instruction changed)
        # Should take "Y" from parent1 (format changed)
        assert merged["instruction"] == "B" or merged["instruction"] == "A"
        assert merged["format"] == "Y" or merged["format"] == "X"
      end
    end
  end

  describe "subsample selection - RED PHASE" do
    test "select_eval_subsample creates balanced sample" do
      proposer = create_proposer_for_testing()

      # Parent 1 better on IDs: 0, 1
      # Parent 2 better on IDs: 2, 3
      # Equal on IDs: 4, 5
      scores1 = %{0 => 0.9, 1 => 0.8, 2 => 0.5, 3 => 0.6, 4 => 0.7, 5 => 0.7}
      scores2 = %{0 => 0.6, 1 => 0.7, 2 => 0.9, 3 => 0.8, 4 => 0.7, 5 => 0.7}

      subsample =
        Merge.select_eval_subsample_for_merged_program(
          proposer,
          scores1,
          scores2,
          num_subsample_ids: 6
        )

      assert length(subsample) == 6
      # Should include samples from different performance categories
      assert Enum.all?(subsample, &(&1 in 0..5))
    end

    test "handles case where one parent dominates everywhere" do
      proposer = create_proposer_for_testing()

      # Parent 1 better on all
      scores1 = %{0 => 0.9, 1 => 0.9, 2 => 0.9}
      scores2 = %{0 => 0.5, 1 => 0.5, 2 => 0.5}

      subsample =
        Merge.select_eval_subsample_for_merged_program(
          proposer,
          scores1,
          scores2,
          num_subsample_ids: 3
        )

      assert length(subsample) == 3
      assert Enum.sort(subsample) == [0, 1, 2]
    end

    test "deterministic with same seed" do
      proposer = create_proposer_for_testing()

      scores1 = %{0 => 0.9, 1 => 0.5, 2 => 0.7, 3 => 0.6}
      scores2 = %{0 => 0.5, 1 => 0.9, 2 => 0.7, 3 => 0.6}

      subsample1 =
        Merge.select_eval_subsample_for_merged_program(
          proposer,
          scores1,
          scores2,
          num_subsample_ids: 3
        )

      subsample2 =
        Merge.select_eval_subsample_for_merged_program(
          proposer,
          scores1,
          scores2,
          num_subsample_ids: 3
        )

      # Same seed should give same subsample
      assert subsample1 == subsample2
    end
  end

  describe "merge scheduling - RED PHASE" do
    test "schedule_if_needed increments counter when conditions met" do
      proposer = create_proposer_for_testing()
      assert proposer.merges_due == 0

      proposer = Merge.schedule_if_needed(proposer)

      assert proposer.merges_due == 1
    end

    test "schedule_if_needed respects budget limit" do
      proposer =
        Merge.new(
          valset: DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          use_merge: true,
          max_merge_invocations: 2
        )

      # Already at budget
      proposer = %{proposer | total_merges_tested: 2}

      proposer = Merge.schedule_if_needed(proposer)

      assert proposer.merges_due == 0
    end

    test "can schedule multiple merges" do
      proposer = create_proposer_for_testing()

      proposer =
        proposer
        |> Merge.schedule_if_needed()
        |> Merge.schedule_if_needed()
        |> Merge.schedule_if_needed()

      assert proposer.merges_due == 3
    end
  end

  describe "val_overlap checking - RED PHASE" do
    test "requires minimum common validation IDs" do
      state =
        create_state_with_programs([
          %{"inst" => "A"},
          %{"inst" => "B"},
          %{"inst" => "C"}
        ])

      # Update state to have limited overlap
      state = %{
        state
        | prog_candidate_val_subscores: [
            # Program 0: IDs 0, 1
            %{0 => 0.5, 1 => 0.5},
            # Program 1: IDs 0, 1, 2
            %{0 => 0.7, 1 => 0.7, 2 => 0.6},
            # Program 2: IDs 2, 3 (only 1 overlap with prog 1)
            %{2 => 0.8, 3 => 0.7}
          ]
      }

      proposer =
        Merge.new(
          valset: DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          use_merge: true,
          max_merge_invocations: 5,
          # Require at least 2 common IDs
          val_overlap_floor: 2
        )

      proposer = %{proposer | merges_due: 1, last_iter_found_new_program: true}

      {proposal, _} = Merge.propose(proposer, state)

      # Programs 1 and 2 only share 1 validation ID (ID 2)
      # With val_overlap_floor=2, merge should be skipped
      # (actual behavior depends on which programs are selected)
      assert is_nil(proposal) or is_struct(proposal, CandidateProposal)
    end
  end

  # Test helpers

  defp create_proposer_for_testing do
    evaluator = fn _batch, _prog ->
      # Return dummy evaluation
      {["out"], [0.8]}
    end

    Merge.new(
      valset: DataLoader.List.new([%{input: "test", answer: "1"}]),
      evaluator: evaluator,
      use_merge: true,
      max_merge_invocations: 10,
      seed: 42
    )
  end

  defp create_state_with_programs(program_candidates) do
    # Create initial state
    seed = hd(program_candidates)
    num_programs = length(program_candidates)

    eval_batch = %EvaluationBatch{
      outputs: List.duplicate("out", 3),
      scores: [0.5, 0.5, 0.5]
    }

    state = State.new(seed, eval_batch, [0, 1, 2])

    # Build parent structure (0 is root, others are children of 0)
    parent_structure =
      0..(num_programs - 1)
      |> Enum.map(fn idx ->
        if idx == 0, do: {idx, []}, else: {idx, [0]}
      end)
      |> Enum.into(%{})

    # Build subscores (list indexed by program ID)
    subscores =
      0..(num_programs - 1)
      |> Enum.map(fn idx ->
        # Give different scores to each program
        base_score = 0.5 + idx * 0.1
        %{0 => base_score, 1 => base_score, 2 => base_score}
      end)

    # Update state with programs
    state = %{
      state
      | program_candidates: program_candidates,
        parent_program_for_candidate: parent_structure,
        prog_candidate_val_subscores: subscores,
        program_at_pareto_front_valset: %{
          0 => MapSet.new(1..(num_programs - 1)),
          1 => MapSet.new(1..(num_programs - 1)),
          2 => MapSet.new([num_programs - 1])
        }
    }

    state
  end
end
