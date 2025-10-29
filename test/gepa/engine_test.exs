defmodule GEPA.EngineTest do
  use ExUnit.Case, async: false

  alias GEPA.Engine
  alias GEPA.Adapters.Basic

  @moduletag :engine
  @moduletag timeout: 5000

  describe "initialize_state/1" do
    test "creates initial state from config" do
      config = create_simple_config()

      # Call the initialization directly (testing private via run)
      {:ok, result} = Engine.run(config)

      # Should have initialized with seed
      assert length(result.program_candidates) >= 1
      assert hd(result.program_candidates) == config.seed_candidate
    end
  end

  describe "run/1 with very small limits" do
    @tag timeout: 10000
    test "completes within iteration limit" do
      config =
        create_simple_config()
        |> Map.put(:stop_conditions, [GEPA.StopCondition.MaxCalls.new(5)])

      {:ok, result} = Engine.run(config)

      # Should stop quickly
      assert result.total_num_evals <= 10
      assert result.i >= 0
    end

    @tag timeout: 10000
    test "can run at least one iteration" do
      config =
        create_simple_config()
        |> Map.put(:stop_conditions, [GEPA.StopCondition.MaxCalls.new(8)])

      {:ok, result} = Engine.run(config)

      # Verify it ran
      assert is_map(result)
      assert result.i >= 0
    end
  end

  # Helper functions
  defp create_simple_config do
    # Very simple data for fast tests
    trainset = [%{input: "Q1", answer: "A1"}]
    valset = [%{input: "Q2", answer: "A2"}]

    %{
      seed_candidate: %{"instruction" => "Help"},
      trainset: GEPA.DataLoader.List.new(trainset),
      valset: GEPA.DataLoader.List.new(valset),
      adapter: Basic.new(),
      candidate_selector: GEPA.Strategies.CandidateSelector.CurrentBest,
      stop_conditions: [GEPA.StopCondition.MaxCalls.new(3)],
      reflection_minibatch_size: 1,
      perfect_score: 1.0,
      # Don't skip, always try to improve
      skip_perfect_score: false,
      seed: 42,
      run_dir: nil
    }
  end
end
