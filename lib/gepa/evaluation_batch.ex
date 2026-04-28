defmodule GEPA.EvaluationBatch do
  @moduledoc """
  Container for per-example evaluation results returned by an adapter.

  GEPA treats outputs and trajectories as opaque user data, but it relies on a
  strict one-to-one alignment between `outputs`, `scores`, optional
  `trajectories`, and optional `objective_scores`. This mirrors the Python
  reference contract and keeps bugs in adapters from leaking into optimizer
  state.
  """

  @type t :: %__MODULE__{
          outputs: [term()],
          scores: [float()],
          trajectories: [term()] | nil,
          objective_scores: [%{String.t() => number()}] | nil,
          num_metric_calls: non_neg_integer() | nil
        }

  @enforce_keys [:outputs, :scores]
  defstruct [:outputs, :scores, trajectories: nil, objective_scores: nil, num_metric_calls: nil]

  @doc "Validate that a batch satisfies the official GEPA adapter invariants."
  @spec valid?(term(), keyword()) :: boolean()
  def valid?(batch, opts \\ []) do
    case validate(batch, opts) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  @doc "Return `:ok` for a valid batch or a precise error tuple otherwise."
  @spec validate(term(), keyword()) :: :ok | {:error, term()}
  def validate(batch, opts \\ [])

  def validate(%__MODULE__{outputs: outputs, scores: scores} = batch, opts)
      when is_list(outputs) and is_list(scores) do
    output_count = length(outputs)

    with :ok <- validate_expected_count(output_count, opts),
         :ok <- validate_scores(scores, output_count),
         :ok <- validate_trajectories(batch.trajectories, output_count, opts),
         :ok <- validate_objective_scores(batch.objective_scores, output_count) do
      validate_metric_calls(batch.num_metric_calls)
    end
  end

  def validate(%__MODULE__{}, _opts), do: {:error, :outputs_and_scores_must_be_lists}
  def validate(_other, _opts), do: {:error, :not_an_evaluation_batch}

  defp validate_expected_count(count, opts) do
    expected = Keyword.get(opts, :expected_count)

    if is_nil(expected) or count == expected do
      :ok
    else
      {:error, {:invalid_evaluation_batch_length, :outputs, count, expected}}
    end
  end

  defp validate_scores(scores, count) do
    cond do
      length(scores) != count ->
        {:error, {:invalid_evaluation_batch_length, :scores, length(scores), count}}

      not Enum.all?(scores, &is_number/1) ->
        {:error, :scores_must_be_numeric}

      true ->
        :ok
    end
  end

  defp validate_trajectories(trajectories, count, opts) do
    capture_traces = Keyword.get(opts, :capture_traces, false)

    cond do
      not optional_list_length_matches?(trajectories, count) ->
        {:error,
         {:invalid_evaluation_batch_length, :trajectories, optional_length(trajectories), count}}

      capture_traces and is_nil(trajectories) ->
        {:error, :trajectories_required_when_capture_traces}

      true ->
        :ok
    end
  end

  defp validate_objective_scores(obj_scores, count) do
    cond do
      not optional_list_length_matches?(obj_scores, count) ->
        {:error,
         {:invalid_evaluation_batch_length, :objective_scores, optional_length(obj_scores), count}}

      has_invalid_objective_scores?(obj_scores) ->
        {:error, :objective_scores_must_be_maps_of_numeric_values}

      true ->
        :ok
    end
  end

  defp validate_metric_calls(num_metric_calls) do
    if valid_metric_calls?(num_metric_calls) do
      :ok
    else
      {:error, :num_metric_calls_must_be_non_negative_integer}
    end
  end

  @doc "Raise unless a batch is valid; otherwise return the batch unchanged."
  @spec validate!(t(), keyword()) :: t()
  def validate!(%__MODULE__{} = batch, opts \\ []) do
    case validate(batch, opts) do
      :ok -> batch
      {:error, reason} -> raise ArgumentError, "invalid GEPA.EvaluationBatch: #{inspect(reason)}"
    end
  end

  @doc "Return a copy whose scores are floats."
  @spec normalize_scores(t()) :: t()
  def normalize_scores(%__MODULE__{scores: scores} = batch) do
    %{batch | scores: Enum.map(scores, &(&1 * 1.0))}
  end

  defp optional_list_length_matches?(nil, _expected), do: true

  defp optional_list_length_matches?(values, expected) when is_list(values) do
    length(values) == expected
  end

  defp optional_list_length_matches?(_values, _expected), do: false

  defp optional_length(nil), do: nil
  defp optional_length(values) when is_list(values), do: length(values)
  defp optional_length(_), do: :not_a_list

  defp valid_metric_calls?(nil), do: true
  defp valid_metric_calls?(value), do: is_integer(value) and value >= 0

  defp has_invalid_objective_scores?(nil), do: false

  defp has_invalid_objective_scores?(objective_scores) when is_list(objective_scores) do
    Enum.any?(objective_scores, fn
      scores when is_map(scores) ->
        Enum.any?(scores, fn
          {key, value} when is_binary(key) and is_number(value) -> false
          {_key, _value} -> true
        end)

      _other ->
        true
    end)
  end

  defp has_invalid_objective_scores?(_objective_scores), do: true
end
