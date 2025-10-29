defmodule GEPA.Strategies.BatchSampler do
  @moduledoc """
  Behavior for sampling training data into mini-batches.
  """

  @doc """
  Sample next mini-batch of data IDs.

  ## Parameters

  - `sampler`: Sampler state/struct
  - `loader`: Data loader
  - `gepa_state`: Current GEPA state (for iteration info)

  ## Returns

  `{batch_ids, new_sampler_state}`
  """
  @callback next_batch(t(), GEPA.DataLoader.t(), GEPA.State.t()) ::
              {[term()], t()}

  @type t :: term()
end

defmodule GEPA.Strategies.BatchSampler.Simple do
  @moduledoc """
  Simple batch sampler that cycles through data in order.

  For MVP - deterministic and simple. Can be replaced with
  EpochShuffled for production use.
  """

  @behaviour GEPA.Strategies.BatchSampler

  defstruct [:batch_size, :current_offset]

  @type t :: %__MODULE__{
          batch_size: pos_integer(),
          current_offset: non_neg_integer()
        }

  def new(batch_size \\ 3) do
    %__MODULE__{batch_size: batch_size, current_offset: 0}
  end

  @impl true
  def next_batch(sampler, loader, _gepa_state) do
    all_ids = GEPA.DataLoader.all_ids(loader)
    total = length(all_ids)

    # Wrap around if needed
    offset = rem(sampler.current_offset, total)

    # Get batch (circular)
    batch_ids =
      all_ids
      |> Stream.cycle()
      |> Stream.drop(offset)
      |> Enum.take(sampler.batch_size)

    new_sampler = %{sampler | current_offset: offset + sampler.batch_size}

    {batch_ids, new_sampler}
  end
end

defmodule GEPA.Strategies.BatchSampler.EpochShuffled do
  @moduledoc """
  Epoch-based batch sampler with shuffling.

  Shuffles the training data at the start of each epoch and samples
  mini-batches sequentially. When an epoch completes, the data is
  reshuffled for the next epoch.

  This provides better training dynamics than simple circular sampling:
  - Each sample seen once per epoch (no immediate repeats)
  - Different sample orders each epoch (prevents overfitting to order)
  - Deterministic with seed (reproducible experiments)

  ## Example

      sampler = GEPA.Strategies.BatchSampler.EpochShuffled.new(
        minibatch_size: 5,
        seed: 42
      )

      {batch1, sampler} = next_batch(sampler, loader, state)
      # Returns 5 samples from shuffled epoch 1

      {batch2, sampler} = next_batch(sampler, loader, state)
      # Returns next 5 samples from epoch 1

      # After all samples used once, starts epoch 2 with new shuffle
  """

  @behaviour GEPA.Strategies.BatchSampler

  defstruct [
    :minibatch_size,
    :seed,
    :shuffled_ids,
    :current_position,
    :epoch
  ]

  @type t :: %__MODULE__{
          minibatch_size: pos_integer(),
          seed: integer(),
          shuffled_ids: [term()] | nil,
          current_position: non_neg_integer(),
          epoch: non_neg_integer()
        }

  @doc """
  Creates a new EpochShuffled batch sampler.

  ## Options

    - `:minibatch_size` - Number of samples per batch (default: 3)
    - `:seed` - Random seed for shuffling (default: 0)

  ## Examples

      sampler = EpochShuffled.new(minibatch_size: 5)
      sampler = EpochShuffled.new(minibatch_size: 10, seed: 42)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      minibatch_size: Keyword.get(opts, :minibatch_size, 3),
      seed: Keyword.get(opts, :seed, 0),
      shuffled_ids: nil,
      current_position: 0,
      epoch: 0
    }
  end

  @impl true
  def next_batch(sampler, loader, _gepa_state) do
    all_ids = GEPA.DataLoader.all_ids(loader)

    # Initialize or reshuffle if we've gone through all data
    sampler =
      if is_nil(sampler.shuffled_ids) or sampler.current_position >= length(all_ids) do
        start_new_epoch(sampler, all_ids)
      else
        sampler
      end

    # Get next batch
    batch_ids =
      sampler.shuffled_ids
      |> Enum.drop(sampler.current_position)
      |> Enum.take(sampler.minibatch_size)

    # Update position
    new_sampler = %{sampler | current_position: sampler.current_position + sampler.minibatch_size}

    {batch_ids, new_sampler}
  end

  defp start_new_epoch(sampler, all_ids) do
    # Create a seeded random generator for this epoch
    # Use different seed for each epoch to get different shuffles
    epoch_seed = sampler.seed + sampler.epoch

    # Set the random seed and shuffle
    _ = :rand.seed(:exsss, {epoch_seed, epoch_seed * 2, epoch_seed * 3})
    shuffled = Enum.shuffle(all_ids)

    %{sampler | shuffled_ids: shuffled, current_position: 0, epoch: sampler.epoch + 1}
  end
end
