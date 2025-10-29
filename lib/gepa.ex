defmodule GEPA do
  @moduledoc """
  GEPA: Genetic-Pareto optimizer for text-based system components.

  ## Example

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
  """

  @doc """
  Run GEPA optimization.

  ## Options

  ### Required
  - `:seed_candidate` - Initial program as map of component -> text
  - `:trainset` - Training data (list or DataLoader)
  - `:valset` - Validation data (list or DataLoader)
  - `:adapter` - Adapter module/struct implementing GEPA.Adapter
  - `:max_metric_calls` - Budget for evaluations

  ### Optional
  - `:candidate_selector` - Selection strategy (default: Pareto)
  - `:reflection_minibatch_size` - Minibatch size (default: 3)
  - `:perfect_score` - Perfect score value (default: 1.0)
  - `:skip_perfect_score` - Skip if perfect (default: true)
  - `:seed` - Random seed (default: 0)
  - `:run_dir` - Directory for state persistence (default: nil)

  ## Returns

  `{:ok, result}` where result is a `GEPA.Result` struct
  """
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
    # Convert lists to DataLoaders
    trainset = ensure_loader(opts[:trainset])
    valset = ensure_loader(opts[:valset])

    # Build stop conditions
    stop_conditions =
      if opts[:max_metric_calls] do
        [GEPA.StopCondition.MaxCalls.new(opts[:max_metric_calls])]
      else
        raise ArgumentError, "must provide :max_metric_calls"
      end

    %{
      seed_candidate:
        opts[:seed_candidate] || raise(ArgumentError, "must provide :seed_candidate"),
      trainset: trainset,
      valset: valset,
      adapter: opts[:adapter] || raise(ArgumentError, "must provide :adapter"),
      candidate_selector: opts[:candidate_selector] || GEPA.Strategies.CandidateSelector.Pareto,
      stop_conditions: stop_conditions,
      reflection_minibatch_size: opts[:reflection_minibatch_size] || 3,
      perfect_score: opts[:perfect_score] || 1.0,
      skip_perfect_score: Keyword.get(opts, :skip_perfect_score, true),
      seed: opts[:seed] || 0,
      run_dir: opts[:run_dir]
    }
  end

  defp ensure_loader(data) when is_list(data) do
    GEPA.DataLoader.List.new(data)
  end

  defp ensure_loader(%GEPA.DataLoader.List{} = loader), do: loader
  defp ensure_loader(loader), do: loader
end
