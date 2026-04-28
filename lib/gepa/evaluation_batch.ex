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
    expected_count = Keyword.get(opts, :expected_count)
    capture_traces = Keyword.get(opts, :capture_traces, false)
    output_count = length(outputs)

    cond do
      not is_nil(expected_count) and output_count != expected_count ->
        {:error, {:invalid_evaluation_batch_length, :outputs, output_count, expected_count}}

      output_count != length(scores) ->
        {:error, {:invalid_evaluation_batch_length, :scores, length(scores), output_count}}

      not Enum.all?(scores, &is_number/1) ->
        {:error, :scores_must_be_numeric}

      not optional_list_length_matches?(batch.trajectories, output_count) ->
        {:error,
         {:invalid_evaluation_batch_length, :trajectories, optional_length(batch.trajectories),
          output_count}}

      capture_traces and is_nil(batch.trajectories) ->
        {:error, :trajectories_required_when_capture_traces}

      not optional_list_length_matches?(batch.objective_scores, output_count) ->
        {:error,
         {:invalid_evaluation_batch_length, :objective_scores,
          optional_length(batch.objective_scores), output_count}}

      has_invalid_objective_scores?(batch.objective_scores) ->
        {:error, :objective_scores_must_be_maps_of_numeric_values}

      not valid_metric_calls?(batch.num_metric_calls) ->
        {:error, :num_metric_calls_must_be_non_negative_integer}

      true ->
        :ok
    end
  end

  def validate(%__MODULE__{}, _opts), do: {:error, :outputs_and_scores_must_be_lists}
  def validate(_other, _opts), do: {:error, :not_an_evaluation_batch}

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
