defmodule GEPA.StateParityTest do
  use GEPA.SupertesterCase, isolation: :full_isolation, async: false

  alias GEPA.Adapter.Dispatch
  alias GEPA.DataLoader.List, as: ListLoader
  alias GEPA.EvaluationBatch
  alias GEPA.State
  alias GEPA.StopCondition.MaxCalls

  defmodule FixedAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    @impl true
    def evaluate(%__MODULE__{}, batch, _candidate, capture_traces) do
      outputs =
        Enum.map(batch, fn item ->
          item[:output] || item["output"] || %{"id" => item[:id] || item["id"]}
        end)

      scores = Enum.map(batch, &(Map.get(&1, :score, Map.get(&1, "score", 0.5)) * 1.0))

      trajectories =
        if capture_traces do
          Enum.map(batch, &%{input: &1})
        end

      {:ok,
       %EvaluationBatch{
         outputs: outputs,
         scores: scores,
         trajectories: trajectories,
         num_metric_calls: length(batch)
       }}
    end

    @impl true
    def make_reflective_dataset(%__MODULE__{}, _candidate, _eval_batch, components) do
      {:ok, Map.new(components, &{&1, []})}
    end
  end

  defmodule StatefulAdapter do
    @behaviour GEPA.Adapter

    defstruct [:state_ref]

    @impl true
    def evaluate(%__MODULE__{}, batch, _candidate, _capture_traces) do
      {:ok,
       %EvaluationBatch{
         outputs: Enum.map(batch, &%{"id" => &1.id}),
         scores: Enum.map(batch, fn _ -> 0.5 end),
         num_metric_calls: length(batch)
       }}
    end

    @impl true
    def make_reflective_dataset(%__MODULE__{}, _candidate, _eval_batch, components) do
      {:ok, Map.new(components, &{&1, []})}
    end

    @impl true
    def get_adapter_state(%__MODULE__{state_ref: ref}), do: Agent.get(ref, & &1)

    @impl true
    def set_adapter_state(%__MODULE__{state_ref: ref}, state) do
      Agent.update(ref, fn _old_state -> state end)
    end
  end

  describe "upstream state initialization parity" do
    test "fresh run with a run_dir writes state, candidates, and seed outputs" do
      run_dir = tmp_dir("fresh")

      {:ok, state} =
        engine_config(
          valset: [
            %{id: 0, output: "out0", score: 0.1},
            %{id: 1, output: %{"k" => "out1"}, score: 0.2}
          ],
          max_calls: 2,
          run_dir: run_dir
        )
        |> GEPA.Engine.run()

      assert %State{} = state
      assert state.num_full_ds_evals == 1
      assert state.total_num_evals == 2
      assert File.exists?(Path.join(run_dir, "gepa_state.etf"))

      assert Jason.decode!(File.read!(Path.join(run_dir, "candidates.json"))) == [
               %{"model" => "m"}
             ]

      assert Jason.decode!(File.read!(best_output_path(run_dir, 0, 0, 0))) == "out0"
      assert Jason.decode!(File.read!(best_output_path(run_dir, 1, 0, 0))) == %{"k" => "out1"}
    end

    test "fresh state without a run_dir initializes without persistence" do
      state = seed_state(outputs: ["out"], scores: [0.5], valset_ids: [0])

      assert %State{} = state
      assert state.num_full_ds_evals == 1
      assert state.total_num_evals == 1
      assert state.program_candidates == [%{"model" => "m"}]
    end
  end

  describe "upstream state persistence parity" do
    test "state save and load round-trip optimizer state" do
      run_dir = tmp_dir("round-trip")

      state =
        seed_state(outputs: [%{"x" => 1}, %{"y" => 2}], scores: [0.3, 0.7], valset_ids: [0, 1])
        |> Map.put(:num_full_ds_evals, 3)
        |> Map.put(:total_num_evals, 10)

      assert State.consistent?(state)
      assert :ok = State.save(state, run_dir)
      assert {:ok, loaded} = State.load(run_dir)

      assert Map.drop(Map.from_struct(loaded), [:budget_hooks]) ==
               Map.drop(Map.from_struct(state), [:budget_hooks])
    end

    test "runtime budget hooks are excluded from serialization" do
      run_dir = tmp_dir("budget-hooks")

      state =
        seed_state(outputs: [%{"x" => 1}], scores: [0.3], valset_ids: [0])
        |> Map.put(:num_full_ds_evals, 3)
        |> Map.put(:total_num_evals, 10)
        |> State.add_budget_hook(fn total, delta -> send(self(), {:hook, total, delta}) end)

      state = State.increment_evals(state, 5)
      assert_receive {:hook, 15, 5}

      assert :ok = State.save(state, run_dir)
      assert {:ok, loaded} = State.load(run_dir)
      refute Map.has_key?(Map.from_struct(loaded), :_budget_hooks)
      assert loaded.budget_hooks == []

      loaded = State.increment_evals(loaded, 3)
      refute_receive {:hook, _, _}
      assert loaded.total_num_evals == 18

      loaded =
        State.add_budget_hook(loaded, fn total, delta ->
          send(self(), {:loaded_hook, total, delta})
        end)

      assert %{total_num_evals: 20} = State.increment_evals(loaded, 2)
      assert_receive {:loaded_hook, 20, 2}
    end

    test "legacy map payloads are migrated when loaded" do
      run_dir = tmp_dir("legacy")
      File.mkdir_p!(run_dir)

      legacy = %{
        "program_candidates" => [%{"a" => "b"}],
        "parent_program_for_candidate" => [[nil]],
        "prog_candidate_val_subscores" => [[0.1, 0.2]],
        "pareto_front_valset" => [0.1, 0.2],
        "program_at_pareto_front_valset" => [[0], [0]],
        "list_of_named_predictors" => ["a"],
        "named_predictor_id_to_update_next_for_program_candidate" => [0],
        "num_metric_calls_by_discovery" => [0],
        "num_full_ds_evals" => 1,
        "total_num_evals" => 2,
        "validation_schema_version" => 1
      }

      File.write!(Path.join(run_dir, "gepa_state.etf"), :erlang.term_to_binary(legacy))

      assert {:ok, loaded} = State.load(run_dir)
      assert loaded.prog_candidate_val_subscores == [%{0 => 0.1, 1 => 0.2}]
      assert loaded.pareto_front_valset == %{0 => 0.1, 1 => 0.2}

      assert loaded.program_at_pareto_front_valset == %{
               0 => MapSet.new([0]),
               1 => MapSet.new([0])
             }

      assert loaded.adapter_state == %{}
      assert loaded.validation_schema_version == State.validation_schema_version()
    end

    test "upgrade_dict adds adapter_state and current schema fields" do
      upgraded =
        State.upgrade_dict(%{
          program_candidates: [%{"a" => "b"}],
          prog_candidate_val_subscores: [%{0 => 1.0}],
          pareto_front_valset: %{0 => 1.0},
          program_at_pareto_front_valset: %{0 => [0]},
          list_of_named_predictors: ["a"]
        })

      assert upgraded.adapter_state == %{}
      assert upgraded.validation_schema_version == State.validation_schema_version()
      assert upgraded.prog_candidate_objective_scores == [%{}]
      assert upgraded.program_at_pareto_front_valset == %{0 => MapSet.new([0])}
    end
  end

  describe "upstream adapter state parity" do
    test "fresh state defaults adapter_state to an empty map" do
      assert seed_state().adapter_state == %{}
    end

    test "adapter_state round-trips through save and load" do
      run_dir = tmp_dir("adapter-state")

      state =
        seed_state()
        |> Map.put(:adapter_state, %{"key" => "value", "nested" => %{"a" => [1, 2, 3]}})

      assert :ok = State.save(state, run_dir)
      assert {:ok, loaded} = State.load(run_dir)
      assert loaded.adapter_state == %{"key" => "value", "nested" => %{"a" => [1, 2, 3]}}
    end

    test "default adapters do not expose adapter state callbacks" do
      refute function_exported?(GEPA.Adapters.Default, :get_adapter_state, 1)
      refute function_exported?(GEPA.Adapters.Default, :set_adapter_state, 2)
    end

    test "dispatch state sync is a no-op for adapters without state callbacks" do
      adapter = %FixedAdapter{}

      assert Dispatch.get_adapter_state(adapter) == %{}
      assert Dispatch.set_adapter_state(adapter, %{"ignored" => true}) == :ok
      assert Dispatch.get_adapter_state(adapter) == %{}
    end

    test "engine restores opaque adapter state from a prior run" do
      {:ok, state_ref} = Agent.start_link(fn -> %{counter: 3} end)
      run_dir = tmp_dir("adapter-restore")

      on_exit(fn ->
        if Process.alive?(state_ref), do: Agent.stop(state_ref)
      end)

      adapter = %StatefulAdapter{state_ref: state_ref}

      assert {:ok, _state} =
               engine_config(adapter: adapter, max_calls: 1, run_dir: run_dir)
               |> GEPA.Engine.run()

      Agent.update(state_ref, fn _state -> %{counter: 0} end)

      assert {:ok, _state} =
               engine_config(adapter: adapter, max_calls: 0, run_dir: run_dir)
               |> GEPA.Engine.run()

      assert Agent.get(state_ref, & &1) == %{counter: 3}
    end
  end

  describe "upstream sparse validation and resume parity" do
    test "state reports validation ids covered by sparse program scores" do
      state =
        seed_state(outputs: ["out0", "out1"], scores: [0.5, 0.6], valset_ids: [0, 1])
        |> then(fn state ->
          {state, _idx} =
            State.add_program(state, %{"model" => "m2"}, [0], %{0 => 0.7},
              outputs_by_val_id: %{0 => "out0b"}
            )

          state
        end)
        |> then(fn state ->
          {state, _idx} =
            State.add_program(state, %{"model" => "m3"}, [1], %{2 => 0.8},
              outputs_by_val_id: %{2 => "out2"}
            )

          state
        end)

      assert Map.keys(State.valset_evaluations(state)) |> MapSet.new() == MapSet.new([0, 1, 2])
      assert Enum.at(state.prog_candidate_val_subscores, 1) == %{0 => 0.7}
      assert Enum.at(state.prog_candidate_val_subscores, 2) == %{2 => 0.8}
    end

    test "resume from run_dir preserves prior metric-call totals" do
      run_dir = tmp_dir("resume")

      {:ok, first_run} =
        GEPA.optimize(
          seed_candidate: %{"model" => "m"},
          trainset: [%{id: 0, output: "train", score: 0.5}],
          valset: [%{id: 0, output: "val", score: 0.5}],
          adapter: %FixedAdapter{},
          custom_candidate_proposer: fn candidate, _dataset, components ->
            Map.new(components, &{&1, candidate[&1] <> " improved"})
          end,
          max_metric_calls: 1,
          run_dir: run_dir
        )

      {:ok, second_run} =
        GEPA.optimize(
          seed_candidate: %{"model" => "m"},
          trainset: [%{id: 0, output: "train", score: 0.5}],
          valset: [%{id: 0, output: "val", score: 0.5}],
          adapter: %FixedAdapter{},
          custom_candidate_proposer: fn candidate, _dataset, components ->
            Map.new(components, &{&1, candidate[&1] <> " improved"})
          end,
          max_metric_calls: 0,
          run_dir: run_dir
        )

      assert second_run.total_num_evals == first_run.total_num_evals
    end
  end

  defp seed_state(opts \\ []) do
    outputs = Keyword.get(opts, :outputs, ["out"])
    scores = Keyword.get(opts, :scores, [0.5])
    valset_ids = Keyword.get(opts, :valset_ids, [0])

    State.new(
      %{"model" => "m"},
      %EvaluationBatch{outputs: outputs, scores: scores},
      valset_ids,
      Keyword.get(opts, :state_opts, [])
    )
  end

  defp engine_config(opts) do
    valset = Keyword.get(opts, :valset, [%{id: 0, output: "out", score: 0.5}])
    adapter = Keyword.get(opts, :adapter, %FixedAdapter{})

    %{
      seed_candidate: %{"model" => "m"},
      trainset: ListLoader.new([%{id: 0, output: "train", score: 0.5}]),
      valset: ListLoader.new(valset),
      adapter: adapter,
      candidate_selector: GEPA.Strategies.CandidateSelector.CurrentBest,
      stop_conditions: [MaxCalls.new(Keyword.fetch!(opts, :max_calls))],
      reflection_minibatch_size: 1,
      perfect_score: 1.0,
      skip_perfect_score: false,
      seed: 42,
      run_dir: Keyword.get(opts, :run_dir),
      custom_candidate_proposer: fn candidate, _dataset, components ->
        Map.new(components, &{&1, candidate[&1] <> " improved"})
      end
    }
  end

  defp best_output_path(run_dir, val_id, iteration, program_idx) do
    Path.join([
      run_dir,
      "generated_best_outputs_valset",
      "task_#{val_id}",
      "iter_#{iteration}_prog_#{program_idx}.json"
    ])
  end

  defp tmp_dir(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "gepa-state-parity-#{label}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
