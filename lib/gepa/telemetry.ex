defmodule GEPA.Telemetry do
  @moduledoc """
  Telemetry helpers for GEPA.

  Provides a stable event schema for lifecycle, iteration, proposal, and
  evaluation events. This keeps GEPA free of tracker-specific code while
  allowing external handlers to attach and forward to W&B, MLflow, etc.
  """

  alias GEPA.{EvaluationBatch, State}

  @schema_version "1.0.0"

  @doc """
  Schema version for telemetry metadata.
  """
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc """
  Emit run start with sanitized config and schema version.
  """
  @spec emit_run_start(map()) :: :ok
  def emit_run_start(config) do
    :telemetry.execute(
      [:gepa, :run, :start],
      %{system_time: System.system_time()},
      %{config: sanitize_config(config), schema_version: @schema_version}
    )
  end

  @doc """
  Emit run stop summary.
  """
  @spec emit_run_stop(State.t(), integer()) :: :ok
  def emit_run_stop(state, run_start_ms) do
    {best_score, best_idx} = best_info(state)

    :telemetry.execute(
      [:gepa, :run, :stop],
      %{
        duration_ms: System.monotonic_time(:millisecond) - run_start_ms,
        iterations: state.i,
        total_metric_calls: state.total_num_evals,
        valset_size: map_size(state.pareto_front_valset),
        pareto_front_size: map_size(state.program_at_pareto_front_valset),
        best_score: best_score
      },
      %{
        best_idx: best_idx,
        best_candidate: Enum.at(state.program_candidates, best_idx),
        result_summary: nil
      }
    )
  end

  @doc """
  Emit baseline evaluation for the seed program.
  """
  @spec emit_baseline(EvaluationBatch.t(), non_neg_integer()) :: :ok
  def emit_baseline(%EvaluationBatch{} = eval_batch, valset_size) do
    coverage = length(eval_batch.scores)
    avg = average(eval_batch.scores)

    :telemetry.execute(
      [:gepa, :baseline, :computed],
      %{
        iteration: 0,
        base_program_full_valset_score: avg,
        base_program_val_coverage: coverage
      },
      %{valset_size: valset_size}
    )
  end

  @doc """
  Emit iteration start.
  """
  @spec emit_iteration_start(non_neg_integer(), term()) :: :ok
  def emit_iteration_start(iteration, selected_program_candidate) do
    :telemetry.execute(
      [:gepa, :iteration, :start],
      %{
        iteration: iteration,
        system_time: System.system_time()
      },
      %{selected_program_candidate: selected_program_candidate}
    )
  end

  @doc """
  Emit iteration stop with performance metrics.
  """
  @spec emit_iteration_stop(
          State.t(),
          non_neg_integer(),
          number(),
          boolean(),
          float(),
          float(),
          term(),
          [term()] | nil,
          [term()] | nil,
          integer()
        ) :: :ok
  # Telemetry event payload is intentionally explicit to keep callsites clear.
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def emit_iteration_stop(
        state,
        iteration,
        prev_best,
        accepted,
        subsample_before_sum,
        subsample_after_sum,
        proposal_tag,
        parent_program_ids,
        subsample_ids,
        iteration_duration_ms
      ) do
    {best_score, _} = best_info(state)

    :telemetry.execute(
      [:gepa, :iteration, :stop],
      %{
        iteration: iteration,
        proposal_accepted: accepted,
        best_score: best_score,
        best_score_delta: best_score - prev_best,
        pareto_front_size: map_size(state.program_at_pareto_front_valset),
        subsample_before_sum: subsample_before_sum,
        subsample_after_sum: subsample_after_sum,
        total_metric_calls: state.total_num_evals,
        iteration_duration_ms: iteration_duration_ms
      },
      %{
        proposal_type: proposal_tag,
        selected_program_candidate: first_or_nil(parent_program_ids),
        parent_program_ids: parent_program_ids,
        subsample_ids: subsample_ids
      }
    )
  end

  @doc """
  Emit proposal generation details.
  """
  @spec emit_proposal_generated(GEPA.CandidateProposal.t(), non_neg_integer()) :: :ok
  def emit_proposal_generated(proposal, iteration) do
    before_sum = Enum.sum(proposal.subsample_scores_before || [])
    after_sum = Enum.sum(proposal.subsample_scores_after || [])
    delta = after_sum - before_sum

    :telemetry.execute(
      [:gepa, :proposal, :generated],
      %{
        iteration: iteration,
        subsample_before_sum: before_sum,
        subsample_after_sum: after_sum,
        subsample_delta: delta
      },
      %{
        tag: proposal.tag,
        new_instructions: Map.get(proposal.metadata, :new_instructions, %{}),
        trajectories?: Map.get(proposal.metadata, :trajectories?, false)
      }
    )
  end

  @doc """
  Emit proposal decision (accepted/rejected).
  """
  @spec emit_proposal_decision(
          GEPA.CandidateProposal.t() | nil,
          non_neg_integer(),
          boolean(),
          atom(),
          float(),
          [term()] | nil
        ) :: :ok
  def emit_proposal_decision(proposal, iteration, accepted, reason, subsample_delta, parent_ids) do
    :telemetry.execute(
      [:gepa, :proposal, :decision],
      %{
        iteration: iteration,
        accepted: accepted,
        subsample_delta: subsample_delta
      },
      %{
        tag: proposal && proposal.tag,
        reason: reason,
        parent_program_ids: parent_ids,
        selected_program_candidate: first_or_nil(parent_ids)
      }
    )
  end

  @doc """
  Emit valset update after accepting a program.
  """
  @spec emit_valset_update(
          State.t(),
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) :: :ok
  def emit_valset_update(state, iteration, new_program_idx, val_scores) do
    val_program_average = average(Map.values(val_scores))
    val_coverage = map_size(val_scores)
    pareto_avg = average(Map.values(state.pareto_front_valset))
    {best_score, best_idx} = best_info(state)

    :telemetry.execute(
      [:gepa, :valset, :update],
      %{
        iteration: iteration,
        val_program_average: val_program_average,
        val_coverage: val_coverage,
        valset_pareto_front_agg: pareto_avg,
        best_valset_agg_score: best_score
      },
      %{
        new_program_idx: new_program_idx,
        linear_pareto_front_program_idx: best_idx,
        pareto_front_programs:
          Enum.into(state.program_at_pareto_front_valset, %{}, fn {k, v} ->
            {k, MapSet.to_list(v)}
          end),
        valset_scores_new_program: val_scores,
        pareto_front_scores: state.pareto_front_valset
      }
    )
  end

  @doc """
  Emit evaluation batch event (train or val).
  """
  @spec emit_evaluation_batch(
          non_neg_integer(),
          :train | :val,
          non_neg_integer(),
          integer(),
          [number()],
          non_neg_integer() | nil,
          String.t() | nil
        ) :: :ok
  def emit_evaluation_batch(
        iteration,
        dataset,
        batch_size,
        duration_ms,
        scores,
        candidate_idx \\ nil,
        candidate_tag \\ nil
      ) do
    :telemetry.execute(
      [:gepa, :evaluation, :batch],
      %{
        iteration: iteration,
        batch_size: batch_size,
        duration_ms: duration_ms,
        mean_score: average(scores)
      },
      %{
        scores: scores,
        dataset: dataset,
        candidate_idx: candidate_idx,
        candidate_tag: candidate_tag
      }
    )
  end

  # Helpers

  defp sanitize_config(config) when is_map(config) do
    config
    |> Map.put(:adapter, "[Adapter]")
    |> Map.put(:trainset, "[DataLoader]")
    |> Map.put(:valset, "[DataLoader]")
  end

  defp average([]), do: 0.0
  defp average(values) when is_list(values), do: Enum.sum(values) / length(values)

  defp first_or_nil(list) when is_list(list), do: List.first(list)
  defp first_or_nil(_), do: nil

  defp best_info(state) do
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {scores, idx} ->
      avg =
        if map_size(scores) == 0 do
          0.0
        else
          Enum.sum(Map.values(scores)) / map_size(scores)
        end

      {avg, idx}
    end)
    |> Enum.max_by(fn {score, _idx} -> score end, fn -> {0.0, 0} end)
  end
end
