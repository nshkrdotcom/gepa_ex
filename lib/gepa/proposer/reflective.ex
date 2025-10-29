defmodule GEPA.Proposer.Reflective do
  @moduledoc """
  Reflective mutation proposer - Simplified MVP version.

  Generates new candidates through reflection on execution traces.
  This version uses a simplified algorithm for MVP functionality.
  """

  defstruct [
    :adapter,
    :trainset,
    :candidate_selector,
    :perfect_score,
    :skip_perfect_score,
    :minibatch_size
  ]

  @type t :: %__MODULE__{
          adapter: term(),
          trainset: GEPA.DataLoader.t(),
          candidate_selector: module(),
          perfect_score: float(),
          skip_perfect_score: boolean(),
          minibatch_size: pos_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      adapter: opts[:adapter],
      trainset: opts[:trainset],
      candidate_selector: opts[:candidate_selector] || GEPA.Strategies.CandidateSelector.Pareto,
      perfect_score: opts[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(opts, :skip_perfect_score, true),
      minibatch_size: opts[:minibatch_size] || 3
    }
  end

  @doc """
  Propose a new candidate through reflective mutation.

  Simplified algorithm:
  1. Select candidate from Pareto front
  2. Sample minibatch from training set
  3. Evaluate with trace capture
  4. Check for perfect scores (optional skip)
  5. Generate improved version (simplified)
  6. Evaluate new candidate
  7. Return proposal if improved
  """
  def propose(%__MODULE__{} = proposer, state) do
    # Step 1: Select candidate
    rand_state = :rand.seed(:exsss, {state.i, 42, state.total_num_evals})

    {candidate_idx, _new_rand} = proposer.candidate_selector.select(state, rand_state)
    candidate = Enum.at(state.program_candidates, candidate_idx)

    # Step 2: Sample minibatch (simplified - just take first N)
    trainset_ids =
      GEPA.DataLoader.all_ids(proposer.trainset)
      |> Enum.take(proposer.minibatch_size)

    minibatch = GEPA.DataLoader.fetch(proposer.trainset, trainset_ids)

    # Step 3: Evaluate current candidate with traces
    adapter = proposer.adapter

    case adapter.__struct__.evaluate(adapter, minibatch, candidate, true) do
      {:ok, eval_curr} ->
        # Step 4: Check for perfect score
        if proposer.skip_perfect_score and all_perfect?(eval_curr.scores, proposer.perfect_score) do
          :none
        else
          # Step 5: Generate improved candidate (simplified)
          new_candidate = improve_candidate(candidate)

          # Step 6: Evaluate new candidate
          case adapter.__struct__.evaluate(adapter, minibatch, new_candidate, false) do
            {:ok, eval_new} ->
              # Return proposal
              {:ok,
               %GEPA.CandidateProposal{
                 candidate: new_candidate,
                 parent_program_ids: [candidate_idx],
                 subsample_indices: trainset_ids,
                 subsample_scores_before: eval_curr.scores,
                 subsample_scores_after: eval_new.scores,
                 tag: "reflective_mutation"
               }}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers

  defp all_perfect?(scores, perfect_score) do
    Enum.all?(scores, &(&1 >= perfect_score))
  end

  defp improve_candidate(candidate) do
    # Simplified for MVP - append improvement marker
    # In full version, this would use LLM with reflective dataset
    for {key, value} <- candidate, into: %{} do
      {key, value <> "\n[Optimized]"}
    end
  end
end
