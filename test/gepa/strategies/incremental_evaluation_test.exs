defmodule GEPA.Strategies.IncrementalEvaluationTest do
  use ExUnit.Case, async: true

  # TDD RED PHASE: Incremental Evaluation Policy
  # Progressively evaluates validation set instead of all at once

  alias GEPA.Strategies.EvaluationPolicy.Incremental

  describe "new/1 - RED PHASE" do
    test "creates policy with default settings" do
      policy = Incremental.new()

      assert %Incremental{} = policy
      assert policy.initial_sample_size > 0
      assert policy.increment_size > 0
    end

    test "creates policy with custom settings" do
      policy =
        Incremental.new(
          initial_sample_size: 10,
          increment_size: 5,
          max_sample_size: 50
        )

      assert policy.initial_sample_size == 10
      assert policy.increment_size == 5
      assert policy.max_sample_size == 50
    end
  end

  describe "select_samples/3 - RED PHASE" do
    test "starts with initial sample size for new candidate" do
      policy = Incremental.new(initial_sample_size: 5)
      candidate_idx = 0
      # 100 samples available
      available_samples = Enum.to_list(0..99)

      {selected, _new_policy} =
        Incremental.select_samples(policy, candidate_idx, available_samples)

      # Should return initial sample size
      assert length(selected) == 5
      # All from available samples
      assert Enum.all?(selected, &(&1 in available_samples))
    end

    test "expands sample for previously evaluated candidate" do
      policy =
        Incremental.new(
          initial_sample_size: 5,
          increment_size: 3
        )

      # Simulate that candidate 1 was already evaluated on 5 samples
      policy = %{policy | evaluated_samples: %{1 => MapSet.new([0, 1, 2, 3, 4])}}

      available_samples = Enum.to_list(0..99)

      {selected, _new_policy} = Incremental.select_samples(policy, 1, available_samples)

      # Should return initial + increment = 8 samples
      assert length(selected) == 8
      # Should include previous samples plus new ones
      assert Enum.all?([0, 1, 2, 3, 4], &(&1 in selected))
    end

    test "respects max_sample_size limit" do
      policy =
        Incremental.new(
          initial_sample_size: 10,
          increment_size: 20,
          max_sample_size: 25
        )

      # Candidate already evaluated on 10
      policy = %{policy | evaluated_samples: %{1 => MapSet.new(0..9)}}

      available_samples = Enum.to_list(0..99)

      {selected, _} = Incremental.select_samples(policy, 1, available_samples)

      # Should cap at max_sample_size (25), not 10 + 20 = 30
      assert length(selected) <= 25
    end

    test "deterministic sample selection with seed" do
      policy1 = Incremental.new(initial_sample_size: 10, seed: 42)
      policy2 = Incremental.new(initial_sample_size: 10, seed: 42)

      available_samples = Enum.to_list(0..99)

      {selected1, _} = Incremental.select_samples(policy1, 0, available_samples)
      {selected2, _} = Incremental.select_samples(policy2, 0, available_samples)

      # Same seed = same selection
      assert selected1 == selected2
    end

    test "different seed gives different selection" do
      policy1 = Incremental.new(initial_sample_size: 10, seed: 42)
      policy2 = Incremental.new(initial_sample_size: 10, seed: 99)

      available_samples = Enum.to_list(0..99)

      {selected1, _} = Incremental.select_samples(policy1, 0, available_samples)
      {selected2, _} = Incremental.select_samples(policy2, 0, available_samples)

      # Different seed = likely different selection
      assert selected1 != selected2
    end
  end

  describe "should_do_full_eval?/3 - RED PHASE" do
    test "returns true when candidate is promising (high score)" do
      policy = Incremental.new(full_eval_threshold: 0.8)
      candidate_idx = 1
      # Above threshold
      partial_score = 0.9

      result = Incremental.should_do_full_eval?(policy, candidate_idx, partial_score)

      assert result == true
    end

    test "returns false when candidate score is low" do
      policy = Incremental.new(full_eval_threshold: 0.8)
      candidate_idx = 1
      # Below threshold
      partial_score = 0.5

      result = Incremental.should_do_full_eval?(policy, candidate_idx, partial_score)

      assert result == false
    end

    test "returns true when max samples already evaluated" do
      policy = Incremental.new(max_sample_size: 20)

      # Already evaluated on 20 samples (max)
      policy = %{policy | evaluated_samples: %{1 => MapSet.new(0..19)}}

      # Even with low score, should do full eval (at max already)
      result = Incremental.should_do_full_eval?(policy, 1, 0.3)

      assert result == true
    end
  end

  describe "update_evaluated/3 - RED PHASE" do
    test "tracks samples evaluated for each candidate" do
      policy = Incremental.new()

      samples = [0, 1, 2]
      policy = Incremental.update_evaluated(policy, 0, samples)

      # Should track evaluated samples
      assert MapSet.new(samples) == policy.evaluated_samples[0] or
               MapSet.subset?(MapSet.new(samples), policy.evaluated_samples[0])
    end

    test "accumulates samples across multiple evaluations" do
      policy = Incremental.new()

      policy = Incremental.update_evaluated(policy, 0, [0, 1, 2])
      policy = Incremental.update_evaluated(policy, 0, [3, 4, 5])

      # Should have all samples
      evaluated = policy.evaluated_samples[0]
      assert MapSet.subset?(MapSet.new([0, 1, 2, 3, 4, 5]), evaluated)
    end
  end
end
