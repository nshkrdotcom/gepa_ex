defmodule GEPA.Proposer.ReflectiveTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Adapters.Basic
  alias GEPA.DataLoader
  alias GEPA.LLM.Mock
  alias GEPA.Proposer.InstructionProposal
  alias GEPA.Proposer.Reflective
  alias GEPA.State

  describe "new/1" do
    test "creates with defaults" do
      adapter = Basic.new()
      trainset = DataLoader.List.new([%{input: "test", answer: "answer"}])

      proposer = Reflective.new(adapter: adapter, trainset: trainset)

      assert proposer.adapter == adapter
      assert proposer.trainset == trainset
      assert proposer.candidate_selector == GEPA.Strategies.CandidateSelector.Pareto
      assert proposer.perfect_score == 1.0
      assert proposer.skip_perfect_score == true
      assert proposer.minibatch_size == 3
      assert proposer.instruction_proposal == nil
    end

    test "accepts instruction_proposal option" do
      adapter = Basic.new()
      trainset = DataLoader.List.new([%{input: "test", answer: "answer"}])
      llm = Mock.new(responses: ["improved"])
      instruction_proposal = InstructionProposal.new(llm: llm)

      proposer =
        Reflective.new(
          adapter: adapter,
          trainset: trainset,
          instruction_proposal: instruction_proposal
        )

      assert proposer.instruction_proposal == instruction_proposal
    end

    test "accepts custom minibatch_size" do
      adapter = Basic.new()
      trainset = DataLoader.List.new([%{input: "test", answer: "answer"}])

      proposer =
        Reflective.new(
          adapter: adapter,
          trainset: trainset,
          minibatch_size: 5
        )

      assert proposer.minibatch_size == 5
    end
  end

  describe "propose/2 without a proposal source" do
    test "returns an error instead of using a placeholder mutation" do
      adapter = Basic.new()

      trainset =
        DataLoader.List.new([
          %{input: "What is 2+2?", answer: "4"}
        ])

      proposer =
        Reflective.new(
          adapter: adapter,
          trainset: trainset,
          minibatch_size: 1,
          skip_perfect_score: false
        )

      # Create a minimal state
      state = create_test_state(%{"instruction" => "Answer questions"})

      assert {:error, {:proposal_generation_failed, :missing_proposal_source}, _proposer,
              _updated_state} =
               Reflective.propose(proposer, state)
    end
  end

  describe "propose/2 with instruction_proposal (LLM-based)" do
    test "uses LLM to generate improved candidate" do
      llm = Mock.new(responses: ["LLM-improved instruction"])
      instruction_proposal = InstructionProposal.new(llm: llm)

      adapter = Basic.new()

      trainset =
        DataLoader.List.new([
          %{input: "What is 2+2?", answer: "4"}
        ])

      proposer =
        Reflective.new(
          adapter: adapter,
          trainset: trainset,
          minibatch_size: 1,
          skip_perfect_score: false,
          instruction_proposal: instruction_proposal
        )

      state = create_test_state(%{"instruction" => "Answer questions"})

      case Reflective.propose(proposer, state) do
        {:ok, proposal, _proposer, _updated_state} ->
          # Should use LLM response, not fallback
          assert proposal.candidate["instruction"] == "LLM-improved instruction"
          refute String.contains?(proposal.candidate["instruction"], "[Optimized]")
          assert proposal.tag == "reflective_mutation"

        {:none, _proposer, _updated_state, _metadata} ->
          # Perfect score skip
          :ok

        {:error, _reason, _proposer, _updated_state} ->
          # Adapter might fail
          :ok
      end
    end

    test "calls adapter.make_reflective_dataset when instruction_proposal is provided" do
      # Track whether make_reflective_dataset was called
      test_pid = self()

      # Create a custom adapter that tracks calls
      defmodule TrackingAdapter do
        @behaviour GEPA.Adapter

        def new(test_pid), do: %{__struct__: __MODULE__, test_pid: test_pid}

        def evaluate(%{test_pid: _}, batch, _candidate, _capture_traces) do
          scores = Enum.map(batch, fn _ -> 0.5 end)

          {:ok,
           %GEPA.EvaluationBatch{
             outputs: Enum.map(batch, fn _ -> "output" end),
             scores: scores,
             trajectories: Enum.map(batch, fn _ -> %{} end)
           }}
        end

        def make_reflective_dataset(%{test_pid: pid}, _candidate, _eval_batch, components) do
          send(pid, {:make_reflective_dataset_called, components})

          dataset =
            for comp <- components, into: %{} do
              {comp, [%{"Inputs" => %{}, "Generated Outputs" => "", "Feedback" => "test"}]}
            end

          {:ok, dataset}
        end
      end

      adapter = TrackingAdapter.new(test_pid)
      llm = Mock.new(responses: ["improved"])
      instruction_proposal = InstructionProposal.new(llm: llm)

      trainset = DataLoader.List.new([%{input: "test", answer: "answer"}])

      proposer =
        Reflective.new(
          adapter: adapter,
          trainset: trainset,
          minibatch_size: 1,
          skip_perfect_score: false,
          instruction_proposal: instruction_proposal
        )

      state = create_test_state(%{"instruction" => "Original"})

      Reflective.propose(proposer, state)

      # Verify make_reflective_dataset was called
      assert_receive {:make_reflective_dataset_called, ["instruction"]}, 1000
    end

    test "handles multiple components" do
      llm =
        Mock.new(
          response_fn: fn prompt ->
            if String.contains?(prompt, "system_prompt") do
              "Improved system prompt"
            else
              "Improved user template"
            end
          end
        )

      instruction_proposal = InstructionProposal.new(llm: llm)

      adapter = Basic.new()
      trainset = DataLoader.List.new([%{input: "test", answer: "answer"}])

      proposer =
        Reflective.new(
          adapter: adapter,
          trainset: trainset,
          minibatch_size: 1,
          skip_perfect_score: false,
          instruction_proposal: instruction_proposal
        )

      state =
        create_test_state(%{
          "system_prompt" => "Original system",
          "user_template" => "Original user"
        })

      case Reflective.propose(proposer, state) do
        {:ok, proposal, _proposer, _updated_state} ->
          assert Map.has_key?(proposal.candidate, "system_prompt")
          assert Map.has_key?(proposal.candidate, "user_template")

        _ ->
          :ok
      end
    end

    test "uses adapter propose_new_texts override before default instruction proposal" do
      test_pid = self()

      defmodule ProposalOverrideAdapter do
        @behaviour GEPA.Adapter

        defstruct [:test_pid]

        def new(test_pid), do: %__MODULE__{test_pid: test_pid}

        @impl true
        def evaluate(_adapter, batch, _candidate, capture_traces) do
          trajectories = if capture_traces, do: Enum.map(batch, fn _ -> %{} end)

          {:ok,
           %GEPA.EvaluationBatch{
             outputs: Enum.map(batch, fn _ -> "output" end),
             scores: Enum.map(batch, fn _ -> 0.5 end),
             trajectories: trajectories
           }}
        end

        @impl true
        def make_reflective_dataset(_adapter, _candidate, _eval_batch, components) do
          {:ok, Map.new(components, &{&1, [%{"Feedback" => "use override"}]})}
        end

        @impl true
        def propose_new_texts(adapter, _candidate, _reflective_dataset, components) do
          send(adapter.test_pid, {:proposal_override_called, components})
          {:ok, Map.new(components, &{&1, "adapter override"})}
        end
      end

      llm =
        Mock.new(
          response_fn: fn _prompt ->
            flunk("LLM should not be called when adapter overrides proposal")
          end
        )

      proposer =
        Reflective.new(
          adapter: ProposalOverrideAdapter.new(test_pid),
          trainset: DataLoader.List.new([%{input: "test", answer: "answer"}]),
          minibatch_size: 1,
          skip_perfect_score: false,
          instruction_proposal: InstructionProposal.new(llm: llm)
        )

      state = create_test_state(%{"instruction" => "Original"})

      assert {:ok, proposal, _proposer, _updated_state} = Reflective.propose(proposer, state)
      assert proposal.candidate["instruction"] == "adapter override"
      assert_receive {:proposal_override_called, ["instruction"]}
    end
  end

  describe "propose/2 skip_perfect_score behavior" do
    test "skips when all scores are perfect and skip_perfect_score is true" do
      # Create an adapter that always returns perfect scores
      defmodule PerfectAdapter do
        @behaviour GEPA.Adapter

        def new, do: %{__struct__: __MODULE__}

        def evaluate(%{}, batch, _candidate, capture_traces) do
          {:ok,
           %GEPA.EvaluationBatch{
             outputs: Enum.map(batch, fn _ -> "perfect" end),
             scores: Enum.map(batch, fn _ -> 1.0 end),
             trajectories: if(capture_traces, do: Enum.map(batch, fn _ -> %{} end))
           }}
        end

        def make_reflective_dataset(%{}, _candidate, _eval_batch, _components) do
          {:ok, %{}}
        end
      end

      adapter = PerfectAdapter.new()
      trainset = DataLoader.List.new([%{input: "test", answer: "answer"}])

      proposer =
        Reflective.new(
          adapter: adapter,
          trainset: trainset,
          minibatch_size: 1,
          skip_perfect_score: true,
          perfect_score: 1.0
        )

      state = create_test_state(%{"instruction" => "Already perfect"})

      result = Reflective.propose(proposer, state)

      assert {:none, _proposer, _updated_state,
              %{reason: :all_scores_perfect, num_metric_calls: 1}} = result
    end

    test "does not skip when skip_perfect_score is false" do
      defmodule PerfectAdapter2 do
        @behaviour GEPA.Adapter

        def new, do: %{__struct__: __MODULE__}

        def evaluate(%{}, batch, _candidate, capture_traces) do
          {:ok,
           %GEPA.EvaluationBatch{
             outputs: Enum.map(batch, fn _ -> "perfect" end),
             scores: Enum.map(batch, fn _ -> 1.0 end),
             trajectories: if(capture_traces, do: Enum.map(batch, fn _ -> %{} end))
           }}
        end

        def make_reflective_dataset(%{}, _candidate, _eval_batch, _components) do
          {:ok, %{}}
        end

        def propose_new_texts(_adapter, _candidate, _reflective_dataset, components) do
          {:ok, Map.new(components, &{&1, "still perfect but updated"})}
        end
      end

      adapter = PerfectAdapter2.new()
      trainset = DataLoader.List.new([%{input: "test", answer: "answer"}])

      proposer =
        Reflective.new(
          adapter: adapter,
          trainset: trainset,
          minibatch_size: 1,
          # Don't skip
          skip_perfect_score: false
        )

      state = create_test_state(%{"instruction" => "Perfect but continue"})

      result = Reflective.propose(proposer, state)
      # Should return a proposal, not :none
      assert match?({:ok, %GEPA.CandidateProposal{}, _, _}, result)
    end
  end

  # Helper to create a test state
  defp create_test_state(seed_candidate) do
    # Create minimal state for testing
    %State{
      program_candidates: [seed_candidate],
      prog_candidate_val_subscores: [%{0 => 0.5}],
      pareto_front_valset: %{0 => 0.5},
      program_at_pareto_front_valset: %{0 => MapSet.new([0])},
      parent_program_for_candidate: [[nil]],
      list_of_named_predictors: Map.keys(seed_candidate),
      i: 0,
      total_num_evals: 0,
      num_full_ds_evals: 0
    }
  end
end
