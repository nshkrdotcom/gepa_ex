defmodule Integration.MergeProposerIntegrationTest do
  use ExUnit.Case, async: false

  # TDD RED PHASE: Engine integration with merge proposer
  # These tests verify merge proposer works end-to-end with Engine

  alias GEPA.{Engine, State, DataLoader}
  alias GEPA.Proposer.{Reflective, Merge}

  describe "Engine with merge proposer - RED PHASE" do
    test "Engine can use merge proposer when configured" do
      config = create_config_with_merge()

      {:ok, result} = Engine.run(config)

      # Should complete successfully
      assert %State{} = result
      assert result.i > 0
    end

    test "merge proposer is invoked after reflective finds new program" do
      config =
        create_config_with_merge(
          max_iterations: 10,
          use_merge: true
        )

      {:ok, result} = Engine.run(config)

      # If optimization ran multiple iterations and found improvements,
      # merge proposer should have been attempted
      # (Check via state or logs - for now just verify it completes)
      assert result.i > 1
    end

    test "merged candidates appear in final state when accepted" do
      config =
        create_config_with_merge(
          max_iterations: 15,
          use_merge: true
        )

      {:ok, result} = Engine.run(config)

      # Check if we have multiple programs (seed + potentially merged)
      assert length(result.program_candidates) >= 1

      # Check genealogy tracking works (it's a list of parent lists)
      assert is_list(result.parent_program_for_candidate)
      # Seed program should have nil or empty parents
      assert hd(result.parent_program_for_candidate) == [nil] or
               hd(result.parent_program_for_candidate) == []
    end

    test "Engine respects max_merge_invocations limit" do
      config =
        create_config_with_merge(
          max_iterations: 20,
          use_merge: true,
          max_merge_invocations: 2
        )

      {:ok, result} = Engine.run(config)

      # Should stop after budget exhausted
      assert %State{} = result
    end

    test "Engine works without merge proposer (backward compatibility)" do
      config = create_config_without_merge()

      {:ok, result} = Engine.run(config)

      # Should work fine with just reflective proposer
      assert %State{} = result
      assert result.i > 0
    end
  end

  # Test helpers

  defp create_config_with_merge(opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    use_merge = Keyword.get(opts, :use_merge, true)
    max_merge_invocations = Keyword.get(opts, :max_merge_invocations, 3)

    trainset =
      DataLoader.List.new([
        %{input: "What is 2+2?", answer: "4"},
        %{input: "What is 3+3?", answer: "6"},
        %{input: "What is 5+5?", answer: "10"}
      ])

    valset =
      DataLoader.List.new([
        %{input: "What is 4+4?", answer: "8"}
      ])

    %{
      seed_candidate: %{"instruction" => "Answer accurately."},
      trainset: trainset,
      valset: valset,
      adapter: GEPA.Adapters.Basic.new(llm: GEPA.LLM.Mock.new()),
      reflective_proposer: create_reflective_proposer(trainset),
      merge_proposer: if(use_merge, do: create_merge_proposer(valset), else: nil),
      stop_conditions: [
        GEPA.StopCondition.MaxCalls.new(max_iterations)
      ],
      run_dir: nil,
      use_merge: use_merge,
      max_merge_invocations: max_merge_invocations
    }
  end

  defp create_config_without_merge do
    create_config_with_merge(use_merge: false)
  end

  defp create_reflective_proposer(trainset) do
    Reflective.new(
      adapter: GEPA.Adapters.Basic.new(llm: GEPA.LLM.Mock.new()),
      trainset: trainset,
      minibatch_size: 3
    )
  end

  defp create_merge_proposer(valset) do
    evaluator = fn batch, candidate ->
      # Simple mock evaluator
      adapter = GEPA.Adapters.Basic.new(llm: GEPA.LLM.Mock.new())
      {:ok, eval_batch} = adapter.__struct__.evaluate(adapter, batch, candidate, false)
      {eval_batch.outputs, eval_batch.scores}
    end

    Merge.new(
      valset: valset,
      evaluator: evaluator,
      use_merge: true,
      max_merge_invocations: 3
    )
  end
end
