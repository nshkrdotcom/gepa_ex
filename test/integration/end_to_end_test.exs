defmodule GEPA.Integration.EndToEndTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 15000

  describe "GEPA.optimize/1" do
    test "completes full optimization run" do
      # Simple Q&A data
      trainset = [
        %{input: "What is 2+2?", answer: "4"},
        %{input: "What is 3+3?", answer: "6"},
        %{input: "What is 4+4?", answer: "8"}
      ]

      valset = [
        %{input: "What is 5+5?", answer: "10"},
        %{input: "What is 6+6?", answer: "12"}
      ]

      seed_candidate = %{"instruction" => "You are a helpful math assistant."}

      # Run optimization
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: seed_candidate,
          trainset: trainset,
          valset: valset,
          adapter: GEPA.Adapters.Basic.new(),
          max_metric_calls: 15
        )

      # Verify result structure
      assert %GEPA.Result{} = result
      assert length(result.candidates) >= 1
      assert hd(result.candidates) == seed_candidate
      assert result.i > 0
      assert result.total_num_evals > 0
    end

    test "returns best candidate and score" do
      trainset = [%{input: "Q", answer: "A"}]
      valset = [%{input: "Q2", answer: "A2"}]

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Help"},
          trainset: trainset,
          valset: valset,
          adapter: GEPA.Adapters.Basic.new(),
          max_metric_calls: 10
        )

      # Should have best candidate
      best = GEPA.Result.best_candidate(result)
      assert is_map(best)
      assert Map.has_key?(best, "instruction")

      # Should have best score
      best_score = GEPA.Result.best_score(result)
      assert is_float(best_score)
      assert best_score >= 0.0
    end

    test "respects max_metric_calls budget" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: GEPA.Adapters.Basic.new(),
          max_metric_calls: 8
        )

      # Should respect budget (may be slightly over due to minibatches)
      assert result.total_num_evals <= 12
    end

    test "handles single iteration gracefully" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"i" => "seed"},
          trainset: [%{input: "1", answer: "1"}],
          valset: [%{input: "2", answer: "2"}],
          adapter: GEPA.Adapters.Basic.new(),
          max_metric_calls: 3
        )

      assert result.i >= 0
      assert length(result.candidates) >= 1
    end
  end

  describe "GEPA.optimize/1 with persistence" do
    @tag timeout: 20000
    test "saves and can resume from state" do
      run_dir = create_temp_dir()

      trainset = [%{input: "Q1", answer: "A1"}]
      valset = [%{input: "Q2", answer: "A2"}]

      # First run
      {:ok, result1} =
        GEPA.optimize(
          seed_candidate: %{"i" => "initial"},
          trainset: trainset,
          valset: valset,
          adapter: GEPA.Adapters.Basic.new(),
          max_metric_calls: 6,
          run_dir: run_dir
        )

      # State file should exist
      state_file = Path.join(run_dir, "gepa_state.etf")
      assert File.exists?(state_file)

      # Second run with same dir should load state
      {:ok, result2} =
        GEPA.optimize(
          # Different seed
          seed_candidate: %{"i" => "different"},
          trainset: trainset,
          valset: valset,
          adapter: GEPA.Adapters.Basic.new(),
          max_metric_calls: 10,
          run_dir: run_dir
        )

      # Should have resumed from saved state
      # (would have same iteration count or higher)
      assert result2.i >= result1.i

      # Cleanup
      File.rm_rf!(run_dir)
    end
  end

  # Helper
  defp create_temp_dir do
    dir = Path.join(System.tmp_dir!(), "gepa_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    dir
  end
end
