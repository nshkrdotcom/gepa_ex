defmodule GEPA.Strategies.Acceptance do
  @moduledoc """
  Acceptance criteria for proposed GEPA candidates.

  Mirrors the official Python acceptance strategy seam while keeping the
  Elixir API small: built-in criteria are modules, and advanced users may pass
  a two-arity function receiving `{proposal, state}`.
  """

  alias GEPA.CandidateProposal

  @type criterion ::
          :strict_improvement
          | :improvement_or_equal
          | module()
          | struct()
          | (CandidateProposal.t(), GEPA.State.t() | nil -> boolean())

  @callback should_accept(CandidateProposal.t(), GEPA.State.t() | nil) :: boolean()

  @doc """
  Normalize user-facing criterion names to implementation modules.
  """
  @spec normalize(criterion() | nil) :: criterion()
  def normalize(nil), do: GEPA.Strategies.Acceptance.StrictImprovement
  def normalize(:strict_improvement), do: GEPA.Strategies.Acceptance.StrictImprovement
  def normalize(:improvement_or_equal), do: GEPA.Strategies.Acceptance.ImprovementOrEqual
  def normalize(criterion), do: criterion

  @doc """
  Apply an acceptance criterion to a proposal.
  """
  @spec should_accept?(CandidateProposal.t(), criterion() | nil, GEPA.State.t() | nil) ::
          boolean()
  def should_accept?(%CandidateProposal{} = proposal, criterion, state) do
    criterion = normalize(criterion)

    cond do
      is_function(criterion, 2) ->
        criterion.(proposal, state)

      is_atom(criterion) and Code.ensure_loaded?(criterion) and
          function_exported?(criterion, :should_accept, 2) ->
        criterion.should_accept(proposal, state)

      is_map(criterion) ->
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
  @moduledoc """
  Accept only if the new subsample score sum is strictly greater than the old sum.
  """

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
  @moduledoc """
  Accept if the new subsample score sum is greater than or equal to the old sum.
  """

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
