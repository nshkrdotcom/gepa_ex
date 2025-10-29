defmodule GEPA.EvaluationBatchTest do
  use ExUnit.Case, async: true

  describe "new/1" do
    test "creates batch with required fields" do
      batch = %GEPA.EvaluationBatch{
        outputs: ["output1", "output2"],
        scores: [0.8, 0.9]
      }

      assert batch.outputs == ["output1", "output2"]
      assert batch.scores == [0.8, 0.9]
      assert batch.trajectories == nil
    end

    test "creates batch with trajectories" do
      batch = %GEPA.EvaluationBatch{
        outputs: ["output1"],
        scores: [1.0],
        trajectories: [%{step: 1}]
      }

      assert batch.trajectories == [%{step: 1}]
    end
  end

  describe "valid?/1" do
    test "returns true when outputs and scores have same length" do
      batch = %GEPA.EvaluationBatch{
        outputs: ["a", "b", "c"],
        scores: [0.1, 0.2, 0.3]
      }

      assert GEPA.EvaluationBatch.valid?(batch)
    end

    test "returns false when lengths don't match" do
      batch = %GEPA.EvaluationBatch{
        outputs: ["a", "b"],
        scores: [0.1, 0.2, 0.3]
      }

      refute GEPA.EvaluationBatch.valid?(batch)
    end

    test "returns true when trajectories match length" do
      batch = %GEPA.EvaluationBatch{
        outputs: ["a", "b"],
        scores: [0.1, 0.2],
        trajectories: [%{t: 1}, %{t: 2}]
      }

      assert GEPA.EvaluationBatch.valid?(batch)
    end

    test "returns false when trajectories length doesn't match" do
      batch = %GEPA.EvaluationBatch{
        outputs: ["a", "b"],
        scores: [0.1, 0.2],
        trajectories: [%{t: 1}]
      }

      refute GEPA.EvaluationBatch.valid?(batch)
    end
  end
end
