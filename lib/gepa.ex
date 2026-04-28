defmodule GEPA do
  @moduledoc """
  GEPA: Genetic-Pareto optimizer for text-based system components.

  ## Basic Example

      trainset = [%{input: "What is 2+2?", answer: "4"}, ...]
      valset = [%{input: "What is 5+5?", answer: "10"}]

      {:ok, result} = GEPA.optimize(
        seed_candidate: %{"instruction" => "You are a helpful assistant."},
        trainset: trainset,
        valset: valset,
        adapter: GEPA.Adapters.Basic.new(),
        max_metric_calls: 100
      )

      IO.puts("Best score: \#{GEPA.Result.best_score(result)}")
      IO.inspect(GEPA.Result.best_candidate(result))

  ## With LLM-based Reflection

      llm = GEPA.LLM.req_llm(:openai, model: "gpt-5.4-mini")

      {:ok, result} = GEPA.optimize(
        seed_candidate: %{"instruction" => "You are a helpful assistant."},
        trainset: trainset,
        valset: valset,
        adapter: GEPA.Adapters.Basic.new(),
        max_metric_calls: 100,
        reflection_llm: llm
      )

  This uses the LLM to propose improved instructions based on execution feedback,
  rather than using a simple placeholder improvement.
  """

  alias GEPA.Adapter.Dispatch
  alias GEPA.Adapters.Default
  alias GEPA.EvaluationCache
  alias GEPA.Proposer.InstructionProposal
  alias GEPA.Proposer.Merge

  alias GEPA.StopCondition.{
    FileStopper,
    MaxCalls,
    MaxCandidateProposals,
    MaxReflectionCost,
    MaxTrackedCandidates,
    ScoreThreshold,
    SignalStopper,
    Timeout
  }

  alias GEPA.Strategies.Acceptance
  alias GEPA.Strategies.BatchSampler.EpochShuffled
  alias GEPA.Strategies.CandidateSelector.{CurrentBest, EpsilonGreedy, Pareto, TopKPareto}
  alias GEPA.Strategies.ComponentSelector.{All, RoundRobin}
  alias GEPA.Strategies.EvaluationPolicy.Full

  @doc """
  Run GEPA optimization.

  ## Options

  ### Required
  - `:seed_candidate` - Initial program as map of component -> text
  - `:trainset` - Training data (list or DataLoader)
  - `:adapter` - Adapter module/struct implementing GEPA.Adapter

  If `:adapter` is omitted, provide `:task_lm` or `:model` and GEPA will build
  the default adapter. If `:valset` is omitted, GEPA reuses `:trainset`.

  At least one stopping path is required: `:max_metric_calls`,
  `:max_reflection_cost`, `:max_candidate_proposals`, `:stop_conditions`,
  `:stop_callbacks`, or `:run_dir` (which adds a `gepa.stop` file stopper).

  ### Optional
  - `:valset` - Validation data (list or DataLoader, default: `:trainset`)
  - `:candidate_selection_strategy` / `:candidate_selector` - `:pareto`,
    `:current_best`, `:epsilon_greedy`, `:top_k_pareto`, or a custom selector
    (default: `:pareto`)
  - `:batch_sampler` - Batch sampler or `:epoch_shuffled` (default:
    `:epoch_shuffled`)
  - `:module_selector` - `:round_robin`, `:all`, or a custom component selector
    (default: `:round_robin`)
  - `:val_evaluation_policy` - `:full_eval` or a custom evaluation policy
    (default: `:full_eval`)
  - `:reflection_minibatch_size` - Minibatch size (default: 3)
  - `:perfect_score` - Perfect score value (default: 1.0)
  - `:skip_perfect_score` - Skip if perfect (default: true)
  - `:seed` - Random seed (default: 0)
  - `:run_dir` - Directory for state persistence (default: nil)
  - `:reflection_llm` - LLM for generating improved instructions (default: nil)
  - `:custom_candidate_proposer` - Function used when no reflection LLM or adapter proposer is available
  - `:proposal_template` - Custom template for instruction proposal (default: built-in)
  - `:structured_output` - Use tool_use / function calling for instruction proposals (default: false)
  - `:acceptance_criterion` - Candidate acceptance criterion (default: `:strict_improvement`)
  - `:cache_evaluation` - Build an evaluation cache automatically (default: `false`)
  - `:raise_on_exception` - Propagate proposer/evaluator exceptions (default: `true`)
  - `:use_merge` - Enable merge proposer construction (default: `false`)
  - `:max_merge_invocations` - Maximum merge attempts when merge is enabled (default: 5)
  - `:merge_val_overlap_floor` - Minimum shared validation IDs for merge subsamples (default: 5)
  - `:callbacks` - Synchronous observational callbacks (default: `[]`)
  - `:track_best_outputs` - Track best validation outputs in state/result (default: `false`)
  - `:frontier_type` - Pareto frontier mode: `:instance`, `:objective`, `:hybrid`, or `:cartesian`
    (default: `:instance`)
  - `:progress` - Enable progress display (default: false). Can be `true` or a keyword
    list with options: `[width: 60, color: true]`

  ## Returns

  `{:ok, result}` where result is a `GEPA.Result` struct

  ## LLM-based Reflection

  When `:reflection_llm` is provided, GEPA uses the LLM to propose improved
  instruction texts based on feedback from execution traces. This is the
  recommended mode for production use.

  Without `:reflection_llm`, the adapter must implement `propose_new_texts/4`
  or `/3`, or you must pass `:custom_candidate_proposer`. GEPA does not use a
  placeholder production mutation path.

  ## Custom Templates

  When using `:reflection_llm`, you can customize the prompt template with
  `:proposal_template`. The template must include these placeholders:

  - `<curr_param>` - Current instruction text
  - `<side_info>` - Formatted examples with feedback

  Legacy `{component_name}`, `{current_instruction}`, and
  `{reflective_dataset}` templates are still accepted for existing Elixir
  callers.

  Example:

      custom_template = \"\"\"
      Improve this instruction:
      Current: <curr_param>
      Examples: <side_info>
      New instruction:
      \"\"\"

      GEPA.optimize(..., reflection_llm: llm, proposal_template: custom_template)
  """
  @spec optimize(Keyword.t()) :: {:ok, GEPA.Result.t()}
  def optimize(opts) do
    # Build configuration
    config = build_config(opts)

    # Run engine
    {:ok, final_state} = GEPA.Engine.run(config)

    # Convert to result
    result = GEPA.Result.from_state(final_state)

    {:ok, result}
  end

  defp build_config(opts) do
    seed_candidate = validate_seed_candidate!(Keyword.get(opts, :seed_candidate))
    train_loader = ensure_loader(fetch_required!(opts, :trainset))
    val_loader = build_val_loader(opts, train_loader)
    adapter = build_adapter(opts)
    validate_adapter_configuration!(opts, adapter)
    seed = Keyword.get(opts, :seed, 0)
    reflection_minibatch_size = Keyword.get(opts, :reflection_minibatch_size, 3)

    %{
      seed_candidate: seed_candidate,
      trainset: train_loader,
      valset: val_loader,
      adapter: adapter,
      candidate_selector: build_candidate_selector(opts),
      stop_conditions: build_stop_conditions(opts),
      max_iterations: Keyword.get(opts, :max_iterations, 1000),
      num_parallel_proposals: Keyword.get(opts, :num_parallel_proposals, 1),
      reflection_minibatch_size: reflection_minibatch_size,
      perfect_score: Keyword.get(opts, :perfect_score, 1.0),
      skip_perfect_score: Keyword.get(opts, :skip_perfect_score, true),
      seed: seed,
      run_dir: opts[:run_dir],
      instruction_proposal: build_instruction_proposal(opts),
      progress: opts[:progress],
      acceptance_criterion: build_acceptance_criterion(opts),
      callbacks: Keyword.get(opts, :callbacks, []),
      track_best_outputs: Keyword.get(opts, :track_best_outputs, false),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      evaluation_cache: build_evaluation_cache(opts),
      batch_sampler: build_batch_sampler(opts, reflection_minibatch_size),
      module_selector: build_module_selector(opts),
      val_evaluation_policy: build_val_evaluation_policy(opts),
      merge_proposer: build_merge_proposer(opts, adapter, val_loader),
      raise_on_exception: Keyword.get(opts, :raise_on_exception, true),
      custom_candidate_proposer: Keyword.get(opts, :custom_candidate_proposer),
      tracker: Keyword.get(opts, :tracker)
    }
  end

  defp build_stop_conditions(opts) do
    opts
    |> user_stop_conditions()
    |> maybe_append_run_dir_file_stopper(opts)
    |> maybe_append_timeout(opts)
    |> maybe_append_max_metric_calls(opts)
    |> maybe_append_score_threshold(opts)
    |> maybe_append_max_tracked_candidates(opts)
    |> maybe_append_max_reflection_cost(opts)
    |> maybe_append_max_candidate_proposals(opts)
    |> maybe_append_signal_stopper(opts)
    |> validate_stop_conditions!()
  end

  defp validate_seed_candidate!(seed_candidate)
       when is_map(seed_candidate) and map_size(seed_candidate) > 0 do
    seed_candidate
  end

  defp validate_seed_candidate!(_seed_candidate) do
    raise ArgumentError, "seed_candidate must contain at least one component text."
  end

  defp build_val_loader(opts, train_loader) do
    case Keyword.get(opts, :valset) do
      nil -> train_loader
      valset -> ensure_loader(valset)
    end
  end

  defp user_stop_conditions(opts) do
    opts
    |> Keyword.get(:stop_conditions, Keyword.get(opts, :stop_callbacks))
    |> List.wrap()
  end

  defp maybe_append_run_dir_file_stopper(stop_conditions, opts) do
    case Keyword.get(opts, :run_dir) do
      nil -> stop_conditions
      run_dir -> stop_conditions ++ [FileStopper.new(Path.join(run_dir, "gepa.stop"))]
    end
  end

  defp maybe_append_max_metric_calls(stop_conditions, opts) do
    case Keyword.get(opts, :max_metric_calls) do
      nil -> stop_conditions
      max_metric_calls -> stop_conditions ++ [MaxCalls.new(max_metric_calls)]
    end
  end

  defp maybe_append_timeout(stop_conditions, opts) do
    timeout_seconds = Keyword.get(opts, :timeout_seconds, Keyword.get(opts, :timeout))

    case timeout_seconds do
      nil -> stop_conditions
      seconds -> stop_conditions ++ [Timeout.new(seconds: seconds)]
    end
  end

  defp maybe_append_score_threshold(stop_conditions, opts) do
    case Keyword.get(opts, :score_threshold) do
      nil -> stop_conditions
      threshold -> stop_conditions ++ [ScoreThreshold.new(threshold)]
    end
  end

  defp maybe_append_max_tracked_candidates(stop_conditions, opts) do
    case Keyword.get(opts, :max_tracked_candidates) do
      nil -> stop_conditions
      max_tracked -> stop_conditions ++ [MaxTrackedCandidates.new(max_tracked)]
    end
  end

  defp maybe_append_max_reflection_cost(stop_conditions, opts) do
    case Keyword.get(opts, :max_reflection_cost) do
      nil ->
        stop_conditions

      max_reflection_cost ->
        reflection_lm = Keyword.get(opts, :reflection_llm) || Keyword.get(opts, :reflection_lm)
        stop_conditions ++ [MaxReflectionCost.new(max_reflection_cost, reflection_lm)]
    end
  end

  defp maybe_append_max_candidate_proposals(stop_conditions, opts) do
    case Keyword.get(opts, :max_candidate_proposals) do
      nil ->
        stop_conditions

      max_candidate_proposals ->
        stop_conditions ++ [MaxCandidateProposals.new(max_candidate_proposals)]
    end
  end

  defp maybe_append_signal_stopper(stop_conditions, opts) do
    if Keyword.get(opts, :signal_stopper, false) do
      stop_conditions ++ [SignalStopper.new()]
    else
      stop_conditions
    end
  end

  defp validate_stop_conditions!([]) do
    raise ArgumentError,
          "must provide at least one stop condition via :stop_conditions, :stop_callbacks, :max_metric_calls, :max_reflection_cost, :max_candidate_proposals, or :run_dir"
  end

  defp validate_stop_conditions!(stop_conditions), do: stop_conditions

  defp build_candidate_selector(opts) do
    opts
    |> Keyword.get(:candidate_selection_strategy, Keyword.get(opts, :candidate_selector, :pareto))
    |> normalize_candidate_selector()
  end

  defp normalize_candidate_selector(selector) when selector in [:pareto, "pareto", Pareto],
    do: Pareto

  defp normalize_candidate_selector(selector)
       when selector in [:current_best, "current_best", CurrentBest],
       do: CurrentBest

  defp normalize_candidate_selector(selector)
       when selector in [:epsilon_greedy, "epsilon_greedy"] do
    EpsilonGreedy.new()
  end

  defp normalize_candidate_selector(selector) when selector in [:top_k_pareto, "top_k_pareto"] do
    TopKPareto.new(k: 5)
  end

  defp normalize_candidate_selector(selector), do: selector

  defp build_batch_sampler(opts, reflection_minibatch_size) do
    case Keyword.get(opts, :batch_sampler, :epoch_shuffled) do
      sampler when sampler in [:epoch_shuffled, "epoch_shuffled"] ->
        EpochShuffled.new(
          minibatch_size: reflection_minibatch_size || 3,
          seed: Keyword.get(opts, :seed, 0)
        )

      sampler ->
        if Keyword.has_key?(opts, :reflection_minibatch_size) do
          raise ArgumentError,
                "reflection_minibatch_size only accepted when batch_sampler is :epoch_shuffled"
        end

        sampler
    end
  end

  defp build_module_selector(opts) do
    case Keyword.get(opts, :module_selector, :round_robin) do
      selector when selector in [:round_robin, "round_robin", RoundRobin] -> RoundRobin
      selector when selector in [:all, "all", All] -> All
      selector -> selector
    end
  end

  defp build_val_evaluation_policy(opts) do
    case Keyword.get(opts, :val_evaluation_policy, :full_eval) do
      policy when policy in [nil, :full_eval, "full_eval", Full] -> Full
      policy -> policy
    end
  end

  defp build_acceptance_criterion(opts) do
    opts
    |> Keyword.get(:acceptance_criterion, :strict_improvement)
    |> Acceptance.normalize()
  end

  defp build_evaluation_cache(opts) do
    cond do
      opts[:evaluation_cache] -> opts[:evaluation_cache]
      Keyword.get(opts, :cache_evaluation, false) -> EvaluationCache.new()
      true -> nil
    end
  end

  defp build_merge_proposer(opts, adapter, val_loader) do
    if Keyword.get(opts, :use_merge, false) do
      Merge.new(
        valset: val_loader,
        evaluator: fn batch, candidate ->
          case Dispatch.evaluate(adapter, batch, candidate, false) do
            {:ok, eval_batch} ->
              {eval_batch.outputs, eval_batch.scores, eval_batch.objective_scores}

            {:error, reason} ->
              raise "merge evaluation failed: #{inspect(reason)}"
          end
        end,
        use_merge: true,
        max_merge_invocations: Keyword.get(opts, :max_merge_invocations, 5),
        val_overlap_floor: Keyword.get(opts, :merge_val_overlap_floor, 5),
        seed: Keyword.get(opts, :seed, 0)
      )
    end
  end

  defp validate_adapter_configuration!(opts, adapter) do
    user_adapter? = Keyword.has_key?(opts, :adapter) and not is_nil(Keyword.get(opts, :adapter))
    task_lm = Keyword.get(opts, :task_lm, Keyword.get(opts, :model))
    evaluator = Keyword.get(opts, :evaluator)

    if user_adapter? and not is_nil(task_lm) do
      raise ArgumentError,
            "Since an adapter is provided, GEPA does not require :task_lm or :model. Set those options to nil."
    end

    if user_adapter? and not is_nil(evaluator) do
      raise ArgumentError,
            "Since an adapter is provided, GEPA does not require :evaluator. Set :evaluator to nil."
    end

    adapter_has_propose? = Dispatch.has_propose_new_texts?(adapter)
    custom_proposer? = not is_nil(Keyword.get(opts, :custom_candidate_proposer))

    reflection_lm? =
      not is_nil(Keyword.get(opts, :reflection_llm, Keyword.get(opts, :reflection_lm)))

    template_present? =
      Keyword.has_key?(opts, :proposal_template) or
        Keyword.has_key?(opts, :reflection_prompt_template)

    cond do
      adapter_has_propose? and custom_proposer? ->
        raise ArgumentError,
              "Cannot provide both adapter.propose_new_texts and :custom_candidate_proposer. Please use only one custom proposal method."

      adapter_has_propose? and template_present? ->
        raise ArgumentError,
              "adapter.propose_new_texts is present, so :proposal_template/:reflection_prompt_template would be ignored. Set the template option to nil."

      not adapter_has_propose? and not custom_proposer? and not reflection_lm? ->
        raise ArgumentError,
              "reflection_llm was not provided, adapter does not provide propose_new_texts, and custom_candidate_proposer was not provided."

      true ->
        :ok
    end
  end

  defp fetch_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> raise ArgumentError, "must provide #{inspect(key)}"
    end
  end

  defp build_adapter(opts) do
    case Keyword.get(opts, :adapter) do
      nil -> build_default_adapter(opts)
      adapter -> adapter
    end
  end

  defp build_default_adapter(opts) do
    task_lm = opts[:task_lm] || opts[:model]

    if task_lm do
      Default.new(
        model: task_lm,
        evaluator: opts[:evaluator],
        failure_score: opts[:failure_score] || 0.0
      )
    else
      raise ArgumentError, "must provide :adapter"
    end
  end

  defp build_instruction_proposal(opts) do
    case Keyword.get(opts, :reflection_llm, Keyword.get(opts, :reflection_lm)) do
      nil ->
        nil

      llm ->
        proposal_opts = [llm: llm]

        template =
          Keyword.get(opts, :proposal_template, Keyword.get(opts, :reflection_prompt_template))

        proposal_opts =
          if template do
            Keyword.put(proposal_opts, :template, template)
          else
            proposal_opts
          end

        proposal_opts =
          if Keyword.has_key?(opts, :structured_output) do
            Keyword.put(proposal_opts, :structured_output, opts[:structured_output])
          else
            proposal_opts
          end

        InstructionProposal.new(proposal_opts)
    end
  end

  defp ensure_loader(data), do: GEPA.DataLoader.ensure(data)
end
