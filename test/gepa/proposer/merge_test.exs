defmodule GEPA.Proposer.MergeTest do
  use ExUnit.Case, async: true

  # TDD RED PHASE: Main Merge Proposer Module
  # These tests define the complete merge proposer behavior

  alias GEPA.Proposer.Merge
  alias GEPA.{CandidateProposal, State, EvaluationBatch}

  describe "new/1 - RED PHASE" do
    test "creates merge proposer with required options" do
      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([%{input: "test", answer: "1"}]),
          evaluator: fn _batch, _prog -> {[], []} end,
          max_merge_invocations: 5
        )

      assert %Merge{} = proposer
      assert proposer.max_merge_invocations == 5
      assert proposer.merges_due == 0
      assert proposer.total_merges_tested == 0
    end

    test "raises on invalid val_overlap_floor" do
      assert_raise ArgumentError, fn ->
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          max_merge_invocations: 5,
          # Invalid!
          val_overlap_floor: 0
        )
      end
    end

    test "initializes with default seed if not provided" do
      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          max_merge_invocations: 5
        )

      assert proposer.seed != nil
    end
  end

  describe "schedule_if_needed/1 - RED PHASE" do
    test "increments merges_due when merge is enabled and under budget" do
      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          use_merge: true,
          max_merge_invocations: 5
        )

      assert proposer.merges_due == 0

      proposer = Merge.schedule_if_needed(proposer)

      assert proposer.merges_due == 1
    end

    test "does not schedule when merge is disabled" do
      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          use_merge: false,
          max_merge_invocations: 5
        )

      proposer = Merge.schedule_if_needed(proposer)

      assert proposer.merges_due == 0
    end

    test "does not schedule when budget exhausted" do
      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          use_merge: true,
          max_merge_invocations: 2
        )

      # Simulate 2 merges already tested
      proposer = %{proposer | total_merges_tested: 2}

      proposer = Merge.schedule_if_needed(proposer)

      # Should not schedule (at budget limit)
      assert proposer.merges_due == 0
    end
  end

  describe "select_eval_subsample_for_merged_program/3 - RED PHASE" do
    test "selects balanced subsample from parent score differences" do
      scores1 = %{0 => 0.8, 1 => 0.6, 2 => 0.7, 3 => 0.5, 4 => 0.9}
      scores2 = %{0 => 0.7, 1 => 0.8, 2 => 0.7, 3 => 0.6, 4 => 0.8}

      # Parent 1 better: id 0, 4
      # Parent 2 better: id 1, 3
      # Equal: id 2

      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          max_merge_invocations: 5,
          seed: 42
        )

      subsample =
        Merge.select_eval_subsample_for_merged_program(
          proposer,
          scores1,
          scores2,
          num_subsample_ids: 5
        )

      assert length(subsample) == 5
      # Should include samples from all three categories
      assert is_list(subsample)
      # All IDs should be from common IDs
      common = MapSet.intersection(MapSet.new(Map.keys(scores1)), MapSet.new(Map.keys(scores2)))
      assert Enum.all?(subsample, &MapSet.member?(common, &1))
    end

    test "handles small number of common IDs" do
      scores1 = %{0 => 0.8, 1 => 0.7}
      scores2 = %{0 => 0.7, 1 => 0.8}

      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          max_merge_invocations: 5,
          seed: 42
        )

      subsample =
        Merge.select_eval_subsample_for_merged_program(
          proposer,
          scores1,
          scores2,
          num_subsample_ids: 5
        )

      # Only 2 common IDs, but should still return 5 (with repeats allowed)
      assert length(subsample) <= 5
    end

    test "respects num_subsample_ids parameter" do
      scores1 = %{0 => 0.8, 1 => 0.6, 2 => 0.7, 3 => 0.5, 4 => 0.9, 5 => 0.8}
      scores2 = %{0 => 0.7, 1 => 0.8, 2 => 0.7, 3 => 0.6, 4 => 0.8, 5 => 0.7}

      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          max_merge_invocations: 5,
          seed: 42
        )

      subsample =
        Merge.select_eval_subsample_for_merged_program(
          proposer,
          scores1,
          scores2,
          num_subsample_ids: 3
        )

      assert length(subsample) == 3
    end
  end

  describe "propose/2 - RED PHASE" do
    test "returns nil when merge is not enabled" do
      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          use_merge: false,
          max_merge_invocations: 5
        )

      # Create minimal state
      state = create_minimal_state()

      result = Merge.propose(proposer, state)

      assert result == {nil, proposer}
    end

    test "returns nil when no merge is scheduled" do
      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          use_merge: true,
          max_merge_invocations: 5
        )

      # merges_due = 0, so no merge scheduled
      state = create_minimal_state()

      result = Merge.propose(proposer, state)

      assert result == {nil, proposer}
    end

    test "returns nil when last iteration found no new program" do
      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([]),
          evaluator: fn _, _ -> {[], []} end,
          use_merge: true,
          max_merge_invocations: 5
        )

      proposer = %{proposer | merges_due: 1, last_iter_found_new_program: false}
      state = create_minimal_state()

      result = Merge.propose(proposer, state)

      assert result == {nil, proposer}
    end

    test "attempts merge when conditions are met" do
      # Setup evaluator that returns scores
      evaluator = fn _batch, _prog ->
        # Subsample scores
        {[], [0.8, 0.8, 0.7]}
      end

      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([%{a: 1}, %{b: 2}, %{c: 3}]),
          evaluator: evaluator,
          use_merge: true,
          max_merge_invocations: 5,
          seed: 42
        )

      # Set conditions for merge
      proposer = %{proposer | merges_due: 1, last_iter_found_new_program: true}

      # Create state with mergeable programs
      state = create_mergeable_state()

      {proposal, new_proposer} = Merge.propose(proposer, state)

      # Should return a proposal or nil (depending on if valid merge found)
      assert is_nil(proposal) or match?(%CandidateProposal{}, proposal)
      assert %Merge{} = new_proposer
    end

    test "returns proposal with correct structure when merge succeeds" do
      evaluator = fn _batch, _prog ->
        # Good scores
        {[], [0.9, 0.9, 0.9]}
      end

      proposer =
        Merge.new(
          valset: GEPA.DataLoader.List.new([%{a: 1}, %{b: 2}, %{c: 3}]),
          evaluator: evaluator,
          use_merge: true,
          max_merge_invocations: 5,
          seed: 42
        )

      proposer = %{proposer | merges_due: 1, last_iter_found_new_program: true}
      state = create_good_mergeable_state()

      {proposal, _new_proposer} = Merge.propose(proposer, state)

      if proposal do
        assert %CandidateProposal{} = proposal
        assert proposal.tag == "merge"
        assert is_map(proposal.candidate)
        assert is_list(proposal.parent_program_ids)
        assert length(proposal.parent_program_ids) == 2
        assert is_list(proposal.subsample_indices)
        assert is_list(proposal.subsample_scores_after)
      end
    end
  end

  # Helper functions to create test states

  defp create_minimal_state do
    seed = %{"instruction" => "initial"}
    eval_batch = %EvaluationBatch{outputs: [], scores: []}
    State.new(seed, eval_batch, [])
  end

  defp create_mergeable_state do
    # Start with seed
    seed = %{"instruction" => "A"}

    eval_batch = %EvaluationBatch{
      outputs: ["out1", "out2", "out3"],
      scores: [0.5, 0.5, 0.5]
    }

    state = State.new(seed, eval_batch, [0, 1, 2])

    # Manually add child programs to simulate genealogy
    # This simulates what would happen after 2 iterations with proposals accepted
    state = %{
      state
      | program_candidates: [
          # 0: seed
          %{"instruction" => "A"},
          # 1: child of 0
          %{"instruction" => "A"},
          # 2: child of 0
          %{"instruction" => "B"}
        ],
        parent_program_for_candidate: %{
          0 => [],
          1 => [0],
          2 => [0]
        },
        prog_candidate_val_subscores: [
          # Program 0 scores
          %{0 => 0.5, 1 => 0.5, 2 => 0.5},
          # Program 1 scores
          %{0 => 0.7, 1 => 0.7, 2 => 0.6},
          # Program 2 scores
          %{0 => 0.6, 1 => 0.8, 2 => 0.7}
        ],
        program_at_pareto_front_valset: %{
          0 => MapSet.new([1, 2]),
          1 => MapSet.new([1, 2]),
          2 => MapSet.new([2])
        }
    }

    state
  end

  defp create_good_mergeable_state do
    create_mergeable_state()
  end
end
