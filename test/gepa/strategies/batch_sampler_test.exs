defmodule GEPA.Strategies.BatchSamplerTest do
  use ExUnit.Case, async: true

  alias GEPA.Strategies.BatchSampler.{Simple, EpochShuffled}
  alias GEPA.DataLoader

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
      assert sampler.shuffled_ids == nil
      assert sampler.current_position == 0
      assert sampler.epoch == 0
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
      assert sampler.shuffled_ids != nil
      assert sampler.epoch == 1
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
      assert sampler.epoch == 2
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
      # Last batch in epoch
      assert length(batch2) == 1

      # Next batch starts new epoch
      {batch3, sampler} = EpochShuffled.next_batch(sampler, loader, state)
      assert length(batch3) == 2
      assert sampler.epoch == 2
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
  end
end
