defmodule GEPA.Types do
  @moduledoc """
  Shared type specifications for GEPA.
  """

  @typedoc "Program candidate - maps component names to their text implementations"
  @type candidate :: %{String.t() => String.t()}

  @typedoc "Program index in state"
  @type program_idx :: non_neg_integer()

  @typedoc "Data identifier (generic, can be int, string, etc.)"
  @type data_id :: term()

  @typedoc "Data instance (user-defined)"
  @type data_inst :: term()

  @typedoc "Trajectory (user-defined execution trace)"
  @type trajectory :: term()

  @typedoc "Rollout output (user-defined program output)"
  @type rollout_output :: term()

  @typedoc "Score (higher is better)"
  @type score :: float()

  @typedoc "Sparse validation scores"
  @type sparse_scores :: %{data_id() => score()}

  @typedoc "Pareto front per validation example"
  @type pareto_fronts :: %{data_id() => MapSet.t(program_idx())}
end
