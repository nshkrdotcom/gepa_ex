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

  alias GEPA.Adapters.Default
  alias GEPA.Proposer.InstructionProposal
  alias GEPA.StopCondition.MaxCalls
  alias GEPA.Strategies.CandidateSelector.Pareto

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
  - `:reflection_llm` - LLM for generating improved instructions (default: nil)
  - `:proposal_template` - Custom template for instruction proposal (default: built-in)
  - `:structured_output` - Use tool_use / function calling for instruction proposals (default: false)
  - `:acceptance_criterion` - Candidate acceptance criterion (default: `:strict_improvement`)
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

  Without `:reflection_llm`, GEPA uses a simple placeholder improvement that
  just appends "[Optimized]" - useful only for testing.

  ## Custom Templates

  When using `:reflection_llm`, you can customize the prompt template with
  `:proposal_template`. The template must include these placeholders:

  - `{component_name}` - Name of the component being optimized
  - `{current_instruction}` - Current instruction text
  - `{reflective_dataset}` - Formatted examples with feedback

  Example:

      custom_template = \"\"\"
      Improve this instruction for {component_name}:
      Current: {current_instruction}
      Examples: {reflective_dataset}
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
    %{
      seed_candidate: fetch_required!(opts, :seed_candidate),
      trainset: ensure_loader(opts[:trainset]),
      valset: ensure_loader(opts[:valset]),
      adapter: build_adapter(opts),
      candidate_selector: Keyword.get(opts, :candidate_selector, Pareto),
      stop_conditions: build_stop_conditions(opts),
      reflection_minibatch_size: Keyword.get(opts, :reflection_minibatch_size, 3),
      perfect_score: Keyword.get(opts, :perfect_score, 1.0),
      skip_perfect_score: Keyword.get(opts, :skip_perfect_score, true),
      seed: Keyword.get(opts, :seed, 0),
      run_dir: opts[:run_dir],
      instruction_proposal: build_instruction_proposal(opts),
      progress: opts[:progress],
      acceptance_criterion: Keyword.get(opts, :acceptance_criterion, :strict_improvement),
      callbacks: Keyword.get(opts, :callbacks, []),
      track_best_outputs: Keyword.get(opts, :track_best_outputs, false),
      frontier_type: Keyword.get(opts, :frontier_type, :instance),
      evaluation_cache: opts[:evaluation_cache]
    }
  end

  defp build_stop_conditions(opts) do
    [MaxCalls.new(fetch_required!(opts, :max_metric_calls))]
  end

  defp fetch_required!(opts, key) do
    Keyword.get(opts, key) || raise ArgumentError, "must provide #{inspect(key)}"
  end

  defp build_adapter(opts) do
    Keyword.get(opts, :adapter) || build_default_adapter(opts)
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
    case opts[:reflection_llm] do
      nil ->
        nil

      llm ->
        proposal_opts = [llm: llm]

        proposal_opts =
          if opts[:proposal_template] do
            Keyword.put(proposal_opts, :template, opts[:proposal_template])
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

  defp ensure_loader(data) when is_list(data) do
    GEPA.DataLoader.List.new(data)
  end

  defp ensure_loader(%GEPA.DataLoader.List{} = loader), do: loader
  defp ensure_loader(loader), do: loader
end
