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
          i: non_neg_integer(),
          discovery_eval_counts: [non_neg_integer()],
          best_outputs_valset: %{Types.data_id() => [{Types.program_idx(), term()}]} | nil,
          val_aggregate_subscores: [%{String.t() => float()}] | nil,
          per_objective_best_candidates: %{String.t() => MapSet.t(Types.program_idx())} | nil,
          objective_pareto_front: %{String.t() => float()} | nil
        }

  defstruct [
    :candidates,
    :val_aggregate_scores,
    :val_subscores,
    :per_val_instance_best_candidates,
    :parents,
    :total_num_evals,
    :num_full_ds_evals,
    :i,
    discovery_eval_counts: [],
    best_outputs_valset: nil,
    val_aggregate_subscores: nil,
    per_objective_best_candidates: nil,
    objective_pareto_front: nil
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
      i: state.i,
      discovery_eval_counts: state.num_metric_calls_by_discovery,
      best_outputs_valset: state.best_outputs_valset,
      val_aggregate_subscores:
        if Enum.any?(state.prog_candidate_objective_scores, &(&1 != %{})) do
          state.prog_candidate_objective_scores
        end,
      per_objective_best_candidates:
        if state.program_at_pareto_front_objectives != %{} do
          state.program_at_pareto_front_objectives
        end,
      objective_pareto_front:
        if state.objective_pareto_front != %{} do
          state.objective_pareto_front
        end
    }
  end

  @doc """
  Convert a result to a plain map suitable for persistence or JSON conversion.
  """
  @spec to_dict(t()) :: map()
  def to_dict(%__MODULE__{} = result) do
    %{
      "candidates" => result.candidates,
      "val_aggregate_scores" => result.val_aggregate_scores,
      "val_subscores" => result.val_subscores,
      "per_val_instance_best_candidates" =>
        mapset_values_to_lists(result.per_val_instance_best_candidates),
      "parents" => result.parents,
      "total_num_evals" => result.total_num_evals,
      "num_full_ds_evals" => result.num_full_ds_evals,
      "i" => result.i,
      "discovery_eval_counts" => result.discovery_eval_counts,
      "best_outputs_valset" => result.best_outputs_valset,
      "val_aggregate_subscores" => result.val_aggregate_subscores,
      "per_objective_best_candidates" =>
        mapset_values_to_lists(result.per_objective_best_candidates),
      "objective_pareto_front" => result.objective_pareto_front,
      "validation_schema_version" => 2
    }
  end

  @doc """
  Rebuild a result from `to_dict/1` output.
  """
  @spec from_dict(map()) :: t()
  def from_dict(data) when is_map(data) do
    %__MODULE__{
      candidates: dict_get(data, :candidates, []),
      val_aggregate_scores: dict_get(data, :val_aggregate_scores, []),
      val_subscores: dict_get(data, :val_subscores, []),
      per_val_instance_best_candidates:
        list_values_to_mapsets(dict_get(data, :per_val_instance_best_candidates, %{})),
      parents: dict_get(data, :parents, []),
      total_num_evals: dict_get(data, :total_num_evals, 0),
      num_full_ds_evals: dict_get(data, :num_full_ds_evals, 0),
      i: dict_get(data, :i, 0),
      discovery_eval_counts: dict_get(data, :discovery_eval_counts, []),
      best_outputs_valset: dict_get(data, :best_outputs_valset),
      val_aggregate_subscores: dict_get(data, :val_aggregate_subscores),
      per_objective_best_candidates:
        list_values_to_mapsets(dict_get(data, :per_objective_best_candidates)),
      objective_pareto_front: dict_get(data, :objective_pareto_front)
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

  defp dict_get(data, key, default \\ nil) do
    Map.get(data, Atom.to_string(key), Map.get(data, key, default))
  end

  defp mapset_values_to_lists(nil), do: nil

  defp mapset_values_to_lists(values) do
    Map.new(values, fn {key, value} ->
      list =
        case value do
          %MapSet{} -> MapSet.to_list(value)
          _ -> value
        end

      {key, list}
    end)
  end

  defp list_values_to_mapsets(nil), do: nil

  defp list_values_to_mapsets(values) do
    Map.new(values, fn {key, value} ->
      if is_list(value) do
        {key, MapSet.new(value)}
      else
        {key, value}
      end
    end)
  end
end
