defmodule GEPA.State do
  @moduledoc """
  Persistent state tracking the complete optimization history.

  This is the heart of GEPA - all candidates, scores, Pareto fronts,
  and lineage are stored here.
  """

  alias GEPA.Types

  @type t :: %__MODULE__{
          # All discovered program candidates
          program_candidates: [Types.candidate()],

          # Parent relationships (genealogy) - list per program
          parent_program_for_candidate: [[Types.program_idx() | nil]],

          # Sparse validation scores (only evaluated examples)
          prog_candidate_val_subscores: [Types.sparse_scores()],

          # Pareto front tracking
          pareto_front_valset: %{Types.data_id() => float()},
          program_at_pareto_front_valset: Types.pareto_fronts(),

          # Component metadata
          list_of_named_predictors: [String.t()],
          named_predictor_id_to_update_next_for_program_candidate: [non_neg_integer()],

          # Iteration tracking
          i: non_neg_integer(),
          num_full_ds_evals: non_neg_integer(),
          total_num_evals: non_neg_integer(),
          num_metric_calls_by_discovery: [non_neg_integer()],

          # Trace and metadata
          full_program_trace: [map()],
          best_outputs_valset: %{Types.data_id() => [{Types.program_idx(), term()}]} | nil,
          validation_schema_version: pos_integer()
        }

  @enforce_keys [
    :program_candidates,
    :parent_program_for_candidate,
    :prog_candidate_val_subscores,
    :pareto_front_valset,
    :program_at_pareto_front_valset,
    :list_of_named_predictors
  ]

  defstruct [
    :program_candidates,
    :parent_program_for_candidate,
    :prog_candidate_val_subscores,
    :pareto_front_valset,
    :program_at_pareto_front_valset,
    :list_of_named_predictors,
    named_predictor_id_to_update_next_for_program_candidate: [],
    i: 0,
    num_full_ds_evals: 0,
    total_num_evals: 0,
    num_metric_calls_by_discovery: [],
    full_program_trace: [],
    best_outputs_valset: nil,
    validation_schema_version: 2
  ]
end
