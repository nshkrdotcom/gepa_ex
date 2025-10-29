defmodule GEPA.StopConditionAdvancedTest do
  use ExUnit.Case, async: true

  # TDD RED PHASE: Additional Stop Conditions

  alias GEPA.StopCondition.{Timeout, NoImprovement}
  alias GEPA.State

  describe "Timeout - RED PHASE" do
    test "creates timeout with duration" do
      timeout = Timeout.new(seconds: 10)

      assert %Timeout{} = timeout
      assert timeout.max_seconds == 10
    end

    test "does not stop before timeout" do
      timeout = Timeout.new(seconds: 100)
      state = create_minimal_state()

      # Just started, should not stop
      assert Timeout.should_stop?(timeout, state) == false
    end

    test "stops after timeout expires" do
      # Already expired
      timeout = Timeout.new(seconds: 0)
      # Small delay
      :timer.sleep(10)

      state = create_minimal_state()

      # Should stop (time expired)
      assert Timeout.should_stop?(timeout, state) == true
    end

    test "supports different time units" do
      t1 = Timeout.new(seconds: 10)
      assert t1.max_seconds == 10

      t2 = Timeout.new(minutes: 2)
      assert t2.max_seconds == 120

      t3 = Timeout.new(hours: 1)
      assert t3.max_seconds == 3600
    end
  end

  describe "NoImprovement - RED PHASE" do
    test "creates no improvement condition with patience" do
      condition = NoImprovement.new(patience: 5)

      assert %NoImprovement{} = condition
      assert condition.patience == 5
    end

    test "does not stop when improving" do
      condition = NoImprovement.new(patience: 3)

      # Create state showing improvement
      state1 = create_state_with_score(0.5, iteration: 1)
      condition = NoImprovement.update(condition, state1)

      # Improved!
      state2 = create_state_with_score(0.7, iteration: 2)
      condition = NoImprovement.update(condition, state2)

      # Should not stop (just improved)
      assert NoImprovement.should_stop?(condition, state2) == false
    end

    test "stops after patience iterations without improvement" do
      condition = NoImprovement.new(patience: 2)

      # Start at score 0.5
      state1 = create_state_with_score(0.5, iteration: 1)
      condition = NoImprovement.update(condition, state1)

      # No improvement for 2 iterations
      state2 = create_state_with_score(0.5, iteration: 2)
      condition = NoImprovement.update(condition, state2)

      state3 = create_state_with_score(0.5, iteration: 3)
      condition = NoImprovement.update(condition, state3)

      # Should stop (no improvement for patience=2 iterations)
      assert NoImprovement.should_stop?(condition, state3) == true
    end

    test "resets counter when improvement occurs" do
      condition = NoImprovement.new(patience: 2)

      state1 = create_state_with_score(0.5, iteration: 1)
      condition = NoImprovement.update(condition, state1)

      # No improvement
      state2 = create_state_with_score(0.5, iteration: 2)
      condition = NoImprovement.update(condition, state2)

      # Improvement! Should reset counter
      state3 = create_state_with_score(0.7, iteration: 3)
      condition = NoImprovement.update(condition, state3)

      # One more without improvement
      state4 = create_state_with_score(0.7, iteration: 4)
      condition = NoImprovement.update(condition, state4)

      # Should NOT stop (counter was reset at iteration 3)
      assert NoImprovement.should_stop?(condition, state4) == false
    end

    test "considers small improvements as no improvement" do
      condition = NoImprovement.new(patience: 2, min_improvement: 0.01)

      state1 = create_state_with_score(0.50, iteration: 1)
      condition = NoImprovement.update(condition, state1)

      # Tiny improvement (< 0.01)
      state2 = create_state_with_score(0.505, iteration: 2)
      condition = NoImprovement.update(condition, state2)

      # Should still count as no improvement
      assert condition.iterations_without_improvement > 0
    end
  end

  # Test helpers

  defp create_minimal_state do
    seed = %{"instruction" => "test"}
    eval_batch = %GEPA.EvaluationBatch{outputs: [], scores: []}
    State.new(seed, eval_batch, [])
  end

  defp create_state_with_score(score, opts) do
    iteration = Keyword.get(opts, :iteration, 0)

    seed = %{"instruction" => "test"}

    eval_batch = %GEPA.EvaluationBatch{
      outputs: ["out"],
      scores: [score]
    }

    state = State.new(seed, eval_batch, [0])
    %{state | i: iteration}
  end
end
