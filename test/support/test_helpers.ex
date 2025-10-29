defmodule GEPA.TestHelpers do
  @moduledoc """
  Test helper functions for GEPA tests.
  """

  @doc """
  Creates a minimal valid state for testing.
  """
  def create_test_state(opts \\ []) do
    %GEPA.State{
      program_candidates: opts[:candidates] || [%{"instruction" => "seed"}],
      parent_program_for_candidate: opts[:parents] || [[nil]],
      prog_candidate_val_subscores: opts[:subscores] || [%{}],
      pareto_front_valset: opts[:fronts] || %{},
      program_at_pareto_front_valset: opts[:front_programs] || %{},
      list_of_named_predictors: opts[:predictors] || ["instruction"],
      named_predictor_id_to_update_next_for_program_candidate: opts[:next_predictors] || [0],
      i: opts[:iteration] || 0,
      num_full_ds_evals: 0,
      total_num_evals: 0,
      num_metric_calls_by_discovery: [],
      full_program_trace: [],
      best_outputs_valset: nil,
      validation_schema_version: 2
    }
  end

  @doc """
  Creates a test candidate.
  """
  def create_test_candidate(components \\ nil) do
    components || %{"instruction" => "You are a helpful assistant."}
  end

  @doc """
  Creates a test evaluation batch.
  """
  def create_test_eval_batch(n, score \\ 0.8) do
    %GEPA.EvaluationBatch{
      outputs: List.duplicate("output", n),
      scores: List.duplicate(score, n),
      trajectories: nil
    }
  end

  @doc """
  Creates test data instances.
  """
  def create_test_data(n) do
    for i <- 1..n do
      %{input: "Question #{i}", answer: "Answer #{i}"}
    end
  end
end
