defmodule GEPA.Proposer.Reflective do
  # The proposal flow mirrors the official GEPA evaluate/propose/evaluate loop.
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  @moduledoc """
  Reflective mutation proposer.

  Generates new candidates through reflection on execution traces.
  When an `instruction_proposal` is configured, uses LLM-based improvement.
  Otherwise falls back to a simple placeholder improvement.

  ## With LLM-based Instruction Proposal

      llm = GEPA.LLM.req_llm(:openai)
      instruction_proposal = GEPA.Proposer.InstructionProposal.new(llm: llm)

      proposer = Reflective.new(
        adapter: my_adapter,
        trainset: trainset,
        instruction_proposal: instruction_proposal
      )

  ## Without LLM (Fallback Mode)

      proposer = Reflective.new(
        adapter: my_adapter,
        trainset: trainset
      )
      # Uses simple "[Optimized]" marker - for testing only
  """

  alias GEPA.Proposer.InstructionProposal

  defstruct [
    :adapter,
    :trainset,
    :candidate_selector,
    :perfect_score,
    :skip_perfect_score,
    :minibatch_size,
    :instruction_proposal
  ]

  @type t :: %__MODULE__{
          adapter: term(),
          trainset: GEPA.DataLoader.t(),
          candidate_selector: module() | struct(),
          perfect_score: float(),
          skip_perfect_score: boolean(),
          minibatch_size: pos_integer(),
          instruction_proposal: InstructionProposal.t() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      adapter: opts[:adapter],
      trainset: opts[:trainset],
      candidate_selector: opts[:candidate_selector] || GEPA.Strategies.CandidateSelector.Pareto,
      perfect_score: opts[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(opts, :skip_perfect_score, true),
      minibatch_size: opts[:minibatch_size] || 3,
      instruction_proposal: opts[:instruction_proposal]
    }
  end

  @doc """
  Propose a new candidate through reflective mutation.

  Algorithm:
  1. Select candidate from Pareto front
  2. Sample minibatch from training set
  3. Evaluate with trace capture
  4. Check for perfect scores (optional skip)
  5. Generate improved version:
     - If `instruction_proposal` configured: use LLM with reflective dataset
     - Otherwise: use simple fallback (for testing)
  6. Evaluate new candidate
  7. Return proposal if improved
  """
  @spec propose(t(), GEPA.State.t()) ::
          {:ok, GEPA.CandidateProposal.t(), module() | struct()}
          | {:error, term(), module() | struct()}
          | {:none, module() | struct()}
  def propose(%__MODULE__{} = proposer, state) do
    rand_state = :rand.seed(:exsss, {state.i, 42, state.total_num_evals})

    {candidate_idx, updated_selector, _new_rand} =
      select_candidate(proposer.candidate_selector, state, rand_state)

    proposer = %{proposer | candidate_selector: updated_selector}
    candidate = Enum.at(state.program_candidates, candidate_idx)

    trainset_ids =
      GEPA.DataLoader.all_ids(proposer.trainset)
      |> Enum.take(proposer.minibatch_size)

    minibatch = GEPA.DataLoader.fetch(proposer.trainset, trainset_ids)

    adapter = proposer.adapter
    capture_traces = proposer.instruction_proposal != nil

    case adapter.__struct__.evaluate(adapter, minibatch, candidate, capture_traces) do
      {:ok, eval_curr} ->
        if proposer.skip_perfect_score and all_perfect?(eval_curr.scores, proposer.perfect_score) do
          {:none, proposer.candidate_selector}
        else
          case generate_improved_candidate(proposer, candidate, eval_curr) do
            {:ok, new_candidate} ->
              case adapter.__struct__.evaluate(adapter, minibatch, new_candidate, false) do
                {:ok, eval_new} ->
                  {:ok,
                   %GEPA.CandidateProposal{
                     candidate: new_candidate,
                     parent_program_ids: [candidate_idx],
                     subsample_indices: trainset_ids,
                     subsample_scores_before: eval_curr.scores,
                     subsample_scores_after: eval_new.scores,
                     tag: "reflective_mutation",
                     metadata: %{
                       new_instructions: changed_components(candidate, new_candidate),
                       trajectories?: capture_traces
                     }
                   }, proposer.candidate_selector}

                {:error, reason} ->
                  {:error, reason, proposer.candidate_selector}
              end

            {:error, reason} ->
              {:error, {:proposal_generation_failed, reason}, proposer.candidate_selector}
          end
        end

      {:error, reason} ->
        {:error, reason, proposer.candidate_selector}
    end
  end

  # Private helpers

  defp all_perfect?(scores, perfect_score) do
    Enum.all?(scores, &(&1 >= perfect_score))
  end

  defp select_candidate(selector, state, rand_state) do
    case selector do
      module when is_atom(module) ->
        case module.select(state, rand_state) do
          {idx, new_rand} -> {idx, selector, new_rand}
          {idx, updated_selector, new_rand} -> {idx, updated_selector, new_rand}
        end

      %{__struct__: module} = struct ->
        case module.select(struct, state, rand_state) do
          {idx, new_rand} -> {idx, struct, new_rand}
          {idx, updated_selector, new_rand} -> {idx, updated_selector, new_rand}
        end
    end
  end

  defp generate_improved_candidate(proposer, candidate, eval_batch) do
    case proposer.instruction_proposal do
      nil ->
        # Fallback: simple improvement (for testing without LLM)
        {:ok, simple_improve(candidate)}

      instruction_proposal ->
        # Use LLM-based instruction proposal
        components = Map.keys(candidate)

        # Build reflective dataset from adapter
        adapter = proposer.adapter

        case adapter.__struct__.make_reflective_dataset(
               adapter,
               candidate,
               eval_batch,
               components
             ) do
          {:ok, reflective_dataset} ->
            propose_new_texts(
              proposer,
              instruction_proposal,
              candidate,
              reflective_dataset,
              components
            )

          {:error, reason} ->
            {:error, {:reflective_dataset_failed, reason}}
        end
    end
  end

  defp propose_new_texts(
         proposer,
         instruction_proposal,
         candidate,
         reflective_dataset,
         components
       ) do
    adapter = proposer.adapter
    module = adapter.__struct__

    cond do
      function_exported?(module, :propose_new_texts, 4) ->
        module.propose_new_texts(adapter, candidate, reflective_dataset, components)

      function_exported?(module, :propose_new_texts, 3) ->
        module.propose_new_texts(candidate, reflective_dataset, components)

      true ->
        InstructionProposal.propose_batch(
          instruction_proposal,
          candidate,
          reflective_dataset,
          components
        )
    end
  end

  defp simple_improve(candidate) do
    # Simplified fallback - append improvement marker
    # Only used when instruction_proposal is nil (testing)
    for {key, value} <- candidate, into: %{} do
      {key, value <> "\n[Optimized]"}
    end
  end

  defp changed_components(original, updated) do
    for {key, value} <- updated, Map.get(original, key) != value, into: %{} do
      {key, value}
    end
  end
end
