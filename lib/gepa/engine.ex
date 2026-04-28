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

  alias GEPA.Adapter.Dispatch

  alias GEPA.{
    Callbacks,
    CandidateProposal,
    DataLoader,
    EvaluationBatch,
    EvaluationCache,
    State,
    Telemetry,
    Tracking
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
    Tracking.start(config[:tracker])

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
      notify_state_saved(config, final_state)
    end

    Telemetry.emit_run_stop(final_state, run_start_ms)

    Tracking.log_summary(config[:tracker], %{
      total_iterations: final_state.i,
      total_metric_calls: final_state.total_num_evals,
      best_score: best_score(final_state)
    })

    # Finish progress display
    maybe_finish_progress(progress, final_state)

    Callbacks.notify(config[:callbacks], :optimization_end, %{
      best_candidate_idx: best_program_idx(final_state),
      total_iterations: final_state.i,
      total_metric_calls: final_state.total_num_evals,
      final_state: final_state
    })

    Tracking.finish(config[:tracker])

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

      # Increment internal iteration. Public callbacks/logs are one-based to
      # match upstream while state.i remains zero-based after the first loop.
      next_i = state.i + 1

      state = %{
        state
        | i: next_i,
          full_program_trace: state.full_program_trace ++ [%{i: next_i}]
      }

      iteration = state.i + 1
      Logger.debug("Starting iteration #{iteration}")

      Callbacks.notify(config[:callbacks], :iteration_start, %{
        iteration: iteration,
        state: state,
        trainset: config.trainset
      })

      Tracking.log_metrics(
        config[:tracker],
        %{iteration: iteration, total_metric_calls: state.total_num_evals},
        step: iteration
      )

      # Try merge proposer first (if configured and conditions met)
      {proposal, state, config, proposal_evals} =
        case Map.fetch(config, :merge_proposer) do
          {:ok, nil} ->
            {reflective, new_state, new_config, metric_calls} =
              try_reflective_proposal(state, config)

            {reflective, new_state, new_config, metric_calls}

          {:ok, merge_proposer} ->
            should_attempt_merge? =
              merge_proposer.use_merge and merge_proposer.merges_due > 0 and
                merge_proposer.last_iter_found_new_program

            {merge_proposal, updated_proposer} =
              Merge.propose(merge_proposer, state)

            notify_merge_attempt(config, iteration, should_attempt_merge?, merge_proposal)

            updated_proposer =
              if should_attempt_merge? do
                %{updated_proposer | last_iter_found_new_program: false}
              else
                updated_proposer
              end

            merge_config = %{config | merge_proposer: updated_proposer}

            if merge_proposal do
              {merge_proposal, state, merge_config, nil}
            else
              {reflective, new_state, new_config, metric_calls} =
                try_reflective_proposal(state, merge_config)

              {reflective, new_state, new_config, metric_calls}
            end

          :error ->
            {reflective, new_state, new_config, metric_calls} =
              try_reflective_proposal(state, config)

            {reflective, new_state, new_config, metric_calls}
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
            Logger.debug("Proposal generated for iteration #{iteration} (#{proposal.tag})")
            Telemetry.emit_proposal_generated(proposal, iteration)

            # Update eval counter
            num_subsample_evals = proposal_evals || proposal_metric_calls(proposal)

            state = %{state | total_num_evals: state.total_num_evals + num_subsample_evals}

            if CandidateProposal.should_accept?(
                 proposal,
                 Map.get(config, :acceptance_criterion, :strict_improvement),
                 state
               ) do
              Logger.info("Accepting #{proposal.tag} proposal at iteration #{iteration}")
              new_state = accept_proposal(state, proposal, config, iteration)
              new_candidate_idx = length(new_state.program_candidates) - 1

              Callbacks.notify(config[:callbacks], :candidate_accepted, %{
                iteration: iteration,
                new_candidate_idx: new_candidate_idx,
                parent_ids: proposal.parent_program_ids,
                candidate: proposal.candidate,
                new_score: elem(State.get_program_score(new_state, new_candidate_idx), 0)
              })

              notify_merge_decision(config, iteration, proposal, new_candidate_idx, :accepted)

              Telemetry.emit_proposal_decision(
                proposal,
                iteration,
                true,
                :accepted,
                subsample_after_sum - subsample_before_sum,
                proposal.parent_program_ids
              )

              Tracking.log_metrics(
                config[:tracker],
                %{
                  proposal_accepted: 1,
                  subsample_delta: subsample_after_sum - subsample_before_sum,
                  total_metric_calls: new_state.total_num_evals
                },
                step: iteration
              )

              new_config = update_merge_proposer_after_accept(config, proposal.tag)

              {:cont, new_state, new_config, true}
            else
              Logger.debug("Rejecting proposal at iteration #{iteration}")

              Callbacks.notify(config[:callbacks], :candidate_rejected, %{
                iteration: iteration,
                old_score: subsample_before_sum,
                new_score: subsample_after_sum,
                reason: :not_improved
              })

              notify_merge_decision(config, iteration, proposal, nil, :rejected)

              Telemetry.emit_proposal_decision(
                proposal,
                iteration,
                false,
                :not_improved,
                subsample_after_sum - subsample_before_sum,
                proposal.parent_program_ids
              )

              Tracking.log_metrics(
                config[:tracker],
                %{
                  proposal_accepted: 0,
                  subsample_delta: subsample_after_sum - subsample_before_sum,
                  total_metric_calls: state.total_num_evals
                },
                step: iteration
              )

              {:cont, state, config, false}
            end

          nil ->
            Logger.debug("No proposal generated at iteration #{iteration}")
            state = add_metric_calls(state, proposal_evals || 0)

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

      new_config = update_stop_conditions(new_config, new_state)
      notify_budget_updated(config, iteration, state, new_state, new_config)

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

    try do
      case Reflective.propose(proposer, state) do
        {:ok, proposal, updated_proposer, updated_state} ->
          new_config = put_reflective_proposer(config, updated_proposer)
          {proposal, updated_state, new_config, nil}

        {:none, updated_proposer, updated_state, metadata} ->
          new_config = put_reflective_proposer(config, updated_proposer)
          {nil, updated_state, new_config, Map.get(metadata, :num_metric_calls, 0)}

        {:error, reason, updated_proposer, updated_state} ->
          handle_reflective_error(reason, updated_proposer, updated_state, config)
      end
    rescue
      exception ->
        if Map.get(config, :raise_on_exception, true) do
          notify_error(config, state.i + 1, exception, false)
          reraise exception, __STACKTRACE__
        else
          Logger.warning("Reflective proposal raised: #{Exception.message(exception)}")
          notify_error(config, state.i + 1, exception, true)
          {nil, state, config, 0}
        end
    end
  end

  defp handle_reflective_error(reason, proposer, state, config) do
    if Map.get(config, :raise_on_exception, true) do
      notify_error(config, state.i + 1, reason, false)
      raise "Reflective proposal failed: #{inspect(reason)}"
    else
      Logger.warning("Reflective proposal failed: #{inspect(reason)}")
      notify_error(config, state.i + 1, reason, true)
      new_config = put_reflective_proposer(config, proposer)
      {nil, state, new_config, 0}
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
            |> validate_loaded_state!(config)
            |> sync_loaded_cache_setting(config)

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
    validation_batch = DataLoader.fetch(config.valset, valset_ids)

    Callbacks.notify(config[:callbacks], :evaluation_start, %{
      iteration: 0,
      candidate_idx: 0,
      batch_size: length(valset_ids),
      capture_traces: false,
      parent_ids: [],
      inputs: validation_batch,
      is_seed_candidate: true
    })

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

    Callbacks.notify(config[:callbacks], :evaluation_end, %{
      iteration: 0,
      candidate_idx: 0,
      scores: eval_batch.scores,
      has_trajectories: has_trajectories?(eval_batch),
      parent_ids: [],
      outputs: eval_batch.outputs,
      trajectories: eval_batch.trajectories,
      objective_scores: eval_batch.objective_scores,
      is_seed_candidate: true
    })

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

    state =
      State.new(config.seed_candidate, eval_batch, valset_ids,
        track_best_outputs: config[:track_best_outputs] || false,
        frontier_type: config[:frontier_type] || :instance,
        evaluation_cache: evaluation_cache,
        adapter_state: adapter_state_from_adapter(adapter)
      )

    notify_valset_evaluated(
      config,
      0,
      0,
      config.seed_candidate,
      valset_ids,
      eval_batch,
      [],
      state
    )

    state
  end

  defp optimization_loop(state, config, progress) do
    max_iters = Map.get(config, :max_iterations, 1000)

    # Safety guard against infinite loops
    if state.i + 1 >= max_iters do
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

            notify_state_saved(config, new_state)
          end

          optimization_loop(new_state, new_config, progress)

        {:stop, final_state} ->
          Logger.info("Optimization stopped at iteration #{final_state.i}")
          final_state
      end
    end
  end

  defp should_stop?(state, stop_conditions) do
    Enum.any?(stop_conditions, &GEPA.StopCondition.should_stop?(&1, state))
  end

  defp update_stop_conditions(config, state) do
    Map.update(config, :stop_conditions, [], fn stop_conditions ->
      Enum.map(stop_conditions, &GEPA.StopCondition.update(&1, state))
    end)
  end

  defp update_merge_proposer_after_accept(config, "merge") do
    case Map.fetch(config, :merge_proposer) do
      {:ok, %Merge{} = merge_proposer} ->
        updated_merge = %{
          merge_proposer
          | merges_due: max(merge_proposer.merges_due - 1, 0),
            total_merges_tested: merge_proposer.total_merges_tested + 1,
            last_iter_found_new_program: false
        }

        %{config | merge_proposer: updated_merge}

      _ ->
        config
    end
  end

  defp update_merge_proposer_after_accept(config, _proposal_tag) do
    case Map.fetch(config, :merge_proposer) do
      {:ok, %Merge{} = merge_proposer} ->
        updated_merge = %{merge_proposer | last_iter_found_new_program: true}
        updated_merge = Merge.schedule_if_needed(updated_merge)
        %{config | merge_proposer: updated_merge}

      _ ->
        config
    end
  end

  defp proposal_metric_calls(%CandidateProposal{metadata: metadata} = proposal) do
    Map.get(metadata, :num_metric_calls) ||
      Map.get(metadata, "num_metric_calls") ||
      length(proposal.subsample_scores_before) + length(proposal.subsample_scores_after)
  end

  defp add_metric_calls(state, 0), do: state

  defp add_metric_calls(state, calls) when is_integer(calls) and calls > 0 do
    %{state | total_num_evals: state.total_num_evals + calls}
  end

  defp validate_loaded_state!(state, config) do
    requested_frontier_type = Map.get(config, :frontier_type, :instance)
    loaded_frontier_type = Map.get(state, :frontier_type, :instance)

    if loaded_frontier_type != requested_frontier_type do
      raise ArgumentError,
            "Frontier type mismatch: requested #{inspect(requested_frontier_type)} but loaded state has #{inspect(loaded_frontier_type)}"
    end

    state
  end

  defp sync_loaded_cache_setting(state, config) do
    case Map.get(config, :evaluation_cache) do
      nil ->
        %{state | evaluation_cache: nil}

      evaluation_cache ->
        if state.evaluation_cache do
          state
        else
          %{state | evaluation_cache: evaluation_cache}
        end
    end
  end

  defp accept_proposal(state, proposal, config, iteration) do
    # Evaluate on the validation IDs selected by the configured policy.
    valset_ids = validation_eval_ids(config, state, length(state.program_candidates))
    adapter = config.adapter
    validation_batch = DataLoader.fetch(config.valset, valset_ids)

    Callbacks.notify(config[:callbacks], :evaluation_start, %{
      iteration: iteration,
      candidate_idx: nil,
      batch_size: length(valset_ids),
      capture_traces: false,
      parent_ids: proposal.parent_program_ids,
      inputs: validation_batch,
      is_seed_candidate: false
    })

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

        Callbacks.notify(config[:callbacks], :evaluation_end, %{
          iteration: iteration,
          candidate_idx: nil,
          scores: eval_batch.scores,
          has_trajectories: has_trajectories?(eval_batch),
          parent_ids: proposal.parent_program_ids,
          outputs: eval_batch.outputs,
          trajectories: eval_batch.trajectories,
          objective_scores: eval_batch.objective_scores,
          is_seed_candidate: false
        })

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

        notify_valset_evaluated(
          config,
          iteration,
          new_idx,
          proposal.candidate,
          valset_ids,
          eval_batch,
          proposal.parent_program_ids,
          new_state
        )

        notify_pareto_front_updated(config, iteration, state, new_state)

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
        notify_error(config, iteration, reason, false)
        state
    end
  end

  defp evaluate_validation(adapter, loader, ids, candidate, capture_traces, nil) do
    batch = DataLoader.fetch(loader, ids)

    with {:ok, eval_batch} <-
           Dispatch.evaluate(adapter, batch, candidate, capture_traces) do
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
             Dispatch.evaluate(adapter, batch, candidate, capture_traces) do
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

  defp validation_eval_ids(config, state, target_program_idx) do
    policy = Map.get(config, :val_evaluation_policy, GEPA.Strategies.EvaluationPolicy.Full)

    cond do
      is_atom(policy) and function_exported?(policy, :get_eval_batch, 3) ->
        policy.get_eval_batch(config.valset, state, target_program_idx)

      is_map(policy) and function_exported?(policy.__struct__, :get_eval_batch, 4) ->
        policy.__struct__.get_eval_batch(policy, config.valset, state, target_program_idx)

      is_map(policy) and function_exported?(policy.__struct__, :get_eval_batch, 3) ->
        policy.__struct__.get_eval_batch(config.valset, state, target_program_idx)

      true ->
        DataLoader.all_ids(config.valset)
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

  defp put_reflective_proposer(config, %Reflective{} = proposer) do
    config
    |> Map.put(:reflective_proposer, proposer)
    |> Map.put(
      :candidate_selector,
      proposer.candidate_selector || candidate_selector_from_config(config)
    )
  end

  defp create_proposer(config) do
    Reflective.new(
      adapter: config.adapter,
      trainset: config.trainset,
      candidate_selector: candidate_selector_from_config(config),
      perfect_score: config[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(config |> Map.to_list(), :skip_perfect_score, true),
      minibatch_size: config[:reflection_minibatch_size] || 3,
      instruction_proposal: config[:instruction_proposal],
      batch_sampler: config[:batch_sampler],
      module_selector: config[:module_selector],
      custom_candidate_proposer: config[:custom_candidate_proposer],
      callbacks: config[:callbacks],
      seed: config[:seed] || 0
    )
  end

  defp adapter_state_from_adapter(adapter), do: Dispatch.get_adapter_state(adapter)

  defp restore_adapter_state(adapter, state) do
    if is_map(state) and map_size(state) > 0 do
      Dispatch.set_adapter_state(adapter, state)
    end

    :ok
  end

  defp sync_adapter_state_to_state(state, adapter) do
    %{state | adapter_state: adapter_state_from_adapter(adapter)}
  end

  defp has_trajectories?(%EvaluationBatch{trajectories: trajectories}) do
    is_list(trajectories) and trajectories != []
  end

  defp notify_merge_attempt(_config, _iteration, false, _proposal), do: :ok

  defp notify_merge_attempt(config, iteration, true, %CandidateProposal{} = proposal) do
    Callbacks.notify(config[:callbacks], :merge_attempted, %{
      iteration: iteration,
      parent_ids: proposal.parent_program_ids,
      merged_candidate: proposal.candidate
    })
  end

  defp notify_merge_attempt(config, iteration, true, _proposal) do
    Callbacks.notify(config[:callbacks], :merge_rejected, %{
      iteration: iteration,
      parent_ids: [],
      reason: :no_merge_candidate
    })
  end

  defp notify_merge_decision(
         config,
         iteration,
         %CandidateProposal{tag: "merge"} = proposal,
         idx,
         :accepted
       ) do
    Callbacks.notify(config[:callbacks], :merge_accepted, %{
      iteration: iteration,
      new_candidate_idx: idx,
      parent_ids: proposal.parent_program_ids
    })
  end

  defp notify_merge_decision(
         config,
         iteration,
         %CandidateProposal{tag: "merge"} = proposal,
         _idx,
         :rejected
       ) do
    Callbacks.notify(config[:callbacks], :merge_rejected, %{
      iteration: iteration,
      parent_ids: proposal.parent_program_ids,
      reason: :not_improved
    })
  end

  defp notify_merge_decision(_config, _iteration, _proposal, _idx, _decision), do: :ok

  defp notify_pareto_front_updated(config, iteration, old_state, new_state) do
    old_front = front_program_indices(old_state)
    new_front = front_program_indices(new_state)

    Callbacks.notify(config[:callbacks], :pareto_front_updated, %{
      iteration: iteration,
      new_front: new_front,
      displaced_candidates: old_front -- new_front
    })
  end

  defp front_program_indices(state) do
    state
    |> State.get_pareto_front_mapping()
    |> Map.values()
    |> Enum.flat_map(&MapSet.to_list/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp notify_state_saved(config, state) do
    Callbacks.notify(config[:callbacks], :state_saved, %{
      iteration: state.i + 1,
      run_dir: config.run_dir
    })
  end

  defp notify_budget_updated(config, iteration, old_state, new_state, new_config) do
    Callbacks.notify(config[:callbacks], :budget_updated, %{
      iteration: iteration,
      metric_calls_used: new_state.total_num_evals,
      metric_calls_delta: new_state.total_num_evals - old_state.total_num_evals,
      metric_calls_remaining: metric_calls_remaining(new_config, new_state)
    })
  end

  defp metric_calls_remaining(config, state) do
    config
    |> Map.get(:stop_conditions, [])
    |> List.wrap()
    |> Enum.find_value(fn
      %GEPA.StopCondition.MaxCalls{max_calls: max_calls} ->
        max(max_calls - state.total_num_evals, 0)

      _condition ->
        nil
    end)
  end

  defp notify_valset_evaluated(
         config,
         iteration,
         candidate_idx,
         candidate,
         valset_ids,
         %EvaluationBatch{} = eval_batch,
         parent_ids,
         state
       ) do
    scores_by_val_id = Enum.zip(valset_ids, eval_batch.scores) |> Map.new()
    outputs_by_val_id = Enum.zip(valset_ids, eval_batch.outputs) |> Map.new()
    average_score = average_score(eval_batch.scores)

    Callbacks.notify(config[:callbacks], :valset_evaluated, %{
      iteration: iteration,
      candidate_idx: candidate_idx,
      candidate: candidate,
      scores_by_val_id: scores_by_val_id,
      average_score: average_score,
      num_examples_evaluated: length(valset_ids),
      total_valset_size: length(DataLoader.all_ids(config.valset)),
      parent_ids: parent_ids,
      is_best_program: candidate_idx == best_program_idx(state),
      outputs_by_val_id: outputs_by_val_id
    })
  end

  defp notify_error(config, iteration, exception, will_continue) do
    Callbacks.notify(config[:callbacks], :error, %{
      iteration: iteration,
      exception: exception,
      will_continue: will_continue
    })
  end

  defp average_score([]), do: 0.0
  defp average_score(scores), do: Enum.sum(scores) / length(scores)

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
      %GEPA.StopCondition.Composite{conditions: nested} -> extract_max_calls(nested)
      _ -> nil
    end)
  end
end
