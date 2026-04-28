defmodule GEPA.Strategies.Acceptance do
  @moduledoc """
  Acceptance criteria for proposed GEPA candidates.

  Reflective mutations use a pluggable acceptance criterion. Merge proposals are
  intentionally accepted with the official merge rule: the merged program's
  subsample score sum must be at least the better parent sum. That rule is not
  user-overridable in the Python engine and is kept separate here as well.
  """

  alias GEPA.CandidateProposal

  @type criterion ::
          :strict_improvement
          | :improvement_or_equal
          | module()
          | struct()
          | (CandidateProposal.t(), GEPA.State.t() | nil -> boolean())

  @callback should_accept(CandidateProposal.t(), GEPA.State.t() | nil) :: boolean()

  @spec normalize(criterion() | nil) :: criterion()
  def normalize(nil), do: GEPA.Strategies.Acceptance.StrictImprovement
  def normalize(:strict_improvement), do: GEPA.Strategies.Acceptance.StrictImprovement
  def normalize(:improvement_or_equal), do: GEPA.Strategies.Acceptance.ImprovementOrEqual
  def normalize(criterion), do: criterion

  @spec should_accept?(CandidateProposal.t(), criterion() | nil, GEPA.State.t() | nil) ::
          boolean()
  def should_accept?(%CandidateProposal{tag: "merge"} = proposal, _criterion, _state) do
    with parent_sums when is_list(parent_sums) and parent_sums != [] <-
           proposal.subsample_scores_before,
         after_scores when is_list(after_scores) <- proposal.subsample_scores_after do
      Enum.sum(after_scores) >= Enum.max(parent_sums)
    else
      _ -> false
    end
  end

  def should_accept?(%CandidateProposal{} = proposal, criterion, state) do
    criterion = normalize(criterion)

    cond do
      is_function(criterion, 2) ->
        criterion.(proposal, state)

      is_atom(criterion) and Code.ensure_loaded?(criterion) and
          function_exported?(criterion, :should_accept, 2) ->
        criterion.should_accept(proposal, state)

      is_map(criterion) and Map.has_key?(criterion, :__struct__) ->
        module = criterion.__struct__

        if function_exported?(module, :should_accept, 3) do
          module.should_accept(criterion, proposal, state)
        else
          false
        end

      true ->
        false
    end
  end
end

defmodule GEPA.Strategies.Acceptance.StrictImprovement do
  @moduledoc "Accept only if the new subsample score sum is strictly greater than the old sum."

  @behaviour GEPA.Strategies.Acceptance

  @impl true
  def should_accept(proposal, _state) do
    with before_scores when is_list(before_scores) <- proposal.subsample_scores_before,
         after_scores when is_list(after_scores) <- proposal.subsample_scores_after do
      Enum.sum(after_scores) > Enum.sum(before_scores)
    else
      _ -> false
    end
  end
end

defmodule GEPA.Strategies.Acceptance.ImprovementOrEqual do
  @moduledoc "Accept if the new subsample score sum is greater than or equal to the old sum."

  @behaviour GEPA.Strategies.Acceptance

  @impl true
  def should_accept(proposal, _state) do
    with before_scores when is_list(before_scores) <- proposal.subsample_scores_before,
         after_scores when is_list(after_scores) <- proposal.subsample_scores_after do
      Enum.sum(after_scores) >= Enum.sum(before_scores)
    else
      _ -> false
    end
  end
end
