defmodule GEPA.EngineTest do
  use GEPA.SupertesterCase, isolation: :full_isolation, async: false

  alias GEPA.Adapters.Basic
  alias GEPA.DataLoader.List, as: ListLoader
  alias GEPA.Engine
  alias GEPA.StopCondition.{MaxCalls, MaxCandidateProposals}
  alias GEPA.Strategies.CandidateSelector.CurrentBest
  alias GEPA.Strategies.EvaluationPolicy.Full

  defmodule MetadataAdapter do
    @behaviour GEPA.Adapter

    defstruct [:metric_calls, :state_ref]

    def new(opts \\ []) do
      %__MODULE__{metric_calls: Keyword.get(opts, :metric_calls, 1), state_ref: opts[:state_ref]}
    end

    @impl true
    def evaluate(%__MODULE__{metric_calls: metric_calls}, batch, _candidate, capture_traces) do
      {:ok,
       %GEPA.EvaluationBatch{
         outputs: Enum.map(batch, &{:output, &1.input}),
         scores: Enum.map(batch, fn _ -> 0.5 end),
         trajectories: if(capture_traces, do: Enum.map(batch, &%{input: &1.input})),
         objective_scores: Enum.map(batch, fn _ -> %{"accuracy" => 0.5} end),
         num_metric_calls: metric_calls
       }}
    end

    @impl true
    def make_reflective_dataset(_adapter, candidate, eval_batch, components) do
      {:ok,
       Map.new(components, fn component ->
         {component,
          [
            %{
              "Generated Outputs" => candidate[component],
              "Feedback" => inspect(eval_batch.outputs)
            }
          ]}
       end)}
    end

    @impl true
    def propose_new_texts(_adapter, candidate, _reflective_dataset, components) do
      {:ok, Map.new(components, &{&1, candidate[&1] <> " updated"})}
    end

    @impl true
    def get_adapter_state(%__MODULE__{state_ref: nil}), do: %{}

    def get_adapter_state(%__MODULE__{state_ref: ref}), do: Agent.get(ref, & &1)
  end

  defmodule NoCallAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def evaluate(_adapter, _batch, _candidate, _capture_traces) do
      raise "adapter should not be called for cached evaluation"
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _eval_batch, _components) do
      {:ok, %{}}
    end
  end

  defmodule PerfectAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def evaluate(_adapter, batch, _candidate, capture_traces) do
      trajectories =
        if capture_traces do
          Enum.map(batch, &%{input: &1.input, feedback: "perfect"})
        end

      {:ok,
       %GEPA.EvaluationBatch{
         outputs: Enum.map(batch, &{:output, &1.input}),
         scores: Enum.map(batch, fn _ -> 1.0 end),
         trajectories: trajectories,
         num_metric_calls: length(batch)
       }}
    end

    @impl true
    def make_reflective_dataset(_adapter, candidate, _eval_batch, components) do
      {:ok, Map.new(components, &{&1, [%{"Generated Outputs" => candidate[&1]}]})}
    end
  end

  defmodule ErrorAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def evaluate(_adapter, _batch, _candidate, _capture_traces), do: {:error, :boom}

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _eval_batch, _components), do: {:ok, %{}}
  end

  defmodule RestorableAdapter do
    @behaviour GEPA.Adapter

    defstruct [:state_ref]

    def new(state_ref), do: %__MODULE__{state_ref: state_ref}

    @impl true
    def evaluate(_adapter, batch, _candidate, _capture_traces) do
      {:ok,
       %GEPA.EvaluationBatch{
         outputs: Enum.map(batch, &{:output, &1.input}),
         scores: Enum.map(batch, fn _ -> 0.5 end),
         num_metric_calls: length(batch)
       }}
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _eval_batch, _components), do: {:ok, %{}}

    @impl true
    def get_adapter_state(%__MODULE__{state_ref: state_ref}) do
      Agent.get(state_ref, & &1)
    end

    @impl true
    def set_adapter_state(%__MODULE__{state_ref: state_ref}, state) do
      Agent.update(state_ref, fn _old_state -> state end)
    end
  end

  defmodule AlwaysStop do
    @behaviour GEPA.StopCondition

    defstruct []

    @impl true
    def should_stop?(_condition, _state), do: true
  end

  defmodule FirstOnlyValPolicy do
    @behaviour GEPA.Strategies.EvaluationPolicy

    @impl true
    def get_eval_batch(valset_loader, _state, _target_program_idx) do
      valset_loader |> GEPA.DataLoader.all_ids() |> Enum.take(1)
    end

    @impl true
    def get_best_program(state), do: Full.get_best_program(state)

    @impl true
    def get_valset_score(program_idx, state) do
      Full.get_valset_score(program_idx, state)
    end
  end

  @moduletag :engine
  @moduletag timeout: 5_000

  describe "initialize_state/1" do
    test "creates initial state from config" do
      config = create_simple_config()

      # Call the initialization directly (testing private via run)
      {:ok, result} = Engine.run(config)

      # Should have initialized with seed
      assert result.program_candidates != []
      assert hd(result.program_candidates) == config.seed_candidate
    end
  end

  describe "run/1 with very small limits" do
    @tag timeout: 10_000
    test "completes within iteration limit" do
      config =
        create_simple_config()
        |> Map.put(:stop_conditions, [MaxCalls.new(5)])

      {:ok, result} = Engine.run(config)

      # Should stop quickly
      assert result.total_num_evals <= 10
      assert result.i >= 0
    end

    @tag timeout: 10_000
    test "can run at least one iteration" do
      config =
        create_simple_config()
        |> Map.put(:stop_conditions, [MaxCalls.new(8)])

      {:ok, result} = Engine.run(config)

      # Verify it ran
      assert is_map(result)
      assert result.i >= 0
    end
  end

  describe "upstream metadata parity" do
    test "first optimization iteration has internal index 0 and public callback iteration 1" do
      test_pid = self()

      callback = fn
        :iteration_start, event ->
          send(test_pid, {:iteration_start, event.iteration, event.state.i})

        _event, _payload ->
          :ok
      end

      config =
        create_simple_config()
        |> Map.put(:adapter, PerfectAdapter.new())
        |> Map.put(:stop_conditions, [MaxCandidateProposals.new(1)])
        |> Map.put(:callbacks, [callback])
        |> Map.put(:skip_perfect_score, true)

      {:ok, result} = Engine.run(config)

      assert result.i == 0
      assert_receive {:iteration_start, 1, 0}
    end

    test "counts only actual current-evaluation metric calls when no proposal is generated" do
      state =
        GEPA.State.new(
          %{"instruction" => "Help"},
          %GEPA.EvaluationBatch{outputs: ["seed"], scores: [0.5], num_metric_calls: 1},
          [0]
        )

      config =
        create_simple_config()
        |> Map.put(:adapter, PerfectAdapter.new())
        |> Map.put(:stop_conditions, [MaxCalls.new(10)])
        |> Map.put(:skip_perfect_score, true)

      {:cont, new_state, _config, false, nil} = Engine.run_iteration(state, config)

      assert new_state.total_num_evals == state.total_num_evals + 1
    end

    test "uses proposal evaluation metric-call metadata for budget accounting" do
      state =
        GEPA.State.new(
          %{"instruction" => "Help"},
          %GEPA.EvaluationBatch{outputs: ["seed"], scores: [0.1], num_metric_calls: 1},
          [0]
        )

      config =
        create_simple_config()
        |> Map.put(:adapter, MetadataAdapter.new(metric_calls: 7))
        |> Map.put(:stop_conditions, [MaxCalls.new(100)])
        |> Map.put(:skip_perfect_score, false)

      {:cont, new_state, _config, false, "reflective_mutation"} =
        Engine.run_iteration(state, config)

      assert new_state.total_num_evals == state.total_num_evals + 14
    end

    test "uses validation evaluation policy for accepted candidate full eval" do
      state =
        GEPA.State.new(
          %{"instruction" => "Help"},
          %GEPA.EvaluationBatch{outputs: ["seed-0", "seed-1"], scores: [0.1, 0.2]},
          [0, 1]
        )

      config =
        create_simple_config()
        |> Map.put(
          :valset,
          ListLoader.new([%{input: "Q2", answer: "A2"}, %{input: "Q3", answer: "A3"}])
        )
        |> Map.put(:adapter, MetadataAdapter.new(metric_calls: 1))
        |> Map.put(:stop_conditions, [MaxCalls.new(100)])
        |> Map.put(:skip_perfect_score, false)
        |> Map.put(:acceptance_criterion, :improvement_or_equal)
        |> Map.put(:val_evaluation_policy, FirstOnlyValPolicy)

      {:cont, new_state, _config, true, "reflective_mutation"} =
        Engine.run_iteration(state, config)

      new_scores = Enum.at(new_state.prog_candidate_val_subscores, 1)
      assert Map.keys(new_scores) == [0]
      assert new_state.total_num_evals == state.total_num_evals + 3
    end

    test "raises reflective proposal errors when raise_on_exception is true" do
      state =
        GEPA.State.new(
          %{"instruction" => "Help"},
          %GEPA.EvaluationBatch{outputs: ["seed"], scores: [0.1], num_metric_calls: 1},
          [0]
        )

      config =
        create_simple_config()
        |> Map.put(:adapter, ErrorAdapter.new())
        |> Map.put(:stop_conditions, [MaxCalls.new(100)])
        |> Map.put(:raise_on_exception, true)

      assert_raise RuntimeError, ~r/Reflective proposal failed: :boom/, fn ->
        Engine.run_iteration(state, config)
      end
    end

    test "continues after reflective proposal errors when raise_on_exception is false" do
      state =
        GEPA.State.new(
          %{"instruction" => "Help"},
          %GEPA.EvaluationBatch{outputs: ["seed"], scores: [0.1], num_metric_calls: 1},
          [0]
        )

      config =
        create_simple_config()
        |> Map.put(:adapter, ErrorAdapter.new())
        |> Map.put(:stop_conditions, [MaxCalls.new(100)])
        |> Map.put(:raise_on_exception, false)

      {:cont, new_state, _config, false, nil} = Engine.run_iteration(state, config)

      assert new_state.total_num_evals == state.total_num_evals
    end

    test "uses evaluation batch metric calls for seed budget accounting" do
      config =
        create_simple_config()
        |> Map.put(:adapter, MetadataAdapter.new(metric_calls: 7))
        |> Map.put(:stop_conditions, [MaxCalls.new(1)])

      {:ok, result} = Engine.run(config)

      assert result.total_num_evals == 7
    end

    test "initializes best outputs and objective frontiers from config" do
      config =
        create_simple_config()
        |> Map.put(:adapter, MetadataAdapter.new())
        |> Map.put(:stop_conditions, [MaxCalls.new(1)])
        |> Map.put(:track_best_outputs, true)
        |> Map.put(:frontier_type, :objective)

      {:ok, result} = Engine.run(config)

      assert result.best_outputs_valset == %{0 => [{0, {:output, "Q2"}}]}
      assert result.objective_pareto_front == %{"accuracy" => 0.5}
      assert result.program_at_pareto_front_objectives == %{"accuracy" => MapSet.new([0])}
    end

    test "syncs adapter state before checkpoint save" do
      {:ok, state_ref} = Agent.start_link(fn -> %{counter: 3} end)

      run_dir =
        Path.join(
          System.tmp_dir!(),
          "gepa_engine_adapter_state_#{System.unique_integer([:positive])}"
        )

      on_exit(fn ->
        if Process.alive?(state_ref), do: Agent.stop(state_ref)
        File.rm_rf(run_dir)
      end)

      config =
        create_simple_config()
        |> Map.put(:adapter, MetadataAdapter.new(state_ref: state_ref))
        |> Map.put(:stop_conditions, [MaxCalls.new(1)])
        |> Map.put(:run_dir, run_dir)

      {:ok, _result} = Engine.run(config)
      saved_state = File.read!(Path.join(run_dir, "gepa_state.etf")) |> :erlang.binary_to_term()
      candidates = File.read!(Path.join(run_dir, "candidates.json")) |> Jason.decode!()

      assert saved_state.adapter_state == %{counter: 3}
      assert candidates == [%{"instruction" => "Help"}]
    end

    test "uses cached seed validation without adapter calls" do
      cache =
        GEPA.EvaluationCache.new()
        |> GEPA.EvaluationCache.put(%{"instruction" => "Help"}, 0, "cached-output", 0.75)

      config =
        create_simple_config()
        |> Map.put(:adapter, NoCallAdapter.new())
        |> Map.put(:evaluation_cache, cache)
        |> Map.put(:stop_conditions, [%AlwaysStop{}])

      {:ok, result} = Engine.run(config)

      assert result.total_num_evals == 0
      assert result.prog_candidate_val_subscores == [%{0 => 0.75}]
    end

    test "rejects resume when frontier type mismatches saved state" do
      run_dir =
        Path.join(
          System.tmp_dir!(),
          "gepa_engine_frontier_mismatch_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(run_dir) end)

      config =
        create_simple_config()
        |> Map.put(:adapter, MetadataAdapter.new())
        |> Map.put(:stop_conditions, [MaxCalls.new(1)])
        |> Map.put(:run_dir, run_dir)
        |> Map.put(:frontier_type, :instance)

      {:ok, _result} = Engine.run(config)

      assert_raise ArgumentError, ~r/Frontier type mismatch/, fn ->
        config
        |> Map.put(:frontier_type, :objective)
        |> Engine.run()
      end
    end

    test "restores adapter state when resuming from run_dir" do
      {:ok, state_ref} = Agent.start_link(fn -> %{counter: 3} end)

      run_dir =
        Path.join(
          System.tmp_dir!(),
          "gepa_engine_restore_adapter_#{System.unique_integer([:positive])}"
        )

      on_exit(fn ->
        if Process.alive?(state_ref), do: Agent.stop(state_ref)
        File.rm_rf(run_dir)
      end)

      adapter = RestorableAdapter.new(state_ref)

      config =
        create_simple_config()
        |> Map.put(:adapter, adapter)
        |> Map.put(:stop_conditions, [MaxCalls.new(1)])
        |> Map.put(:run_dir, run_dir)

      {:ok, _result} = Engine.run(config)
      Agent.update(state_ref, fn _state -> %{counter: 0} end)

      {:ok, _result} = Engine.run(config)

      assert Agent.get(state_ref, & &1) == %{counter: 3}
    end
  end

  # Helper functions
  defp create_simple_config do
    # Very simple data for fast tests
    trainset = [%{input: "Q1", answer: "A1"}]
    valset = [%{input: "Q2", answer: "A2"}]

    %{
      seed_candidate: %{"instruction" => "Help"},
      trainset: ListLoader.new(trainset),
      valset: ListLoader.new(valset),
      adapter: Basic.new(),
      candidate_selector: CurrentBest,
      stop_conditions: [MaxCalls.new(3)],
      reflection_minibatch_size: 1,
      perfect_score: 1.0,
      # Don't skip, always try to improve
      skip_perfect_score: false,
      seed: 42,
      run_dir: nil,
      custom_candidate_proposer: fn candidate, _reflective_dataset, components ->
        Map.new(components, &{&1, candidate[&1] <> " updated"})
      end
    }
  end
end
