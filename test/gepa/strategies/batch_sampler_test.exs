defmodule GEPA.Strategies.BatchSamplerTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.DataLoader
  alias GEPA.Strategies.BatchSampler.{EpochShuffled, Simple}

  describe "Simple batch sampler" do
    test "creates sampler with default batch size" do
      sampler = Simple.new()
      assert sampler.batch_size == 3
      assert sampler.current_offset == 0
    end

    test "creates sampler with custom batch size" do
      sampler = Simple.new(5)
      assert sampler.batch_size == 5
    end

    test "samples batches in circular fashion" do
      loader = DataLoader.List.new([:a, :b, :c, :d, :e])
      sampler = Simple.new(2)
      # State not used by batch sampler
      state = nil

      {batch1, sampler} = Simple.next_batch(sampler, loader, state)
      # Returns indices, not items
      assert batch1 == [0, 1]

      {batch2, sampler} = Simple.next_batch(sampler, loader, state)
      assert batch2 == [2, 3]

      {batch3, sampler} = Simple.next_batch(sampler, loader, state)
      # Wraps around
      assert batch3 == [4, 0]

      {batch4, _sampler} = Simple.next_batch(sampler, loader, state)
      assert batch4 == [1, 2]
    end
  end

  describe "EpochShuffled batch sampler" do
    test "creates sampler with default options" do
      sampler = EpochShuffled.new()
      assert sampler.minibatch_size == 3
      assert sampler.seed == 0
      assert sampler.shuffled_ids == []
      assert sampler.current_position == 0
      assert sampler.epoch == -1
      assert sampler.id_freqs == %{}
      assert sampler.last_trainset_size == 0
    end

    test "creates sampler with custom options" do
      sampler = EpochShuffled.new(minibatch_size: 5, seed: 42)
      assert sampler.minibatch_size == 5
      assert sampler.seed == 42
    end

    test "shuffles data on first batch" do
      loader = DataLoader.List.new([:a, :b, :c, :d, :e, :f])
      sampler = EpochShuffled.new(minibatch_size: 3, seed: 42)
      # State not used by batch sampler
      state = nil

      {batch1, sampler} = EpochShuffled.next_batch(sampler, loader, state)

      assert length(batch1) == 3
      assert is_list(sampler.shuffled_ids)
      assert sampler.epoch == 0
      # All elements should be from the original list (0-indexed)
      assert Enum.all?(batch1, &(&1 in 0..5))
    end

    test "provides sequential batches within an epoch" do
      loader = DataLoader.List.new([:a, :b, :c, :d, :e, :f])
      sampler = EpochShuffled.new(minibatch_size: 2, seed: 42)
      # State not used by batch sampler
      state = nil

      {batch1, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      {batch2, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      {batch3, _sampler} = EpochShuffled.next_batch(sampler, loader, state)

      # No immediate repeats within epoch
      all_sampled = batch1 ++ batch2 ++ batch3
      assert length(all_sampled) == 6
      # No duplicates
      assert Enum.uniq(all_sampled) == all_sampled

      # All elements seen exactly once (0-indexed)
      assert Enum.sort(all_sampled) == [0, 1, 2, 3, 4, 5]
    end

    test "reshuffles at start of new epoch" do
      loader = DataLoader.List.new([:a, :b, :c, :d, :e, :f])
      sampler = EpochShuffled.new(minibatch_size: 6, seed: 42)
      # State not used by batch sampler
      state = nil

      # First epoch
      {batch1, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      epoch1_order = batch1

      # Second epoch (should reshuffle)
      {batch2, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      epoch2_order = batch2

      # Different seed for epoch 2 should give different order
      # (technically could be same by chance, but very unlikely with 6! = 720 permutations)
      assert epoch1_order != epoch2_order
      assert sampler.epoch == 1
    end

    test "seed produces deterministic shuffles" do
      # 10 items
      loader = DataLoader.List.new(Enum.to_list(1..10))
      # State not used by batch sampler
      state = nil

      # Two samplers with same seed
      sampler1 = EpochShuffled.new(minibatch_size: 10, seed: 123)
      sampler2 = EpochShuffled.new(minibatch_size: 10, seed: 123)

      {batch1, _} = EpochShuffled.next_batch(sampler1, loader, state)
      {batch2, _} = EpochShuffled.next_batch(sampler2, loader, state)

      # Same seed = same shuffle
      assert batch1 == batch2

      # Different seed = different shuffle
      sampler3 = EpochShuffled.new(minibatch_size: 10, seed: 456)
      {batch3, _} = EpochShuffled.next_batch(sampler3, loader, state)

      assert batch1 != batch3
    end

    test "handles batches smaller than data size" do
      loader = DataLoader.List.new([:a, :b, :c])
      sampler = EpochShuffled.new(minibatch_size: 2, seed: 42)
      # State not used by batch sampler
      state = nil

      {batch1, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      assert length(batch1) == 2

      {batch2, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      # Last batch in epoch is padded to the minibatch size.
      assert length(batch2) == 2

      # Next batch starts new epoch
      {batch3, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      assert length(batch3) == 2
      assert sampler.epoch == 1
    end

    test "different epochs have different shuffles" do
      # 20 items
      loader = DataLoader.List.new(Enum.to_list(1..20))
      sampler = EpochShuffled.new(minibatch_size: 20, seed: 42)
      # State not used by batch sampler
      state = nil

      # Collect shuffles from 3 epochs
      {epoch1, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      {epoch2, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      {epoch3, _sampler} = EpochShuffled.next_batch(sampler, loader, state)

      # All epochs should have all elements (0-indexed)
      assert Enum.sort(epoch1) == Enum.to_list(0..19)
      assert Enum.sort(epoch2) == Enum.to_list(0..19)
      assert Enum.sort(epoch3) == Enum.to_list(0..19)

      # But in different orders
      assert epoch1 != epoch2
      assert epoch2 != epoch3
      assert epoch1 != epoch3
    end

    test "refreshes shuffled IDs when loader expands" do
      loader = DataLoader.List.new([:a, :b, :c, :d])
      sampler = EpochShuffled.new(minibatch_size: 2, seed: 0)

      {first_batch, sampler} = EpochShuffled.next_batch(sampler, loader, %{i: 0})

      assert length(first_batch) == 2
      assert length(sampler.shuffled_ids) == 4
      assert sampler.last_trainset_size == 4

      expanded_loader = DataLoader.List.add_items(loader, [:e, :f])
      {second_batch, sampler} = EpochShuffled.next_batch(sampler, expanded_loader, %{i: 1})

      assert length(second_batch) == 2
      assert sampler.last_trainset_size == 6
      assert length(sampler.shuffled_ids) == 6
      assert MapSet.subset?(MapSet.new([4, 5]), MapSet.new(sampler.shuffled_ids))
    end

    test "raises when loader is empty" do
      loader = DataLoader.List.new([])
      sampler = EpochShuffled.new(minibatch_size: 2, seed: 0)

      assert_raise ArgumentError, ~r/empty loader/, fn ->
        EpochShuffled.next_batch(sampler, loader, %{i: 0})
      end
    end
  end
end
