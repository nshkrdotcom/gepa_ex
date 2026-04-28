defmodule GEPA.Strategies.BatchSampler do
  @moduledoc "Behaviour for sampling training data into minibatches."

  @callback next_batch(t(), GEPA.DataLoader.t(), GEPA.State.t()) :: {[term()], t()}
  @type t :: term()
end

defmodule GEPA.Strategies.BatchSampler.Simple do
  @moduledoc "Simple deterministic circular sampler."

  @behaviour GEPA.Strategies.BatchSampler

  defstruct [:batch_size, :current_offset]

  @type t :: %__MODULE__{batch_size: pos_integer(), current_offset: non_neg_integer()}

  def new(batch_size \\ 3) when is_integer(batch_size) and batch_size > 0 do
    %__MODULE__{batch_size: batch_size, current_offset: 0}
  end

  @impl true
  def next_batch(%__MODULE__{} = sampler, loader, _gepa_state) do
    all_ids = GEPA.DataLoader.all_ids(loader)
    total = length(all_ids)

    if total == 0 do
      raise ArgumentError, "Cannot sample a minibatch from an empty loader."
    end

    offset = rem(sampler.current_offset, total)

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
  Epoch-shuffled sampler matching the Python reference semantics.

  A deterministic shuffle is generated per epoch; incomplete epoch tails are
  padded with least-seen IDs so every returned minibatch has `minibatch_size` IDs.
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

  def new(opts \\ []) do
    minibatch_size = Keyword.get(opts, :minibatch_size, 3)
    seed = Keyword.get(opts, :seed, 0)

    if not (is_integer(minibatch_size) and minibatch_size > 0) do
      raise ArgumentError, ":minibatch_size must be a positive integer"
    end

    %__MODULE__{
      minibatch_size: minibatch_size,
      seed: seed,
      shuffled_ids: [],
      current_position: 0,
      epoch: -1,
      id_freqs: %{},
      last_trainset_size: 0,
      rng_state: seed_rng(seed)
    }
  end

  @impl true
  def next_batch(%__MODULE__{} = sampler, loader, gepa_state) do
    all_ids = GEPA.DataLoader.all_ids(loader)
    trainset_size = length(all_ids)

    if trainset_size == 0 do
      raise ArgumentError, "Cannot sample a minibatch from an empty loader."
    end

    raw_base_idx = base_index(sampler, gepa_state)
    curr_epoch = current_epoch(sampler, raw_base_idx)

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
      |> pad_result_from_cycle(sampler.shuffled_ids, sampler.minibatch_size)

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

  defp base_index(%__MODULE__{} = sampler, %{i: iteration}) when is_integer(iteration) do
    max(iteration, 0) * sampler.minibatch_size
  end

  defp base_index(%__MODULE__{} = sampler, _state), do: sampler.current_position

  defp current_epoch(%__MODULE__{epoch: -1}, _base_idx), do: 0

  defp current_epoch(%__MODULE__{shuffled_ids: shuffled_ids} = sampler, base_idx) do
    div(base_idx, max(length(shuffled_ids), sampler.minibatch_size))
  end

  defp seed_rng(seed) do
    normalized = :erlang.phash2({__MODULE__, seed})
    :rand.seed_s(:exsss, {normalized + 1, normalized + 2, normalized + 3})
  end

  defp shuffle(ids, rng_state) do
    {keyed, rng_state} =
      Enum.map_reduce(ids, rng_state, fn id, state ->
        {key, state} = :rand.uniform_s(state)
        {{key, id}, state}
      end)

    {keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), rng_state}
  end

  defp pad_to_minibatch(shuffled, id_freqs, minibatch_size) do
    remainder = rem(length(shuffled), minibatch_size)
    num_to_pad = if remainder == 0, do: 0, else: minibatch_size - remainder

    if num_to_pad == 0 do
      {shuffled, id_freqs}
    else
      Enum.reduce(1..num_to_pad, {shuffled, id_freqs}, fn _, {ids, freqs} ->
        selected_id = least_frequent_id(freqs, ids)
        {ids ++ [selected_id], Map.update!(freqs, selected_id, &(&1 + 1))}
      end)
    end
  end

  defp pad_result_from_cycle(batch_ids, _all_ids, minibatch_size)
       when length(batch_ids) == minibatch_size do
    batch_ids
  end

  defp pad_result_from_cycle(batch_ids, all_ids, minibatch_size) do
    needed = minibatch_size - length(batch_ids)
    batch_ids ++ Enum.take(Stream.cycle(all_ids), needed)
  end

  defp least_frequent_id(freqs, ids) do
    ids
    |> Enum.uniq()
    |> Enum.min_by(fn id -> {Map.fetch!(freqs, id), Enum.find_index(ids, &(&1 == id))} end)
  end
end
