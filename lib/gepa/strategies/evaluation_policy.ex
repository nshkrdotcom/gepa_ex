defmodule GEPA.Strategies.EvaluationPolicy do
  @moduledoc """
  Behavior for validation evaluation policies.

  Determines which validation examples to evaluate and how to score programs.
  """

  @doc """
  Get validation batch IDs to evaluate for a program.
  """
  @callback get_eval_batch(GEPA.DataLoader.t(), GEPA.State.t(), non_neg_integer() | nil) ::
              [term()]

  @doc """
  Get the index of the best program given current evaluations.
  """
  @callback get_best_program(GEPA.State.t()) :: non_neg_integer()

  @doc """
  Get the validation score for a specific program.
  """
  @callback get_valset_score(non_neg_integer(), GEPA.State.t()) :: float()
end

defmodule GEPA.Strategies.EvaluationPolicy.Full do
  @moduledoc """
  Always evaluates all validation examples.

  Simple and thorough, but can be expensive for large validation sets.
  """

  @behaviour GEPA.Strategies.EvaluationPolicy

  @impl true
  def get_eval_batch(valset_loader, _state, _target_program_idx) do
    GEPA.DataLoader.all_ids(valset_loader)
  end

  @impl true
  def get_best_program(state) do
    # Find program with highest average score, with coverage tie-breaking
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {scores, idx} ->
      {avg, coverage} = calculate_avg_and_coverage(scores)
      {idx, avg, coverage}
    end)
    |> Enum.max_by(fn {_idx, avg, coverage} -> {avg, coverage} end)
    |> elem(0)
  end

  @impl true
  def get_valset_score(program_idx, state) do
    {avg, _count} = GEPA.State.get_program_score(state, program_idx)
    avg
  end

  defp calculate_avg_and_coverage(scores) when map_size(scores) == 0 do
    {0.0, 0}
  end

  defp calculate_avg_and_coverage(scores) do
    values = Map.values(scores)
    avg = Enum.sum(values) / length(values)
    {avg, length(values)}
  end
end
