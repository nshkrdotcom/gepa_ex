defmodule GEPA.Proposer.Reflective do
  # The proposal flow mirrors the official GEPA evaluate/propose/evaluate loop.
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  @moduledoc """
  Reflective mutation proposer.

  Generates new candidates through reflection on execution traces.
  Candidate text must be proposed by the adapter, a custom proposer, or an
  `instruction_proposal` backed by a reflection LLM.

  ## With LLM-based Instruction Proposal

      llm = GEPA.LLM.req_llm(:openai)
      instruction_proposal = GEPA.Proposer.InstructionProposal.new(llm: llm)

      proposer = Reflective.new(
        adapter: my_adapter,
        trainset: trainset,
        instruction_proposal: instruction_proposal
      )

  ## Without LLM

  If the adapter does not implement `propose_new_texts/4` or `/3`, pass a
  `custom_candidate_proposer` function. GEPA no longer ships a production
  placeholder mutation path.
  """

  alias GEPA.Adapter.Dispatch
  alias GEPA.CandidateProposal.SubsampleEvaluation
  alias GEPA.Proposer.InstructionProposal
  alias GEPA.Strategies.BatchSampler.EpochShuffled
  alias GEPA.Strategies.ComponentSelector.RoundRobin

  defstruct [
    :adapter,
    :trainset,
    :candidate_selector,
    :batch_sampler,
    :module_selector,
    :perfect_score,
    :skip_perfect_score,
    :minibatch_size,
    :instruction_proposal,
    :custom_candidate_proposer,
    :callbacks
  ]

  @type t :: %__MODULE__{
          adapter: term(),
          trainset: GEPA.DataLoader.t(),
          candidate_selector: module() | struct(),
          batch_sampler: module() | struct(),
          module_selector: module() | struct(),
          perfect_score: float(),
          skip_perfect_score: boolean(),
          minibatch_size: pos_integer(),
          instruction_proposal: InstructionProposal.t() | nil,
          custom_candidate_proposer: function() | nil,
          callbacks: [term()] | nil
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      adapter: opts[:adapter],
      trainset: opts[:trainset],
      candidate_selector: opts[:candidate_selector] || GEPA.Strategies.CandidateSelector.Pareto,
      batch_sampler:
        opts[:batch_sampler] ||
          EpochShuffled.new(
            minibatch_size: opts[:minibatch_size] || 3,
            seed: opts[:seed] || 0
          ),
      module_selector: opts[:module_selector] || RoundRobin,
      perfect_score: opts[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(opts, :skip_perfect_score, true),
      minibatch_size: opts[:minibatch_size] || 3,
      instruction_proposal: opts[:instruction_proposal],
      custom_candidate_proposer: opts[:custom_candidate_proposer],
      callbacks: opts[:callbacks] || []
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
     - Adapter `propose_new_texts`
     - Custom proposer
     - LLM-backed `instruction_proposal`
  6. Evaluate new candidate
  7. Return proposal if improved
  """
  @spec propose(t(), GEPA.State.t()) ::
          {:ok, GEPA.CandidateProposal.t(), t(), GEPA.State.t()}
          | {:error, term(), t(), GEPA.State.t()}
          | {:none, t(), GEPA.State.t(), map()}
  def propose(%__MODULE__{} = proposer, state) do
    rand_state = seeded_rand_state(state)

    {candidate_idx, updated_selector, _new_rand} =
      select_candidate(proposer.candidate_selector, state, rand_state)

    proposer = %{proposer | candidate_selector: updated_selector}
    candidate = Enum.at(state.program_candidates, candidate_idx)
    iteration = state.i + 1

    candidate_score =
      average_score(Enum.at(state.prog_candidate_val_subscores, candidate_idx, %{}))

    GEPA.Callbacks.notify(proposer.callbacks, :candidate_selected, %{
      iteration: iteration,
      candidate_idx: candidate_idx,
      candidate: candidate,
      score: candidate_score
    })

    {trainset_ids, batch_sampler} =
      next_batch(proposer.batch_sampler, proposer.trainset, state, proposer.minibatch_size)

    proposer = %{proposer | batch_sampler: batch_sampler}
    minibatch = GEPA.DataLoader.fetch(proposer.trainset, trainset_ids)

    GEPA.Callbacks.notify(proposer.callbacks, :minibatch_sampled, %{
      iteration: iteration,
      minibatch_ids: trainset_ids,
      trainset_size: length(GEPA.DataLoader.all_ids(proposer.trainset))
    })

    adapter = proposer.adapter
    capture_traces = true

    case Dispatch.evaluate(adapter, minibatch, candidate, capture_traces) do
      {:ok, eval_curr} ->
        current_metric_calls = evaluation_metric_calls(eval_curr, trainset_ids)

        cond do
          no_trajectories?(eval_curr) ->
            GEPA.Callbacks.notify(proposer.callbacks, :evaluation_skipped, %{
              iteration: iteration,
              candidate_idx: candidate_idx,
              reason: :no_trajectories,
              scores: eval_curr.scores
            })

            {:none, proposer, state,
             %{num_metric_calls: current_metric_calls, reason: :no_trajectories}}

          proposer.skip_perfect_score and all_perfect?(eval_curr.scores, proposer.perfect_score) ->
            GEPA.Callbacks.notify(proposer.callbacks, :evaluation_skipped, %{
              iteration: iteration,
              candidate_idx: candidate_idx,
              reason: :all_scores_perfect,
              scores: eval_curr.scores
            })

            {:none, proposer, state,
             %{num_metric_calls: current_metric_calls, reason: :all_scores_perfect}}

          true ->
            {components, state} =
              select_components(
                proposer.module_selector,
                state,
                candidate_idx,
                candidate,
                eval_curr
              )

            case generate_improved_candidate(proposer, candidate, eval_curr, components) do
              {:ok, new_candidate, proposal_metadata} ->
                case Dispatch.evaluate(adapter, minibatch, new_candidate, false) do
                  {:ok, eval_new} ->
                    num_metric_calls =
                      current_metric_calls + evaluation_metric_calls(eval_new, trainset_ids)

                    {:ok,
                     %GEPA.CandidateProposal{
                       candidate: new_candidate,
                       parent_program_ids: [candidate_idx],
                       subsample_indices: trainset_ids,
                       subsample_scores_before: eval_curr.scores,
                       subsample_scores_after: eval_new.scores,
                       eval_before: subsample_eval(eval_curr),
                       eval_after: subsample_eval(eval_new),
                       tag: "reflective_mutation",
                       metadata:
                         Map.merge(proposal_metadata, %{
                           new_instructions: changed_components(candidate, new_candidate),
                           trajectories?: true,
                           num_metric_calls: num_metric_calls
                         })
                     }, proposer, state}

                  {:error, reason} ->
                    {:error, reason, proposer, state}
                end

              {:error, reason} ->
                {:error, {:proposal_generation_failed, reason}, proposer, state}
            end
        end

      {:error, reason} ->
        {:error, reason, proposer, state}
    end
  end

  # Private helpers

  defp all_perfect?([], _perfect_score), do: false

  defp all_perfect?(scores, perfect_score) do
    Enum.all?(scores, &(&1 >= perfect_score))
  end

  defp seeded_rand_state(state) do
    a = :erlang.phash2({__MODULE__, :iteration, state.i})
    b = :erlang.phash2({__MODULE__, :evals, state.total_num_evals})
    c = :erlang.phash2({__MODULE__, :programs, length(state.program_candidates)})
    :rand.seed(:exsss, {a + 1, b + 1, c + 1})
  end

  defp evaluation_metric_calls(eval_batch, ids) do
    if is_integer(eval_batch.num_metric_calls) do
      eval_batch.num_metric_calls
    else
      length(ids)
    end
  end

  defp no_trajectories?(eval_batch) do
    is_nil(eval_batch.trajectories) or eval_batch.trajectories == []
  end

  defp subsample_eval(eval_batch) do
    %SubsampleEvaluation{
      scores: eval_batch.scores,
      outputs: eval_batch.outputs,
      objective_scores: eval_batch.objective_scores,
      trajectories: eval_batch.trajectories
    }
  end

  defp average_score(scores) when map_size(scores) == 0, do: 0.0

  defp average_score(scores) do
    values = Map.values(scores)
    Enum.sum(values) / length(values)
  end

  defp next_batch(sampler, trainset, state, minibatch_size) do
    cond do
      is_map(sampler) and Map.has_key?(sampler, :__struct__) and
          function_exported?(sampler.__struct__, :next_batch, 3) ->
        sampler.__struct__.next_batch(sampler, trainset, state)

      is_map(sampler) and Map.has_key?(sampler, :__struct__) and
          function_exported?(sampler.__struct__, :next_minibatch_ids, 3) ->
        {sampler.__struct__.next_minibatch_ids(sampler, trainset, state), sampler}

      is_atom(sampler) and function_exported?(sampler, :next_batch, 3) ->
        case sampler.next_batch(sampler, trainset, state) do
          {batch, updated_sampler} -> {batch, updated_sampler}
          batch when is_list(batch) -> {batch, sampler}
        end

      is_atom(sampler) and function_exported?(sampler, :next_minibatch_ids, 2) ->
        {sampler.next_minibatch_ids(trainset, state), sampler}

      true ->
        GEPA.DataLoader.all_ids(trainset)
        |> Enum.take(minibatch_size)
        |> then(&{&1, sampler})
    end
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

  defp select_components(selector, state, candidate_idx, candidate, eval_batch) do
    cond do
      is_atom(selector) and function_exported?(selector, :select, 5) ->
        selector.select(
          state,
          eval_batch.trajectories,
          eval_batch.scores,
          candidate_idx,
          candidate
        )

      is_atom(selector) and function_exported?(selector, :select, 3) ->
        selector.select(state, candidate_idx, candidate)

      is_map(selector) and Map.has_key?(selector, :__struct__) and
          function_exported?(selector.__struct__, :select, 6) ->
        selector.__struct__.select(
          selector,
          state,
          eval_batch.trajectories,
          eval_batch.scores,
          candidate_idx,
          candidate
        )

      is_map(selector) and Map.has_key?(selector, :__struct__) and
          function_exported?(selector.__struct__, :select, 4) ->
        selector.__struct__.select(selector, state, candidate_idx, candidate)

      true ->
        RoundRobin.select(state, candidate_idx, candidate)
    end
  end

  defp generate_improved_candidate(proposer, candidate, eval_batch, components) do
    adapter = proposer.adapter

    case Dispatch.make_reflective_dataset(adapter, candidate, eval_batch, components) do
      {:ok, reflective_dataset} ->
        GEPA.Callbacks.notify(proposer.callbacks, :reflective_dataset_built, %{
          components: components,
          dataset: reflective_dataset
        })

        with {:ok, new_texts, prompts, raw_lm_outputs} <-
               propose_new_texts(proposer, candidate, reflective_dataset, components) do
          new_candidate = Map.merge(candidate, new_texts)

          GEPA.Callbacks.notify(proposer.callbacks, :proposal_generated_texts, %{
            new_instructions: new_texts,
            prompts: prompts,
            raw_lm_outputs: raw_lm_outputs
          })

          {:ok, new_candidate, %{prompts: prompts, raw_lm_outputs: raw_lm_outputs}}
        end

      {:error, reason} ->
        {:error, {:reflective_dataset_failed, reason}}
    end
  end

  defp propose_new_texts(proposer, candidate, reflective_dataset, components) do
    empty_metadata = {%{}, %{}}

    case Dispatch.propose_new_texts(proposer.adapter, candidate, reflective_dataset, components) do
      {:ok, _new_texts, _prompts, _raw_outputs} = ok ->
        ok

      {:error, _reason} = error ->
        error

      :missing ->
        cond do
          is_function(proposer.custom_candidate_proposer, 3) ->
            normalize_new_texts(
              proposer.custom_candidate_proposer.(candidate, reflective_dataset, components),
              empty_metadata
            )

          proposer.instruction_proposal != nil ->
            InstructionProposal.propose_batch_with_metadata(
              proposer.instruction_proposal,
              candidate,
              reflective_dataset,
              components
            )

          true ->
            {:error, :missing_proposal_source}
        end
    end
  end

  defp normalize_new_texts({:ok, new_texts}, {prompts, raw_outputs}) when is_map(new_texts) do
    {:ok, new_texts, prompts, raw_outputs}
  end

  defp normalize_new_texts({:ok, new_texts, prompts, raw_outputs}, _metadata)
       when is_map(new_texts) and is_map(prompts) and is_map(raw_outputs) do
    {:ok, new_texts, prompts, raw_outputs}
  end

  defp normalize_new_texts({:error, reason}, _metadata), do: {:error, reason}

  defp normalize_new_texts(new_texts, {prompts, raw_outputs}) when is_map(new_texts) do
    {:ok, new_texts, prompts, raw_outputs}
  end

  defp normalize_new_texts(other, _metadata) do
    {:error, {:invalid_proposal_result, other}}
  end

  defp changed_components(original, updated) do
    for {key, value} <- updated, Map.get(original, key) != value, into: %{} do
      {key, value}
    end
  end
end
