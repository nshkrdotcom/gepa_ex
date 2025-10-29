defmodule GEPA.EvaluationBatch do
  @moduledoc """
  Container for evaluation results.

  An EvaluationBatch contains the outputs, scores, and optionally trajectories
  from evaluating a candidate program on a batch of examples.

  ## Fields

  - `outputs`: List of raw outputs (opaque to GEPA, user-defined type)
  - `scores`: List of numeric scores (higher is better)
  - `trajectories`: Optional list of execution traces for reflection

  ## Invariants

  - `length(outputs) == length(scores)`
  - If trajectories present: `length(outputs) == length(trajectories)`
  """

  @type t :: %__MODULE__{
          outputs: [term()],
          scores: [float()],
          trajectories: [term()] | nil
        }

  @enforce_keys [:outputs, :scores]
  defstruct [:outputs, :scores, trajectories: nil]

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
  def valid?(%__MODULE__{outputs: outputs, scores: scores, trajectories: nil}) do
    length(outputs) == length(scores)
  end

  def valid?(%__MODULE__{outputs: outputs, scores: scores, trajectories: trajs})
      when is_list(trajs) do
    length(outputs) == length(scores) and length(outputs) == length(trajs)
  end

  def valid?(_), do: false
end
