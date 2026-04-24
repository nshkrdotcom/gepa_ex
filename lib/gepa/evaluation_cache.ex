defmodule GEPA.EvaluationCache do
  @moduledoc """
  Cache for validation evaluations keyed by candidate content and example id.

  GEPA treats cached entries as opaque task outputs plus score metadata. A cache
  hit avoids re-running the adapter and contributes zero new metric calls.
  """

  defmodule Entry do
    @moduledoc """
    Cached result for one candidate/example pair.
    """

    @type t :: %__MODULE__{
            output: term(),
            score: float(),
            objective_scores: %{String.t() => float()} | nil
          }

    @enforce_keys [:output, :score]
    defstruct [:output, :score, objective_scores: nil]
  end

  @type candidate :: %{String.t() => String.t()}
  @type data_id :: term()
  @type key :: {String.t(), data_id()}
  @type t :: %__MODULE__{entries: %{key() => Entry.t()}}

  defstruct entries: %{}

  @doc """
  Create an empty evaluation cache.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Fetch one cached evaluation.
  """
  @spec get(t(), candidate(), data_id()) :: {:ok, Entry.t()} | :miss
  def get(%__MODULE__{entries: entries}, candidate, example_id) do
    case Map.fetch(entries, {candidate_hash(candidate), example_id}) do
      {:ok, entry} -> {:ok, entry}
      :error -> :miss
    end
  end

  @doc """
  Store one cached evaluation.
  """
  @spec put(t(), candidate(), data_id(), term(), float(), %{String.t() => float()} | nil) :: t()
  def put(
        %__MODULE__{entries: entries} = cache,
        candidate,
        example_id,
        output,
        score,
        objective_scores \\ nil
      ) do
    entry = %Entry{output: output, score: score, objective_scores: objective_scores}
    %{cache | entries: Map.put(entries, {candidate_hash(candidate), example_id}, entry)}
  end

  @doc """
  Split ids into cached entries and uncached ids.

  The uncached list preserves the caller's requested order.
  """
  @spec get_batch(t(), candidate(), [data_id()]) :: {%{data_id() => Entry.t()}, [data_id()]}
  def get_batch(%__MODULE__{} = cache, candidate, example_ids) do
    Enum.reduce(example_ids, {%{}, []}, fn example_id, {cached, uncached} ->
      case get(cache, candidate, example_id) do
        {:ok, entry} -> {Map.put(cached, example_id, entry), uncached}
        :miss -> {cached, uncached ++ [example_id]}
      end
    end)
  end

  @doc """
  Store a batch of evaluation results.
  """
  @spec put_batch(
          t(),
          candidate(),
          [data_id()],
          [term()],
          [float()],
          [%{String.t() => float()}] | nil
        ) :: t()
  def put_batch(cache, candidate, example_ids, outputs, scores, objective_scores_list \\ nil) do
    example_ids
    |> Enum.with_index()
    |> Enum.reduce(cache, fn {example_id, index}, acc ->
      put(
        acc,
        candidate,
        example_id,
        Enum.at(outputs, index),
        Enum.at(scores, index),
        objective_scores_list && Enum.at(objective_scores_list, index)
      )
    end)
  end

  @doc """
  Deterministic hash for candidate maps.
  """
  @spec candidate_hash(candidate()) :: String.t()
  def candidate_hash(candidate) do
    candidate
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
