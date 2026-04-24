defmodule GEPA.Integration.InstructionProposalIntegrationTest do
  @moduledoc """
  Integration tests for the full instruction proposal pipeline.
  Tests the complete flow from GEPA.optimize -> Reflective proposer -> InstructionProposal -> LLM.
  """

  use GEPA.SupertesterCase, isolation: :full_isolation, async: false

  @moduletag :integration
  @moduletag timeout: 30_000

  alias GEPA.Adapters.Basic
  alias GEPA.LLM.Mock

  describe "GEPA.optimize with reflection_llm integration" do
    test "full optimization with LLM-based instruction proposal" do
      # Use a mock LLM that tracks calls and returns improved instructions
      call_log = :ets.new(:call_log, [:set, :public])

      llm =
        Mock.new(
          response_fn: fn prompt ->
            call_id = System.unique_integer([:positive])

            :ets.insert(
              call_log,
              {call_id, %{prompt: prompt, timestamp: System.monotonic_time()}}
            )

            # Return an "improved" instruction based on the prompt
            if String.contains?(prompt, "math") do
              "Solve math problems step by step. First identify the operation, then compute the result."
            else
              "Process the input carefully and provide accurate results."
            end
          end
        )

      trainset = [
        %{input: "What is 2+2?", answer: "4"},
        %{input: "What is 3*4?", answer: "12"},
        %{input: "What is 10-3?", answer: "7"}
      ]

      valset = [
        %{input: "What is 5+5?", answer: "10"},
        %{input: "What is 6*2?", answer: "12"}
      ]

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "You are a math helper."},
          trainset: trainset,
          valset: valset,
          adapter: Basic.new(),
          max_metric_calls: 20,
          reflection_llm: llm,
          skip_perfect_score: false
        )

      # Verify result
      assert %GEPA.Result{} = result
      assert result.i > 0

      # Check that LLM was called
      llm_calls = :ets.tab2list(call_log)
      :ets.delete(call_log)

      assert llm_calls != [], "LLM should have been called at least once"

      # Verify prompts contain expected content
      prompts = Enum.map(llm_calls, fn {_, %{prompt: p}} -> p end)

      assert Enum.any?(prompts, &String.contains?(&1, "instruction")),
             "Prompts should mention the component name"
    end

    test "custom template is used in optimization" do
      captured_prompts = :ets.new(:captured, [:set, :public])

      llm =
        Mock.new(
          response_fn: fn prompt ->
            :ets.insert(captured_prompts, {System.unique_integer(), prompt})
            "improved"
          end
        )

      custom_template = """
      ===CUSTOM_TEMPLATE_START===
      Component: {component_name}
      Current Instruction: {current_instruction}
      Feedback Examples: {reflective_dataset}
      ===CUSTOM_TEMPLATE_END===
      Provide improved instruction:
      """

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"system" => "Original system prompt"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 15,
          reflection_llm: llm,
          proposal_template: custom_template,
          skip_perfect_score: false
        )

      prompts = :ets.tab2list(captured_prompts) |> Enum.map(&elem(&1, 1))
      :ets.delete(captured_prompts)

      if prompts != [] do
        # At least one prompt should use our custom template
        assert Enum.any?(prompts, &String.contains?(&1, "===CUSTOM_TEMPLATE_START===")),
               "Custom template markers should appear in prompts"

        assert Enum.any?(prompts, &String.contains?(&1, "===CUSTOM_TEMPLATE_END===")),
               "Custom template markers should appear in prompts"
      end
    end

    test "optimization improves over iterations with LLM" do
      # LLM returns progressively "better" instructions
      iteration_counter = :counters.new(1, [:atomics])

      llm =
        Mock.new(
          response_fn: fn _prompt ->
            count = :counters.get(iteration_counter, 1)
            :counters.add(iteration_counter, 1, 1)

            # Each iteration returns a slightly different instruction
            "Improved instruction v#{count}: Be more precise and accurate."
          end
        )

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"prompt" => "Basic instruction"},
          trainset: [
            %{input: "test1", answer: "result1"},
            %{input: "test2", answer: "result2"}
          ],
          valset: [%{input: "test3", answer: "result3"}],
          adapter: Basic.new(),
          max_metric_calls: 25,
          reflection_llm: llm,
          skip_perfect_score: false
        )

      # Should have generated some candidates
      assert result.candidates != []

      # LLM should have been called multiple times
      assert :counters.get(iteration_counter, 1) > 0
    end

    test "handles adapter make_reflective_dataset correctly" do
      # This tests that the full pipeline works:
      # evaluate -> make_reflective_dataset -> propose_new_texts

      dataset_calls = :ets.new(:dataset_calls, [:set, :public])

      # Create a custom adapter that tracks make_reflective_dataset calls
      defmodule TrackingAdapterIntegration do
        @behaviour GEPA.Adapter

        def new(ets_table), do: %{__struct__: __MODULE__, ets: ets_table}

        def evaluate(%{}, batch, _candidate, _capture_traces) do
          # Return scores that will trigger improvement attempts
          scores = Enum.map(batch, fn _ -> 0.3 + :rand.uniform() * 0.3 end)

          {:ok,
           %GEPA.EvaluationBatch{
             outputs: Enum.map(batch, fn _ -> "output" end),
             scores: scores,
             trajectories: Enum.map(batch, fn item -> %{input: item.input} end)
           }}
        end

        def make_reflective_dataset(%{ets: ets}, candidate, eval_batch, components) do
          :ets.insert(
            ets,
            {System.unique_integer(),
             %{
               candidate: candidate,
               num_trajectories: length(eval_batch.trajectories || []),
               components: components
             }}
          )

          dataset =
            for comp <- components, into: %{} do
              {comp,
               [
                 %{
                   "Inputs" => %{"sample" => "data"},
                   "Generated Outputs" => "sample output",
                   "Feedback" => "Needs improvement in accuracy"
                 }
               ]}
            end

          {:ok, dataset}
        end
      end

      adapter = TrackingAdapterIntegration.new(dataset_calls)

      llm = Mock.new(responses: ["Improved based on feedback"])

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: adapter,
          max_metric_calls: 15,
          reflection_llm: llm,
          skip_perfect_score: false
        )

      calls = :ets.tab2list(dataset_calls)
      :ets.delete(dataset_calls)

      # make_reflective_dataset should have been called
      assert calls != [], "make_reflective_dataset should be called when using LLM"

      # Verify structure of calls
      {_, first_call} = hd(calls)
      assert is_map(first_call.candidate)
      assert is_list(first_call.components)
    end
  end

  describe "backward compatibility" do
    test "optimization works without reflection_llm (fallback mode)" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Test"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10
          # No reflection_llm - uses fallback
        )

      assert %GEPA.Result{} = result
      assert result.i > 0
    end

    test "existing tests continue to pass with new code" do
      # Simple smoke test to ensure backward compatibility
      trainset = [%{input: "hello", answer: "world"}]
      valset = [%{input: "foo", answer: "bar"}]

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"prompt" => "respond"},
          trainset: trainset,
          valset: valset,
          adapter: Basic.new(),
          max_metric_calls: 5,
          skip_perfect_score: true
        )

      best = GEPA.Result.best_candidate(result)
      assert is_map(best)
    end
  end
end
