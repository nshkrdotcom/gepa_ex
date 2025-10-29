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
