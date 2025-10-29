defmodule GEPA.Engine do
  @moduledoc """
  Main optimization engine for GEPA.

  Orchestrates the optimization loop: propose → evaluate → accept/reject → repeat.
  """

  require Logger

  @doc """
  Run optimization until stop condition met.

  ## Parameters

  - `config`: Configuration map with all necessary settings

  ## Returns

  `{:ok, final_state}` on success
  """
  def run(config) do
    # Initialize or load state
    state = initialize_state(config)

    # Run optimization loop
    final_state = optimization_loop(state, config)

    # Save final state if run_dir configured
    if config[:run_dir] do
      save_state(final_state, config.run_dir)
    end

    {:ok, final_state}
  end

  @doc """
  Run a single optimization iteration.

  Returns `{:cont, new_state}` to continue or `{:stop, state}` to stop.
  """
  def run_iteration(state, config) do
    # Check stop conditions
    if should_stop?(state, config.stop_conditions) do
      Logger.info("Stop condition met at iteration #{state.i}")
      {:stop, state}
    else
      # Increment iteration
      state = %{state | i: state.i + 1}
      Logger.debug("Starting iteration #{state.i}")

      # Get proposer (simplified - create inline for MVP)
      proposer = create_proposer(config)

      # Propose new candidate
      case GEPA.Proposer.Reflective.propose(proposer, state) do
        {:ok, proposal} ->
          Logger.debug("Proposal generated for iteration #{state.i}")

          # Update eval counter (proposer evaluated on minibatch twice: before and after)
          num_subsample_evals =
            length(proposal.subsample_scores_before) + length(proposal.subsample_scores_after)

          state = %{state | total_num_evals: state.total_num_evals + num_subsample_evals}

          # Check acceptance
          if GEPA.CandidateProposal.should_accept?(proposal) do
            Logger.info("Accepting proposal at iteration #{state.i}")
            # Evaluate on full validation set
            {:cont, accept_proposal(state, proposal, config)}
          else
            Logger.debug("Rejecting proposal at iteration #{state.i}")
            # Reject proposal, continue
            {:cont, state}
          end

        :none ->
          Logger.debug("No proposal generated at iteration #{state.i}")
          # Still update eval counter for the attempt
          state = %{state | total_num_evals: state.total_num_evals + 1}
          {:cont, state}

        {:error, reason} ->
          Logger.warning("Proposal failed at iteration #{state.i}: #{inspect(reason)}")
          {:cont, state}
      end
    end
  end

  # Private functions

  defp initialize_state(config) do
    # Try to load existing state if run_dir provided
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
  end

  defp create_initial_state(config) do
    # Evaluate seed candidate on validation set
    valset_ids = GEPA.DataLoader.all_ids(config.valset)
    valset_batch = GEPA.DataLoader.fetch(config.valset, valset_ids)

    adapter = config.adapter

    {:ok, eval_batch} =
      adapter.__struct__.evaluate(adapter, valset_batch, config.seed_candidate, false)

    GEPA.State.new(config.seed_candidate, eval_batch, valset_ids)
  end

  defp optimization_loop(state, config, max_iters \\ 1000) do
    # Safety guard against infinite loops
    if state.i >= max_iters do
      Logger.warning("Reached max iterations (#{max_iters}), stopping")
      state
    else
      case run_iteration(state, config) do
        {:cont, new_state} ->
          # Save state periodically
          if config[:run_dir] && rem(new_state.i, 5) == 0 do
            save_state(new_state, config.run_dir)
          end

          optimization_loop(new_state, config, max_iters)

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

  defp accept_proposal(state, proposal, config) do
    # Evaluate on full validation set
    valset_ids = GEPA.DataLoader.all_ids(config.valset)
    valset_batch = GEPA.DataLoader.fetch(config.valset, valset_ids)

    adapter = config.adapter

    case adapter.__struct__.evaluate(adapter, valset_batch, proposal.candidate, false) do
      {:ok, eval_batch} ->
        # Create scores map
        val_scores =
          valset_ids
          |> Enum.zip(eval_batch.scores)
          |> Enum.into(%{})

        # Add to state
        {new_state, new_idx} =
          GEPA.State.add_program(
            state,
            proposal.candidate,
            proposal.parent_program_ids,
            val_scores
          )

        Logger.info(
          "Accepted new program #{new_idx} with avg score #{elem(GEPA.State.get_program_score(new_state, new_idx), 0)}"
        )

        new_state

      {:error, reason} ->
        Logger.error("Failed to evaluate proposal: #{inspect(reason)}")
        state
    end
  end

  defp create_proposer(config) do
    GEPA.Proposer.Reflective.new(
      adapter: config.adapter,
      trainset: config.trainset,
      candidate_selector: config.candidate_selector,
      perfect_score: config[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(config |> Map.to_list(), :skip_perfect_score, true),
      minibatch_size: config[:reflection_minibatch_size] || 3
    )
  end

  defp save_state(state, run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")
    File.mkdir_p!(run_dir)

    data = :erlang.term_to_binary(state, [:compressed])
    File.write!(path, data)
  end

  defp load_state(run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")

    with {:ok, data} <- File.read(path),
         state <- :erlang.binary_to_term(data) do
      {:ok, state}
    end
  end
end
