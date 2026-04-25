defmodule GEPA.EvaluationBatch do
  @moduledoc """
  Container for evaluation results.

  An EvaluationBatch contains the outputs, scores, and optionally trajectories
  from evaluating a candidate program on a batch of examples.

  ## Fields

  - `outputs`: List of raw outputs (opaque to GEPA, user-defined type)
  - `scores`: List of numeric scores (higher is better)
  - `trajectories`: Optional list of execution traces for reflection
  - `objective_scores`: Optional per-example multi-objective score maps
  - `num_metric_calls`: Optional explicit metric-call count for budget accounting

  ## Invariants

  - `length(outputs) == length(scores)`
  - If trajectories present: `length(outputs) == length(trajectories)`
  - If objective scores present: `length(outputs) == length(objective_scores)`
  """

  @type t :: %__MODULE__{
          outputs: [term()],
          scores: [float()],
          trajectories: [term()] | nil,
          objective_scores: [%{String.t() => float()}] | nil,
          num_metric_calls: non_neg_integer() | nil
        }

  @enforce_keys [:outputs, :scores]
  defstruct [:outputs, :scores, trajectories: nil, objective_scores: nil, num_metric_calls: nil]

  @doc """
  Validates that the batch satisfies all invariants.

  ## Examples

      iex> batch = %GEPA.EvaluationBatch{outputs: ["a"], scores: [0.5]}
      iex> GEPA.EvaluationBatch.valid?(batch)
      true

      iex> batch = %GEPA.EvaluationBatch{outputs: ["a", "b"], scores: [0.5]}
      iex> GEPA.EvaluationBatch.valid?(batch)
      false
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = batch) do
    output_count = length(batch.outputs)

    output_count == length(batch.scores) and
      optional_list_length_matches?(batch.trajectories, output_count) and
      optional_list_length_matches?(batch.objective_scores, output_count) and
      (is_nil(batch.num_metric_calls) or
         (is_integer(batch.num_metric_calls) and batch.num_metric_calls >= 0))
  end

  def valid?(_), do: false

  defp optional_list_length_matches?(nil, _expected), do: true

  defp optional_list_length_matches?(values, expected) when is_list(values) do
    length(values) == expected
  end

  defp optional_list_length_matches?(_values, _expected), do: false
end
