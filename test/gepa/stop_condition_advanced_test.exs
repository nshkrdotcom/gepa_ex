defmodule GEPA.StopConditionAdvancedTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  # TDD RED PHASE: Additional Stop Conditions

  alias GEPA.State

  alias GEPA.StopCondition.{
    Composite,
    FileStopper,
    MaxCandidateProposals,
    MaxReflectionCost,
    MaxTrackedCandidates,
    NoImprovement,
    ScoreThreshold,
    SignalStopper,
    Timeout
  }

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
      timeout =
        Timeout.new(seconds: 1)
        |> Map.update!(:start_time, &(&1 - 2))

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

  describe "additional upstream stop conditions" do
    test "file stopper stops when the file exists and can remove it" do
      path = Path.join(System.tmp_dir!(), "gepa-stop-#{System.unique_integer([:positive])}")
      stopper = FileStopper.new(path)
      state = create_minimal_state()

      refute FileStopper.should_stop?(stopper, state)
      File.write!(path, "stop")
      assert FileStopper.should_stop?(stopper, state)
      assert :ok = FileStopper.remove_stop_file(stopper)
      refute File.exists?(path)
    end

    test "score threshold stops when best aggregate score reaches threshold" do
      state = create_state_with_score(0.8, iteration: 0)

      assert ScoreThreshold.should_stop?(ScoreThreshold.new(0.75), state)
      refute ScoreThreshold.should_stop?(ScoreThreshold.new(0.95), state)
    end

    test "max tracked candidates counts candidate programs" do
      state = create_minimal_state()

      assert MaxTrackedCandidates.should_stop?(MaxTrackedCandidates.new(1), state)
      refute MaxTrackedCandidates.should_stop?(MaxTrackedCandidates.new(2), state)
    end

    test "max candidate proposals uses upstream completed-proposal semantics" do
      state = %{create_minimal_state() | i: 2}

      assert MaxCandidateProposals.should_stop?(MaxCandidateProposals.new(3), state)
      refute MaxCandidateProposals.should_stop?(MaxCandidateProposals.new(4), state)
    end

    test "max reflection cost reads reported LM cost" do
      lm = %{total_cost: 1.25}
      state = create_minimal_state()

      assert MaxReflectionCost.should_stop?(MaxReflectionCost.new(1.0, lm), state)
      refute MaxReflectionCost.should_stop?(MaxReflectionCost.new(2.0, lm), state)
    end

    test "signal stopper can be tripped explicitly" do
      stopper = SignalStopper.new()
      state = create_minimal_state()

      refute SignalStopper.should_stop?(stopper, state)
      assert stopper |> SignalStopper.request_stop() |> SignalStopper.should_stop?(state)
    end

    test "composite supports any/all and recursively updates stateful children" do
      state = create_state_with_score(0.5, iteration: 1)

      any =
        Composite.new([
          ScoreThreshold.new(0.9),
          MaxTrackedCandidates.new(1)
        ])

      all =
        Composite.new(
          [
            ScoreThreshold.new(0.4),
            MaxTrackedCandidates.new(2)
          ],
          :all
        )

      assert GEPA.StopCondition.should_stop?(any, state)
      refute GEPA.StopCondition.should_stop?(all, state)

      no_improvement = NoImprovement.new(patience: 1)
      composite = Composite.new([no_improvement])
      updated = GEPA.StopCondition.update(composite, state)
      [%NoImprovement{best_score: 0.5}] = updated.conditions
    end

    test "custom function and module stoppers dispatch through GEPA.StopCondition" do
      state = create_minimal_state()

      assert GEPA.StopCondition.should_stop?(fn _state -> true end, state)
      assert GEPA.StopCondition.should_stop?(__MODULE__.AlwaysStopModule, state)
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

  defmodule AlwaysStopModule do
    def should_stop?(_state), do: true
  end
end
