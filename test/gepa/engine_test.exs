defmodule GEPA.EngineTest do
  use GEPA.SupertesterCase, isolation: :full_isolation, async: false

  alias GEPA.Adapters.Basic
  alias GEPA.DataLoader.List, as: ListLoader
  alias GEPA.Engine
  alias GEPA.StopCondition.MaxCalls
  alias GEPA.Strategies.CandidateSelector.CurrentBest

  defmodule MetadataAdapter do
    @behaviour GEPA.Adapter

    defstruct [:metric_calls, :state_ref]

    def new(opts \\ []) do
      %__MODULE__{metric_calls: Keyword.get(opts, :metric_calls, 1), state_ref: opts[:state_ref]}
    end

    @impl true
    def evaluate(%__MODULE__{metric_calls: metric_calls}, batch, _candidate, _capture_traces) do
      {:ok,
       %GEPA.EvaluationBatch{
         outputs: Enum.map(batch, &{:output, &1.input}),
         scores: Enum.map(batch, fn _ -> 0.5 end),
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

  defmodule AlwaysStop do
    @behaviour GEPA.StopCondition

    defstruct []

    @impl true
    def should_stop?(_condition, _state), do: true
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
      run_dir: nil
    }
  end
end
