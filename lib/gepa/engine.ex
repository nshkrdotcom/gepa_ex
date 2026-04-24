defmodule GEPA.Engine do
  # The engine loop intentionally coordinates proposal, evaluation, telemetry,
  # and persistence in one place. Keep this exception scoped to this module.
  # credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  @moduledoc """
  Main optimization engine for GEPA.

  Orchestrates the optimization loop: propose → evaluate → accept/reject → repeat.
  """

  require Logger

  alias GEPA.{
    Callbacks,
    CandidateProposal,
    DataLoader,
    EvaluationBatch,
    EvaluationCache,
    State,
    Telemetry
  }

  alias GEPA.Proposer.{Merge, Reflective}

  @doc """
  Run optimization until stop condition met.

  ## Parameters

  - `config`: Configuration map with all necessary settings

  ## Returns

  `{:ok, final_state}` on success
  """
  @spec run(map()) :: {:ok, State.t()}
  def run(config) do
    run_start_ms = System.monotonic_time(:millisecond)
    Telemetry.emit_run_start(config)

    # Start progress display if enabled
    progress = maybe_start_progress(config)

    # Initialize or load state
    state = initialize_state(config)

    Callbacks.notify(config[:callbacks], :optimization_start, %{
      seed_candidate: config.seed_candidate,
      trainset_size: length(DataLoader.all_ids(config.trainset)),
      valset_size: length(DataLoader.all_ids(config.valset)),
      config: config
    })

    # Run optimization loop
    final_state =
      state
      |> optimization_loop(config, progress)
      |> sync_adapter_state_to_state(config.adapter)

    # Save final state if run_dir configured
    if config[:run_dir] do
      save_state(final_state, config.run_dir)
    end

    Telemetry.emit_run_stop(final_state, run_start_ms)

    # Finish progress display
    maybe_finish_progress(progress, final_state)

    Callbacks.notify(config[:callbacks], :optimization_end, %{
      best_candidate_idx: best_program_idx(final_state),
      total_iterations: final_state.i,
      total_metric_calls: final_state.total_num_evals,
      final_state: final_state
    })

    {:ok, final_state}
  end

  @doc """
  Run a single optimization iteration.

  Returns `{:cont, new_state}` to continue or `{:stop, state}` to stop.
  """
  @spec run_iteration(State.t(), map()) ::
          {:cont, State.t(), map(), boolean(), term()} | {:stop, State.t()}
  def run_iteration(state, config) do
    # Check stop conditions
    if should_stop?(state, config.stop_conditions) do
      Logger.info("Stop condition met at iteration #{state.i}")
      {:stop, state}
    else
      prev_best = best_score(state)
      iter_start_ms = System.monotonic_time(:millisecond)

      # Increment iteration
      state = %{state | i: state.i + 1}
      iteration = state.i
      Logger.debug("Starting iteration #{iteration}")

      Callbacks.notify(config[:callbacks], :iteration_start, %{
        iteration: iteration,
        state: state,
        trainset: config.trainset
      })

      # Try merge proposer first (if configured and conditions met)
      {proposal, state, config} =
        case Map.fetch(config, :merge_proposer) do
          {:ok, nil} ->
            {reflective, new_state, new_config} = try_reflective_proposal(state, config)
            {reflective, new_state, new_config}

          {:ok, merge_proposer} ->
            {merge_proposal, updated_proposer} =
              Merge.propose(merge_proposer, state)

            merge_config = %{config | merge_proposer: updated_proposer}

            if merge_proposal do
              {merge_proposal, state, merge_config}
            else
              {reflective, new_state, new_config} = try_reflective_proposal(state, merge_config)
              {reflective, new_state, new_config}
            end

          :error ->
            {reflective, new_state, new_config} = try_reflective_proposal(state, config)
            {reflective, new_state, new_config}
        end

      selected_candidate = proposal && List.first(proposal.parent_program_ids)
      Telemetry.emit_iteration_start(iteration, selected_candidate)

      proposal_tag = proposal && proposal.tag
      subsample_before_sum = (proposal && Enum.sum(proposal.subsample_scores_before || [])) || 0.0
      subsample_after_sum = (proposal && Enum.sum(proposal.subsample_scores_after || [])) || 0.0
      subsample_ids = proposal && proposal.subsample_indices

      {result_tag, new_state, new_config, accepted?} =
        case proposal do
          %CandidateProposal{} ->
            Logger.debug("Proposal generated for iteration #{state.i} (#{proposal.tag})")
            Telemetry.emit_proposal_generated(proposal, iteration)

            # Update eval counter
            num_subsample_evals =
              length(proposal.subsample_scores_before) + length(proposal.subsample_scores_after)

            state = %{state | total_num_evals: state.total_num_evals + num_subsample_evals}

            if CandidateProposal.should_accept?(
                 proposal,
                 Map.get(config, :acceptance_criterion, :strict_improvement),
                 state
               ) do
              Logger.info("Accepting #{proposal.tag} proposal at iteration #{state.i}")
              new_state = accept_proposal(state, proposal, config, iteration)
              new_candidate_idx = length(new_state.program_candidates) - 1

              Callbacks.notify(config[:callbacks], :candidate_accepted, %{
                iteration: iteration,
                new_candidate_idx: new_candidate_idx,
                parent_ids: proposal.parent_program_ids,
                candidate: proposal.candidate,
                new_score: elem(State.get_program_score(new_state, new_candidate_idx), 0)
              })

              Telemetry.emit_proposal_decision(
                proposal,
                iteration,
                true,
                :accepted,
                subsample_after_sum - subsample_before_sum,
                proposal.parent_program_ids
              )

              new_config =
                case Map.fetch(config, :merge_proposer) do
                  {:ok, nil} ->
                    config

                  {:ok, merge_proposer} ->
                    updated_merge = %{merge_proposer | last_iter_found_new_program: true}
                    updated_merge = Merge.schedule_if_needed(updated_merge)
                    %{config | merge_proposer: updated_merge}

                  :error ->
                    config
                end

              {:cont, new_state, new_config, true}
            else
              Logger.debug("Rejecting proposal at iteration #{state.i}")

              Callbacks.notify(config[:callbacks], :candidate_rejected, %{
                iteration: iteration,
                old_score: subsample_before_sum,
                new_score: subsample_after_sum,
                reason: :not_improved
              })

              Telemetry.emit_proposal_decision(
                proposal,
                iteration,
                false,
                :not_improved,
                subsample_after_sum - subsample_before_sum,
                proposal.parent_program_ids
              )

              {:cont, state, config, false}
            end

          nil ->
            Logger.debug("No proposal generated at iteration #{state.i}")
            state = %{state | total_num_evals: state.total_num_evals + 1}

            Callbacks.notify(config[:callbacks], :candidate_rejected, %{
              iteration: iteration,
              old_score: subsample_before_sum,
              new_score: subsample_after_sum,
              reason: :schedule_skip
            })

            Telemetry.emit_proposal_decision(
              nil,
              iteration,
              false,
              :schedule_skip,
              0.0,
              nil
            )

            {:cont, state, config, false}
        end

      iter_duration_ms = System.monotonic_time(:millisecond) - iter_start_ms

      Telemetry.emit_iteration_stop(
        new_state,
        iteration,
        prev_best,
        accepted?,
        subsample_before_sum,
        subsample_after_sum,
        proposal_tag,
        proposal && proposal.parent_program_ids,
        subsample_ids,
        iter_duration_ms
      )

      Callbacks.notify(config[:callbacks], :iteration_end, %{
        iteration: iteration,
        state: new_state,
        proposal_accepted: accepted?
      })

      {result_tag, new_state, new_config, accepted?, proposal_tag}
    end
  end

  defp try_reflective_proposal(state, config) do
    # Use configured reflective proposer or create one
    proposer = config[:reflective_proposer] || create_proposer(config)

    case Reflective.propose(proposer, state) do
      {:ok, proposal, selector} ->
        new_config = put_candidate_selector(config, selector)
        {proposal, state, new_config}

      {:none, selector} ->
        new_config = put_candidate_selector(config, selector)
        {nil, state, new_config}

      {:error, reason, selector} ->
        Logger.warning("Reflective proposal failed: #{inspect(reason)}")
        new_config = put_candidate_selector(config, selector)
        {nil, state, new_config}
    end
  end

  # Private functions

  defp initialize_state(config) do
    # Try to load existing state if run_dir provided
    state =
      if config[:run_dir] do
        case load_state(config.run_dir) do
          {:ok, state} ->
            Logger.info("Loaded existing state from #{config.run_dir}")
            state

          {:error, _} ->
            create_initial_state(config)
        end
      else
        create_initial_state(config)
      end

    restore_adapter_state(config.adapter, state.adapter_state)
    state
  end

  defp create_initial_state(config) do
    # Evaluate seed candidate on validation set
    valset_ids = DataLoader.all_ids(config.valset)
    adapter = config.adapter

    eval_start = System.monotonic_time(:millisecond)

    {:ok, eval_batch, evaluation_cache} =
      evaluate_validation(
        adapter,
        config.valset,
        valset_ids,
        config.seed_candidate,
        false,
        config[:evaluation_cache]
      )

    duration_ms = System.monotonic_time(:millisecond) - eval_start

    Telemetry.emit_evaluation_batch(
      0,
      :val,
      length(valset_ids),
      duration_ms,
      eval_batch.scores,
      0,
      "seed"
    )

    Telemetry.emit_baseline(eval_batch, length(valset_ids))

    State.new(config.seed_candidate, eval_batch, valset_ids,
      track_best_outputs: config[:track_best_outputs] || false,
      frontier_type: config[:frontier_type] || :instance,
      evaluation_cache: evaluation_cache,
      adapter_state: adapter_state_from_adapter(adapter)
    )
  end

  defp optimization_loop(state, config, progress, max_iters \\ 1000) do
    # Safety guard against infinite loops
    if state.i >= max_iters do
      Logger.warning("Reached max iterations (#{max_iters}), stopping")
      state
    else
      case run_iteration(state, config) do
        {:cont, new_state, new_config, accepted?, proposal_type} ->
          # Update progress display
          progress = maybe_update_progress(progress, new_state, accepted?, proposal_type)

          # Save state periodically
          if config[:run_dir] && rem(new_state.i, 5) == 0 do
            new_state
            |> sync_adapter_state_to_state(config.adapter)
            |> save_state(config.run_dir)
          end

          optimization_loop(new_state, new_config, progress, max_iters)

        {:stop, final_state} ->
          Logger.info("Optimization stopped at iteration #{final_state.i}")
          final_state
      end
    end
  end

  defp should_stop?(state, stop_conditions) do
    Enum.any?(stop_conditions, fn condition ->
      condition.__struct__.should_stop?(condition, state)
    end)
  end

  defp accept_proposal(state, proposal, config, iteration) do
    # Evaluate on full validation set
    valset_ids = DataLoader.all_ids(config.valset)
    adapter = config.adapter

    eval_start = System.monotonic_time(:millisecond)

    case evaluate_validation(
           adapter,
           config.valset,
           valset_ids,
           proposal.candidate,
           false,
           state.evaluation_cache
         ) do
      {:ok, eval_batch, evaluation_cache} ->
        duration_ms = System.monotonic_time(:millisecond) - eval_start
        state = %{state | evaluation_cache: evaluation_cache}

        # Create scores map
        val_scores =
          valset_ids
          |> Enum.zip(eval_batch.scores)
          |> Enum.into(%{})

        outputs_by_val_id =
          valset_ids
          |> Enum.zip(eval_batch.outputs)
          |> Enum.into(%{})

        objective_scores_by_val_id =
          if eval_batch.objective_scores do
            valset_ids
            |> Enum.zip(eval_batch.objective_scores)
            |> Enum.into(%{})
          end

        # Add to state
        {new_state, new_idx} =
          State.add_program(
            state,
            proposal.candidate,
            proposal.parent_program_ids,
            val_scores,
            outputs_by_val_id: outputs_by_val_id,
            objective_scores_by_val_id: objective_scores_by_val_id,
            metric_calls: eval_batch.num_metric_calls || map_size(val_scores)
          )

        Telemetry.emit_evaluation_batch(
          iteration,
          :val,
          length(valset_ids),
          duration_ms,
          eval_batch.scores,
          new_idx,
          proposal.tag
        )

        Telemetry.emit_valset_update(new_state, iteration, new_idx, val_scores)

        Logger.info(
          "Accepted new program #{new_idx} with avg score #{elem(State.get_program_score(new_state, new_idx), 0)}"
        )

        new_state

      {:error, reason} ->
        Logger.error("Failed to evaluate proposal: #{inspect(reason)}")
        state
    end
  end

  defp evaluate_validation(adapter, loader, ids, candidate, capture_traces, nil) do
    batch = DataLoader.fetch(loader, ids)

    with {:ok, eval_batch} <-
           adapter.__struct__.evaluate(adapter, batch, candidate, capture_traces) do
      {:ok, eval_batch, nil}
    end
  end

  defp evaluate_validation(
         adapter,
         loader,
         ids,
         candidate,
         capture_traces,
         %EvaluationCache{} = cache
       ) do
    {cached, uncached_ids} = EvaluationCache.get_batch(cache, candidate, ids)

    if uncached_ids == [] do
      {:ok, eval_batch_from_cached(ids, cached, 0), cache}
    else
      batch = DataLoader.fetch(loader, uncached_ids)

      with {:ok, uncached_eval_batch} <-
             adapter.__struct__.evaluate(adapter, batch, candidate, capture_traces) do
        cache =
          EvaluationCache.put_batch(
            cache,
            candidate,
            uncached_ids,
            uncached_eval_batch.outputs,
            uncached_eval_batch.scores,
            uncached_eval_batch.objective_scores
          )

        {cached, _uncached_ids} = EvaluationCache.get_batch(cache, candidate, ids)
        metric_calls = uncached_eval_batch.num_metric_calls || length(uncached_ids)

        {:ok, eval_batch_from_cached(ids, cached, metric_calls), cache}
      end
    end
  end

  defp eval_batch_from_cached(ids, cached, metric_calls) do
    entries = Enum.map(ids, &Map.fetch!(cached, &1))
    objective_scores = Enum.map(entries, & &1.objective_scores)

    %EvaluationBatch{
      outputs: Enum.map(entries, & &1.output),
      scores: Enum.map(entries, & &1.score),
      objective_scores: if(Enum.any?(objective_scores, & &1), do: objective_scores),
      num_metric_calls: metric_calls
    }
  end

  defp candidate_selector_from_config(config) do
    Map.get(config, :candidate_selector, GEPA.Strategies.CandidateSelector.Pareto)
  end

  defp put_candidate_selector(config, selector) do
    Map.put(config, :candidate_selector, selector || candidate_selector_from_config(config))
  end

  defp create_proposer(config) do
    Reflective.new(
      adapter: config.adapter,
      trainset: config.trainset,
      candidate_selector: candidate_selector_from_config(config),
      perfect_score: config[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(config |> Map.to_list(), :skip_perfect_score, true),
      minibatch_size: config[:reflection_minibatch_size] || 3,
      instruction_proposal: config[:instruction_proposal]
    )
  end

  defp adapter_state_from_adapter(adapter) do
    module = adapter_module(adapter)

    adapter_state_from_callback(module, adapter)
  end

  defp adapter_state_from_callback(module, adapter) when is_atom(module) do
    case module.get_adapter_state(adapter) do
      {:ok, state} when is_map(state) -> state
      state when is_map(state) -> state
      _ -> %{}
    end
  rescue
    UndefinedFunctionError -> %{}
  end

  defp restore_adapter_state(adapter, state) do
    module = adapter_module(adapter)

    case {state, module} do
      {state, module}
      when is_map(state) and map_size(state) > 0 and is_atom(module) ->
        restore_adapter_state_from_callback(module, adapter, state)

      _ ->
        :ok
    end

    :ok
  end

  defp restore_adapter_state_from_callback(module, adapter, state) do
    module.set_adapter_state(adapter, state)
  rescue
    UndefinedFunctionError -> :ok
  end

  defp sync_adapter_state_to_state(state, adapter) do
    %{state | adapter_state: adapter_state_from_adapter(adapter)}
  end

  defp adapter_module(%module{}), do: module
  defp adapter_module(module) when is_atom(module), do: module
  defp adapter_module(_adapter), do: nil

  defp save_state(state, run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")
    File.mkdir_p!(run_dir)

    data = :erlang.term_to_binary(state, [:compressed])
    File.write!(path, data)
    write_json_atomic(Path.join(run_dir, "candidates.json"), state.program_candidates)

    if state.full_program_trace != [] do
      write_json_atomic(Path.join(run_dir, "run_log.json"), state.full_program_trace)
    end
  end

  defp write_json_atomic(path, data) do
    tmp_path = path <> ".tmp"
    File.write!(tmp_path, Jason.encode!(data, pretty: true))
    File.rename!(tmp_path, path)
  end

  defp load_state(run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")

    with {:ok, data} <- File.read(path),
         state <- :erlang.binary_to_term(data) do
      {:ok, state}
    end
  end

  defp best_score(state) do
    state.prog_candidate_val_subscores
    |> Enum.map(fn scores ->
      if map_size(scores) == 0 do
        0.0
      else
        Enum.sum(Map.values(scores)) / map_size(scores)
      end
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp best_program_idx(state) do
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.max_by(fn {scores, _idx} ->
      if map_size(scores) == 0 do
        0.0
      else
        Enum.sum(Map.values(scores)) / map_size(scores)
      end
    end)
    |> elem(1)
  end

  # Progress tracking helpers

  defp maybe_start_progress(%{progress: false}), do: nil
  defp maybe_start_progress(%{progress: nil}), do: nil

  defp maybe_start_progress(%{progress: true} = config) do
    max_calls = extract_max_calls(config[:stop_conditions] || [])
    progress = GEPA.Progress.new(max_calls: max_calls)
    GEPA.Progress.start(progress)
    progress
  end

  defp maybe_start_progress(%{progress: opts} = config) when is_list(opts) do
    max_calls = extract_max_calls(config[:stop_conditions] || [])
    progress = GEPA.Progress.new([{:max_calls, max_calls} | opts])
    GEPA.Progress.start(progress)
    progress
  end

  defp maybe_start_progress(_config), do: nil

  defp maybe_update_progress(nil, _state, _accepted?, _proposal_type), do: nil

  defp maybe_update_progress(progress, state, accepted?, proposal_type) do
    GEPA.Progress.update(progress, %{
      iteration: state.i,
      best_score: best_score(state),
      pareto_size: map_size(state.program_at_pareto_front_valset),
      total_evals: state.total_num_evals,
      accepted: accepted?,
      proposal_type: proposal_type
    })
  end

  defp maybe_finish_progress(nil, _state), do: :ok

  defp maybe_finish_progress(progress, state) do
    result = GEPA.Result.from_state(state)
    GEPA.Progress.finish(progress, result)
  end

  defp extract_max_calls(stop_conditions) do
    Enum.find_value(stop_conditions, fn
      %GEPA.StopCondition.MaxCalls{max_calls: max} -> max
      _ -> nil
    end)
  end
end
