defmodule GEPA.Result do
  @moduledoc """
  Immutable result container for GEPA optimization.

  Contains the final optimization state and provides convenient
  accessors for analysis.
  """

  alias GEPA.Types

  @type t :: %__MODULE__{
          candidates: [Types.candidate()],
          val_aggregate_scores: [float()],
          val_subscores: [Types.sparse_scores()],
          per_val_instance_best_candidates: Types.pareto_fronts(),
          parents: [[Types.program_idx() | nil]],
          total_num_evals: non_neg_integer(),
          num_full_ds_evals: non_neg_integer(),
          i: non_neg_integer()
        }

  defstruct [
    :candidates,
    :val_aggregate_scores,
    :val_subscores,
    :per_val_instance_best_candidates,
    :parents,
    :total_num_evals,
    :num_full_ds_evals,
    :i
  ]

  @doc """
  Create result from final optimization state.
  """
  @spec from_state(GEPA.State.t()) :: t()
  def from_state(state) do
    # Calculate aggregate scores for all programs
    agg_scores =
      state.prog_candidate_val_subscores
      |> Enum.map(fn scores ->
        if map_size(scores) > 0 do
          Enum.sum(Map.values(scores)) / map_size(scores)
        else
          0.0
        end
      end)

    %__MODULE__{
      candidates: state.program_candidates,
      val_aggregate_scores: agg_scores,
      val_subscores: state.prog_candidate_val_subscores,
      per_val_instance_best_candidates: state.program_at_pareto_front_valset,
      parents: state.parent_program_for_candidate,
      total_num_evals: state.total_num_evals,
      num_full_ds_evals: state.num_full_ds_evals,
      i: state.i
    }
  end

  @doc """
  Get the index of the best candidate by aggregate score.
  """
  @spec best_idx(t()) :: non_neg_integer()
  def best_idx(%__MODULE__{val_aggregate_scores: scores}) do
    scores
    |> Enum.with_index()
    |> Enum.max_by(fn {score, _idx} -> score end)
    |> elem(1)
  end

  @doc """
  Get the best candidate program.
  """
  @spec best_candidate(t()) :: Types.candidate()
  def best_candidate(%__MODULE__{} = result) do
    Enum.at(result.candidates, best_idx(result))
  end

  @doc """
  Get the best score achieved.
  """
  @spec best_score(t()) :: float()
  def best_score(%__MODULE__{val_aggregate_scores: scores}) do
    Enum.max(scores)
  end
end
