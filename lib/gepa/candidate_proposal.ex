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
  - `tag`: Proposal type identifier ("reflective_mutation", "merge", etc.)
  - `metadata`: Additional proposal-specific data
  """

  alias GEPA.Types

  @type t :: %__MODULE__{
          candidate: Types.candidate(),
          parent_program_ids: [Types.program_idx()],
          subsample_indices: [Types.data_id()] | nil,
          subsample_scores_before: [float()] | nil,
          subsample_scores_after: [float()] | nil,
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
    metadata: %{}
  ]

  @doc """
  Check if proposal should be accepted based on score improvement.

  Acceptance criterion: sum of new scores > sum of old scores

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
  def should_accept?(%__MODULE__{
        subsample_scores_before: before,
        subsample_scores_after: after_scores
      })
      when is_list(before) and is_list(after_scores) do
    Enum.sum(after_scores) > Enum.sum(before)
  end

  def should_accept?(_), do: false
end
