defmodule GEPA.Proposer do
  @moduledoc """
  Behavior for candidate proposal strategies.

  Proposers generate new candidate programs based on the current optimizer state.
  They implement the mutation logic that drives the evolutionary search.

  ## Proposal Types

  - **Reflective Mutation**: Uses LLM-based reflection on execution traces
  - **Merge**: Combines successful programs through genealogy analysis

  ## Example Implementation

      defmodule MyProposer do
        @behaviour GEPA.Proposer

        @impl true
        def propose(state) do
          # Analyze state, generate new candidate
          # Return {:ok, proposal}, :none, or {:error, reason}
        end
      end
  """

  @doc """
  Propose a new candidate program based on current state.

  ## Parameters

  - `state`: Current GEPA optimization state

  ## Returns

  - `{:ok, proposal}`: Successfully generated proposal
  - `:none`: No proposal could be generated (e.g., perfect scores already)
  - `{:error, reason}`: Failure to generate proposal

  ## Contract

  - Proposers may evaluate candidates on subsamples
  - Proposers should update `state.total_num_evals` if they evaluate
  - Proposers should add trace information to `state.full_program_trace`
  - The engine handles full validation evaluation and acceptance
  """
  @callback propose(GEPA.State.t()) ::
              {:ok, GEPA.CandidateProposal.t()} | :none | {:error, term()}
end
