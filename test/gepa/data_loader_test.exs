defmodule GEPA.DataLoaderTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias __MODULE__.StagedDataLoader
  alias GEPA.DataLoader

  describe "DataLoader.List" do
    test "upstream list data loader basic" do
      loader = DataLoader.List.new(["a", "b"])

      assert DataLoader.all_ids(loader) == [0, 1]
      assert DataLoader.fetch(loader, [1, 0]) == ["b", "a"]

      loader = DataLoader.List.add_items(loader, ["c"])

      assert DataLoader.all_ids(loader) == [0, 1, 2]
      assert DataLoader.fetch(loader, [2]) == ["c"]
    end

    test "new/1 creates loader with items" do
      items = [%{a: 1}, %{a: 2}, %{a: 3}]
      loader = DataLoader.List.new(items)

      assert %DataLoader.List{items: ^items} = loader
    end

    test "all_ids/1 returns integer indices" do
      items = [:a, :b, :c, :d]
      loader = DataLoader.List.new(items)

      assert DataLoader.all_ids(loader) == [0, 1, 2, 3]
    end

    test "all_ids/1 returns empty list for empty loader" do
      loader = DataLoader.List.new([])

      assert DataLoader.all_ids(loader) == []
    end

    test "fetch/2 returns items in order of IDs" do
      items = [:a, :b, :c, :d]
      loader = DataLoader.List.new(items)

      assert DataLoader.fetch(loader, [2, 0, 3]) == [:c, :a, :d]
    end

    test "fetch/2 preserves duplicates" do
      items = [:a, :b, :c]
      loader = DataLoader.List.new(items)

      assert DataLoader.fetch(loader, [0, 0, 1]) == [:a, :a, :b]
    end

    test "size/1 returns count of items" do
      items = [1, 2, 3, 4, 5]
      loader = DataLoader.List.new(items)

      assert DataLoader.size(loader) == 5
    end

    test "size/1 returns 0 for empty list" do
      loader = DataLoader.List.new([])

      assert DataLoader.size(loader) == 0
    end
  end

  describe "upstream staged data loader parity" do
    test "unlocks after batches" do
      loader =
        start_staged_loader(
          ["base0", "base1"],
          [
            {1, ["stage1_item"]},
            {3, ["stage2_item"]}
          ]
        )

      assert DataLoader.all_ids(loader) == [0, 1]
      assert StagedDataLoader.num_unlocked_stages(loader) == 1
      assert StagedDataLoader.batches_served(loader) == 0

      DataLoader.fetch(loader, [0])

      assert StagedDataLoader.batches_served(loader) == 1
      assert StagedDataLoader.num_unlocked_stages(loader) == 2
      assert DataLoader.all_ids(loader) == [0, 1, 2]

      DataLoader.fetch(loader, [1])

      assert StagedDataLoader.batches_served(loader) == 2
      assert StagedDataLoader.num_unlocked_stages(loader) == 2

      DataLoader.fetch(loader, [2])

      assert StagedDataLoader.batches_served(loader) == 3
      assert StagedDataLoader.num_unlocked_stages(loader) == 3
      assert DataLoader.all_ids(loader) == [0, 1, 2, 3]
    end

    test "manual unlock" do
      loader = start_staged_loader(["base"], [{5, ["late"]}])

      assert DataLoader.all_ids(loader) == [0]
      assert StagedDataLoader.num_unlocked_stages(loader) == 1

      assert StagedDataLoader.unlock_next_stage(loader)
      assert StagedDataLoader.num_unlocked_stages(loader) == 2
      assert DataLoader.all_ids(loader) == [0, 1]

      refute StagedDataLoader.unlock_next_stage(loader)
    end
  end

  defp start_staged_loader(initial_items, staged_items) do
    {:ok, loader} = StagedDataLoader.start_link(initial_items, staged_items)

    on_exit(fn ->
      StagedDataLoader.stop(loader)
    end)

    loader
  end

  defmodule StagedDataLoader do
    @behaviour DataLoader

    defstruct [:pid]

    def start_link(initial_items, staged_items) do
      stages =
        staged_items
        |> Enum.map(fn {threshold, items} -> {max(0, threshold), List.wrap(items)} end)
        |> Enum.sort_by(fn {threshold, _items} -> threshold end)

      state = %{
        items: List.wrap(initial_items),
        stages: stages,
        next_stage_idx: 0,
        batches_served: 0,
        num_unlocked_stages: 1
      }

      with {:ok, pid} <- Agent.start_link(fn -> unlock_if_due(state) end) do
        {:ok, %__MODULE__{pid: pid}}
      end
    end

    def stop(%__MODULE__{pid: pid}) do
      if Process.alive?(pid), do: Agent.stop(pid)
    end

    @impl true
    def all_ids(%__MODULE__{pid: pid}) do
      Agent.get(pid, fn %{items: items} -> ids_for(items) end)
    end

    @impl true
    def fetch(%__MODULE__{pid: pid}, ids) do
      Agent.get_and_update(pid, fn state ->
        batch = Enum.map(ids, &Enum.fetch!(state.items, &1))

        state =
          state
          |> Map.update!(:batches_served, &(&1 + 1))
          |> unlock_if_due()

        {batch, state}
      end)
    end

    @impl true
    def size(%__MODULE__{pid: pid}) do
      Agent.get(pid, fn %{items: items} -> length(items) end)
    end

    def batches_served(%__MODULE__{pid: pid}) do
      Agent.get(pid, & &1.batches_served)
    end

    def num_unlocked_stages(%__MODULE__{pid: pid}) do
      Agent.get(pid, & &1.num_unlocked_stages)
    end

    def unlock_next_stage(%__MODULE__{pid: pid}) do
      Agent.get_and_update(pid, fn state ->
        case Enum.fetch(state.stages, state.next_stage_idx) do
          {:ok, {_threshold, items}} ->
            state =
              state
              |> Map.update!(:items, &(&1 ++ items))
              |> Map.update!(:next_stage_idx, &(&1 + 1))
              |> Map.update!(:num_unlocked_stages, &(&1 + 1))

            {true, state}

          :error ->
            {false, state}
        end
      end)
    end

    defp unlock_if_due(state) do
      case Enum.fetch(state.stages, state.next_stage_idx) do
        {:ok, {threshold, _items}} when state.batches_served >= threshold ->
          unlock_due_stage(state)
          |> unlock_if_due()

        _not_due_or_missing ->
          state
      end
    end

    defp unlock_due_stage(state) do
      {_threshold, items} = Enum.fetch!(state.stages, state.next_stage_idx)

      state
      |> Map.update!(:items, &(&1 ++ items))
      |> Map.update!(:next_stage_idx, &(&1 + 1))
      |> Map.update!(:num_unlocked_stages, &(&1 + 1))
    end

    defp ids_for([]), do: []
    defp ids_for(items), do: Enum.to_list(0..(length(items) - 1))
  end
end
