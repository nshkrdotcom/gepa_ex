defmodule GEPA.Strategies.IncrementalEvaluationTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  # TDD RED PHASE: Incremental Evaluation Policy
  # Progressively evaluates validation set instead of all at once

  alias GEPA.Strategies.EvaluationPolicy.Incremental

  defmodule DynamicValLoader do
    defstruct [:pid]

    def new(pid), do: %__MODULE__{pid: pid}

    def all_ids(%__MODULE__{pid: pid}) do
      Agent.get(pid, fn state ->
        state.items
        |> length()
        |> then(fn
          0 -> []
          count -> Enum.to_list(0..(count - 1))
        end)
      end)
    end

    def fetch(%__MODULE__{pid: pid}, ids) do
      Agent.get(pid, fn state -> Enum.map(ids, &Enum.fetch!(state.items, &1)) end)
    end

    def size(loader), do: length(all_ids(loader))

    def has_pending?(%__MODULE__{pid: pid}) do
      Agent.get(pid, &(&1.staged != []))
    end

    def add_next_if_available(%__MODULE__{pid: pid}) do
      Agent.update(pid, fn
        %{staged: [next | rest]} = state ->
          %{state | items: state.items ++ [next], staged: rest, expansions: state.expansions + 1}

        state ->
          state
      end)
    end

    def expansions(%__MODULE__{pid: pid}) do
      Agent.get(pid, & &1.expansions)
    end
  end

  defmodule DynamicValAdapter do
    @behaviour GEPA.Adapter

    defstruct [:val_loader, :counter, :expand_after]

    def new(opts) do
      %__MODULE__{
        val_loader: Keyword.fetch!(opts, :val_loader),
        counter: Keyword.fetch!(opts, :counter),
        expand_after: Keyword.get(opts, :expand_after, 2)
      }
    end

    @impl true
    def evaluate(adapter, batch, candidate, capture_traces) do
      weight =
        candidate
        |> Map.fetch!("system_prompt")
        |> String.split("=")
        |> List.last()
        |> String.to_integer()

      outputs = Enum.map(batch, &%{"id" => &1["id"], "weight" => weight})
      scores = Enum.map(batch, &min(1.0, (weight + 1) / &1["difficulty"]))

      if val_batch?(batch) do
        val_calls = increment_val_calls(adapter.counter)

        if val_calls == adapter.expand_after and DynamicValLoader.has_pending?(adapter.val_loader) do
          DynamicValLoader.add_next_if_available(adapter.val_loader)
        end
      end

      {:ok,
       %GEPA.EvaluationBatch{
         outputs: outputs,
         scores: scores,
         trajectories: if(capture_traces, do: Enum.map(scores, &%{"score" => &1}))
       }}
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, eval_batch, components) do
      records = Enum.map(eval_batch.scores, &%{"score" => &1})
      {:ok, Map.new(components, &{&1, records})}
    end

    @impl true
    def propose_new_texts(_adapter, candidate, _reflective_dataset, components) do
      next_weight =
        candidate
        |> Map.fetch!("system_prompt")
        |> String.split("=")
        |> List.last()
        |> String.to_integer()
        |> Kernel.+(1)

      {:ok, Map.new(components, &{&1, "weight=#{next_weight}"})}
    end

    defp val_batch?([]), do: false
    defp val_batch?([item | _]), do: item["split"] == "val"

    defp increment_val_calls(pid) do
      Agent.get_and_update(pid, fn state ->
        val_calls = state.val_calls + 1
        {val_calls, %{state | val_calls: val_calls}}
      end)
    end
  end

  defmodule RoundRobinDynamicPolicy do
    @behaviour GEPA.Strategies.EvaluationPolicy

    alias GEPA.Strategies.EvaluationPolicy.Full

    defstruct [:batch_size]

    def new(opts \\ []) do
      batch_size = Keyword.get(opts, :batch_size, 5)

      if batch_size <= 0 do
        raise ArgumentError, "batch_size must be a positive integer"
      end

      %__MODULE__{batch_size: batch_size}
    end

    @impl true
    def get_eval_batch(loader, state, target_program_idx) do
      new() |> get_eval_batch(loader, state, target_program_idx)
    end

    def get_eval_batch(policy, loader, state, _target_program_idx) do
      all_ids = GEPA.DataLoader.all_ids(loader)
      order_index = all_ids |> Enum.with_index() |> Map.new()

      all_ids
      |> Enum.sort_by(fn val_id ->
        {eval_count(state, val_id), Map.fetch!(order_index, val_id)}
      end)
      |> Enum.take(policy.batch_size)
    end

    @impl true
    def get_best_program(state) do
      state.prog_candidate_val_subscores
      |> Enum.with_index()
      |> Enum.map(fn {scores, idx} ->
        {avg, coverage} = Full.calculate_avg_and_coverage(scores)
        {idx, avg, coverage}
      end)
      |> Enum.max_by(fn {_idx, avg, coverage} -> {avg, coverage} end)
      |> elem(0)
    end

    @impl true
    def get_valset_score(program_idx, state) do
      state
      |> GEPA.State.get_program_average_val_subset(program_idx)
      |> elem(0)
    end

    defp eval_count(state, val_id) do
      Enum.count(state.prog_candidate_val_subscores, &Map.has_key?(&1, val_id))
    end
  end

  describe "new/1 - RED PHASE" do
    test "creates policy with default settings" do
      policy = Incremental.new()

      assert %Incremental{} = policy
      assert policy.initial_sample_size > 0
      assert policy.increment_size > 0
    end

    test "creates policy with custom settings" do
      policy =
        Incremental.new(
          initial_sample_size: 10,
          increment_size: 5,
          max_sample_size: 50
        )

      assert policy.initial_sample_size == 10
      assert policy.increment_size == 5
      assert policy.max_sample_size == 50
    end
  end

  describe "select_samples/3 - RED PHASE" do
    test "starts with initial sample size for new candidate" do
      policy = Incremental.new(initial_sample_size: 5)
      candidate_idx = 0
      # 100 samples available
      available_samples = Enum.to_list(0..99)

      {selected, _new_policy} =
        Incremental.select_samples(policy, candidate_idx, available_samples)

      # Should return initial sample size
      assert length(selected) == 5
      # All from available samples
      assert Enum.all?(selected, &(&1 in available_samples))
    end

    test "expands sample for previously evaluated candidate" do
      policy =
        Incremental.new(
          initial_sample_size: 5,
          increment_size: 3
        )

      # Simulate that candidate 1 was already evaluated on 5 samples
      policy = %{policy | evaluated_samples: %{1 => MapSet.new([0, 1, 2, 3, 4])}}

      available_samples = Enum.to_list(0..99)

      {selected, _new_policy} = Incremental.select_samples(policy, 1, available_samples)

      # Should return initial + increment = 8 samples
      assert length(selected) == 8
      # Should include previous samples plus new ones
      assert Enum.all?([0, 1, 2, 3, 4], &(&1 in selected))
    end

    test "respects max_sample_size limit" do
      policy =
        Incremental.new(
          initial_sample_size: 10,
          increment_size: 20,
          max_sample_size: 25
        )

      # Candidate already evaluated on 10
      policy = %{policy | evaluated_samples: %{1 => MapSet.new(0..9)}}

      available_samples = Enum.to_list(0..99)

      {selected, _} = Incremental.select_samples(policy, 1, available_samples)

      # Should cap at max_sample_size (25), not 10 + 20 = 30
      assert length(selected) <= 25
    end

    test "deterministic sample selection with seed" do
      policy1 = Incremental.new(initial_sample_size: 10, seed: 42)
      policy2 = Incremental.new(initial_sample_size: 10, seed: 42)

      available_samples = Enum.to_list(0..99)

      {selected1, _} = Incremental.select_samples(policy1, 0, available_samples)
      {selected2, _} = Incremental.select_samples(policy2, 0, available_samples)

      # Same seed = same selection
      assert selected1 == selected2
    end

    test "different seed gives different selection" do
      policy1 = Incremental.new(initial_sample_size: 10, seed: 42)
      policy2 = Incremental.new(initial_sample_size: 10, seed: 99)

      available_samples = Enum.to_list(0..99)

      {selected1, _} = Incremental.select_samples(policy1, 0, available_samples)
      {selected2, _} = Incremental.select_samples(policy2, 0, available_samples)

      # Different seed = likely different selection
      assert selected1 != selected2
    end
  end

  describe "should_do_full_eval?/3 - RED PHASE" do
    test "returns true when candidate is promising (high score)" do
      policy = Incremental.new(full_eval_threshold: 0.8)
      candidate_idx = 1
      # Above threshold
      partial_score = 0.9

      result = Incremental.should_do_full_eval?(policy, candidate_idx, partial_score)

      assert result == true
    end

    test "returns false when candidate score is low" do
      policy = Incremental.new(full_eval_threshold: 0.8)
      candidate_idx = 1
      # Below threshold
      partial_score = 0.5

      result = Incremental.should_do_full_eval?(policy, candidate_idx, partial_score)

      assert result == false
    end

    test "returns true when max samples already evaluated" do
      policy = Incremental.new(max_sample_size: 20)

      # Already evaluated on 20 samples (max)
      policy = %{policy | evaluated_samples: %{1 => MapSet.new(0..19)}}

      # Even with low score, should do full eval (at max already)
      result = Incremental.should_do_full_eval?(policy, 1, 0.3)

      assert result == true
    end
  end

  describe "update_evaluated/3 - RED PHASE" do
    test "tracks samples evaluated for each candidate" do
      policy = Incremental.new()

      samples = [0, 1, 2]
      policy = Incremental.update_evaluated(policy, 0, samples)

      # Should track evaluated samples
      assert MapSet.new(samples) == policy.evaluated_samples[0] or
               MapSet.subset?(MapSet.new(samples), policy.evaluated_samples[0])
    end

    test "accumulates samples across multiple evaluations" do
      policy = Incremental.new()

      policy = Incremental.update_evaluated(policy, 0, [0, 1, 2])
      policy = Incremental.update_evaluated(policy, 0, [3, 4, 5])

      # Should have all samples
      evaluated = policy.evaluated_samples[0]
      assert MapSet.subset?(MapSet.new([0, 1, 2, 3, 4, 5]), evaluated)
    end
  end

  describe "upstream dynamic valset parity" do
    test "handles a validation loader that expands during incremental evaluation" do
      trainset = [
        %{"id" => 0, "difficulty" => 2, "split" => "train"},
        %{"id" => 1, "difficulty" => 3, "split" => "train"},
        %{"id" => 2, "difficulty" => 4, "split" => "train"}
      ]

      initial_valset = [
        %{"id" => 0, "difficulty" => 3, "split" => "val"},
        %{"id" => 1, "difficulty" => 4, "split" => "val"}
      ]

      staged_val_items = [
        %{"id" => 2, "difficulty" => 5, "split" => "val"}
      ]

      {:ok, loader_pid} =
        Agent.start_link(fn ->
          %{items: initial_valset, staged: staged_val_items, expansions: 0}
        end)

      {:ok, counter_pid} = Agent.start_link(fn -> %{val_calls: 0} end)

      on_exit(fn ->
        if Process.alive?(loader_pid), do: Agent.stop(loader_pid)
        if Process.alive?(counter_pid), do: Agent.stop(counter_pid)
      end)

      run_dir =
        Path.join(System.tmp_dir!(), "gepa-dynamic-valset-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(run_dir) end)

      val_loader = DynamicValLoader.new(loader_pid)

      adapter =
        DynamicValAdapter.new(
          val_loader: val_loader,
          counter: counter_pid,
          expand_after: 2
        )

      assert {:ok, result} =
               GEPA.optimize(
                 seed_candidate: %{"system_prompt" => "weight=0"},
                 trainset: trainset,
                 valset: val_loader,
                 adapter: adapter,
                 reflection_lm: nil,
                 candidate_selection_strategy: :current_best,
                 max_metric_calls: 12,
                 run_dir: run_dir,
                 val_evaluation_policy: RoundRobinDynamicPolicy.new(batch_size: 2)
               )

      covered_ids =
        result.val_subscores
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      non_seed_batch_sizes =
        result.val_subscores
        |> Enum.drop(1)
        |> Enum.map(&map_size/1)

      assert DynamicValLoader.expansions(val_loader) == 1
      assert MapSet.member?(covered_ids, 2)
      assert non_seed_batch_sizes != []
      assert Enum.max(non_seed_batch_sizes) <= 2
    end
  end
end
