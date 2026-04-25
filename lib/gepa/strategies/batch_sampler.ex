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

  @spec new() :: t()
  @spec new(pos_integer()) :: t()
  def new(batch_size \\ 3) do
    %__MODULE__{batch_size: batch_size, current_offset: 0}
  end

  @impl true
  @spec next_batch(t(), GEPA.DataLoader.t(), GEPA.State.t()) ::
          {[term()], t()}
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
    :epoch,
    :id_freqs,
    :last_trainset_size,
    :rng_state
  ]

  @type t :: %__MODULE__{
          minibatch_size: pos_integer(),
          seed: integer(),
          shuffled_ids: [term()],
          current_position: non_neg_integer(),
          epoch: integer(),
          id_freqs: %{term() => pos_integer()},
          last_trainset_size: non_neg_integer(),
          rng_state: :rand.state()
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
      shuffled_ids: [],
      current_position: 0,
      epoch: -1,
      id_freqs: %{},
      last_trainset_size: 0,
      rng_state: seed_rng(Keyword.get(opts, :seed, 0))
    }
  end

  @impl true
  @spec next_batch(t(), GEPA.DataLoader.t(), GEPA.State.t()) ::
          {[term()], t()}
  def next_batch(sampler, loader, gepa_state) do
    all_ids = GEPA.DataLoader.all_ids(loader)
    trainset_size = length(all_ids)

    if trainset_size == 0 do
      raise ArgumentError, "Cannot sample a minibatch from an empty loader."
    end

    raw_base_idx = base_index(sampler, gepa_state)
    curr_epoch = current_epoch(sampler, raw_base_idx)

    # Initialize, refresh on trainset size changes, or reshuffle at epoch boundaries.
    sampler =
      if sampler.shuffled_ids == [] or trainset_size != sampler.last_trainset_size or
           curr_epoch > sampler.epoch do
        start_new_epoch(%{sampler | epoch: curr_epoch}, all_ids)
      else
        sampler
      end

    base_idx = rem(raw_base_idx, length(sampler.shuffled_ids))

    batch_ids =
      sampler.shuffled_ids
      |> Enum.drop(base_idx)
      |> Enum.take(sampler.minibatch_size)

    new_sampler = %{sampler | current_position: raw_base_idx + sampler.minibatch_size}

    {batch_ids, new_sampler}
  end

  defp start_new_epoch(sampler, all_ids) do
    {shuffled, rng_state} = shuffle(all_ids, sampler.rng_state)
    id_freqs = Enum.frequencies(shuffled)
    {padded, id_freqs} = pad_to_minibatch(shuffled, id_freqs, sampler.minibatch_size)

    %{
      sampler
      | shuffled_ids: padded,
        id_freqs: id_freqs,
        current_position: 0,
        last_trainset_size: length(all_ids),
        rng_state: rng_state
    }
  end

  defp base_index(%__MODULE__{} = sampler, nil), do: sampler.current_position
  defp base_index(%__MODULE__{} = sampler, %{i: nil}), do: sampler.current_position

  defp base_index(%__MODULE__{} = sampler, %{i: iteration}),
    do: iteration * sampler.minibatch_size

  defp current_epoch(%__MODULE__{epoch: -1}, _base_idx), do: 0

  defp current_epoch(%__MODULE__{shuffled_ids: shuffled_ids} = sampler, base_idx) do
    div(base_idx, max(length(shuffled_ids), sampler.minibatch_size))
  end

  defp seed_rng(seed) do
    :rand.seed_s(:exsss, {seed + 1, seed * 2 + 3, seed * 3 + 5})
  end

  defp shuffle(ids, rng_state) do
    {keyed, rng_state} =
      Enum.map_reduce(ids, rng_state, fn id, state ->
        {key, state} = :rand.uniform_s(state)
        {{key, id}, state}
      end)

    shuffled = keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    {shuffled, rng_state}
  end

  defp pad_to_minibatch(shuffled, id_freqs, minibatch_size) do
    remainder = rem(length(shuffled), minibatch_size)
    num_to_pad = if remainder == 0, do: 0, else: minibatch_size - remainder

    Enum.reduce(1..num_to_pad//1, {shuffled, id_freqs}, fn _, {ids, freqs} ->
      selected_id = least_frequent_id(freqs, ids)
      {ids ++ [selected_id], Map.update!(freqs, selected_id, &(&1 + 1))}
    end)
  end

  defp least_frequent_id(freqs, ids) do
    ids
    |> Enum.uniq()
    |> Enum.min_by(fn id -> {Map.fetch!(freqs, id), Enum.find_index(ids, &(&1 == id))} end)
  end
end
