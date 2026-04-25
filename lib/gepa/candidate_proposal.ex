defmodule GEPA.CandidateProposal.SubsampleEvaluation do
  @moduledoc """
  Rich evaluation data captured for a proposal minibatch.

  This mirrors upstream's `SubsampleEvaluation`: scores remain the compact
  acceptance surface, while outputs, objective scores, and trajectories are
  retained for callbacks, tracking, and custom acceptance logic.
  """

  @type t :: %__MODULE__{
          scores: [float()],
          outputs: [term()],
          objective_scores: [%{String.t() => float()}] | nil,
          trajectories: [term()] | nil
        }

  @enforce_keys [:scores]
  defstruct [:scores, outputs: [], objective_scores: nil, trajectories: nil]
end

defmodule GEPA.CandidateProposal do
  @moduledoc """
  A proposed new candidate program with metadata for acceptance testing.

  A proposal contains the new candidate program along with information about
  its parents and subsample evaluation results that can be used to decide
  whether to accept the proposal.

  ## Fields

  - `candidate`: The new program as a map of component name -> text
  - `parent_program_ids`: List of parent program indices (1 for mutation, 2+ for merge)
  - `subsample_indices`: Data IDs used for subsample evaluation
  - `subsample_scores_before`: Parent scores on subsample
  - `subsample_scores_after`: New candidate scores on subsample
  - `eval_before`: Rich parent minibatch evaluation data
  - `eval_after`: Rich proposed-candidate minibatch evaluation data
  - `tag`: Proposal type identifier ("reflective_mutation", "merge", etc.)
  - `metadata`: Additional proposal-specific data
  """

  alias GEPA.CandidateProposal.SubsampleEvaluation
  alias GEPA.Strategies.Acceptance
  alias GEPA.Types

  @type t :: %__MODULE__{
          candidate: Types.candidate(),
          parent_program_ids: [Types.program_idx()],
          subsample_indices: [Types.data_id()] | nil,
          subsample_scores_before: [float()] | nil,
          subsample_scores_after: [float()] | nil,
          eval_before: SubsampleEvaluation.t() | nil,
          eval_after: SubsampleEvaluation.t() | nil,
          tag: String.t(),
          metadata: map()
        }

  @enforce_keys [:candidate, :parent_program_ids, :tag]
  defstruct [
    :candidate,
    :parent_program_ids,
    :tag,
    subsample_indices: nil,
    subsample_scores_before: nil,
    subsample_scores_after: nil,
    eval_before: nil,
    eval_after: nil,
    metadata: %{}
  ]

  @doc """
  Check if proposal should be accepted.

  The default acceptance criterion is strict improvement:
  `sum(new_scores) > sum(old_scores)`.

  ## Examples

      iex> proposal = %GEPA.CandidateProposal{
      ...>   candidate: %{},
      ...>   parent_program_ids: [0],
      ...>   tag: "test",
      ...>   subsample_scores_before: [0.5, 0.6],
      ...>   subsample_scores_after: [0.7, 0.8]
      ...> }
      iex> GEPA.CandidateProposal.should_accept?(proposal)
      true

      iex> proposal = %GEPA.CandidateProposal{
      ...>   candidate: %{},
      ...>   parent_program_ids: [0],
      ...>   tag: "test",
      ...>   subsample_scores_before: [0.9],
      ...>   subsample_scores_after: [0.8]
      ...> }
      iex> GEPA.CandidateProposal.should_accept?(proposal)
      false
  """
  @spec should_accept?(t()) :: boolean()
  def should_accept?(proposal), do: should_accept?(proposal, :strict_improvement, nil)

  @doc """
  Check if proposal should be accepted using a configurable criterion.
  """
  @spec should_accept?(t(), Acceptance.criterion() | nil, GEPA.State.t() | nil) :: boolean()
  def should_accept?(%__MODULE__{} = proposal, criterion, state) do
    Acceptance.should_accept?(proposal, criterion, state)
  end

  def should_accept?(_, _, _), do: false
end
