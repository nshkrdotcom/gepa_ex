defmodule GEPA.OptimizeAnything.EngineConfig do
  @moduledoc "Engine options for `GEPA.OptimizeAnything`."

  defstruct max_metric_calls: 20,
            max_candidate_proposals: nil,
            max_reflection_cost: nil,
            reflection_minibatch_size: 3,
            num_parallel_proposals: 1,
            max_iterations: 1000,
            seed: 0,
            run_dir: nil,
            cache_evaluation: :off,
            cache_evaluation_storage: :auto,
            raise_on_exception: true,
            track_best_outputs: true,
            best_example_evals_k: 30,
            max_workers: nil,
            parallel: true,
            capture_stdio: false,
            use_cloudpickle: false,
            display_progress_bar: false,
            candidate_selection_strategy: nil,
            val_evaluation_policy: nil,
            acceptance_criterion: nil,
            frontier_type: :instance,
            stop_conditions: nil

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, Map.new(opts))
end

defmodule GEPA.OptimizeAnything.ReflectionConfig do
  @moduledoc "Reflection options for `GEPA.OptimizeAnything`."

  defstruct reflection_lm: nil,
            reflection_lm_kwargs: nil,
            proposal_template: nil,
            reflection_prompt_template: nil,
            custom_candidate_proposer: nil,
            structured_output: false,
            perfect_score: 1.0,
            skip_perfect_score: true,
            reflection_minibatch_size: nil,
            batch_sampler: nil,
            module_selector: nil

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, Map.new(opts))
end

defmodule GEPA.OptimizeAnything.MergeConfig do
  @moduledoc "Merge options for `GEPA.OptimizeAnything`."

  defstruct use_merge: false, max_merge_invocations: 5, merge_val_overlap_floor: 5

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, Map.new(opts))
end

defmodule GEPA.OptimizeAnything.RefinerConfig do
  @moduledoc "Candidate-refinement options for `GEPA.OptimizeAnything`."

  defstruct enabled: false,
            refiner_lm: nil,
            refiner_prompt: nil,
            max_attempts: 1,
            max_refinements: nil,
            score_key: nil

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, Map.new(opts))
end

defmodule GEPA.OptimizeAnything.OptimizationState do
  @moduledoc """
  Historical per-example context injected into optimize-anything evaluators.

  `best_example_evals` contains the top-K prior evaluations for the same
  example, sorted by score descending. Evaluators can use it to warm-start
  expensive searches or avoid repeating known failures.
  """

  defstruct best_example_evals: []

  @type t :: %__MODULE__{best_example_evals: [map()]}
end

defmodule GEPA.OptimizeAnything.TrackingConfig do
  @moduledoc "Tracking options for `GEPA.OptimizeAnything`."

  defstruct tracker: nil,
            key_prefix: nil,
            attach_existing: false,
            logger: nil,
            use_wandb: false,
            wandb_api_key: nil,
            wandb_init_kwargs: nil,
            wandb_attach_existing: false,
            wandb_step_metric: nil,
            use_mlflow: false,
            mlflow_tracking_uri: nil,
            mlflow_experiment_name: nil,
            mlflow_attach_existing: false

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, Map.new(opts))
end

defmodule GEPA.OptimizeAnything.Config do
  @moduledoc "Complete configuration for `GEPA.OptimizeAnything.optimize_anything/1`."

  alias GEPA.OptimizeAnything.{
    EngineConfig,
    MergeConfig,
    RefinerConfig,
    ReflectionConfig,
    TrackingConfig
  }

  defstruct seed_candidate: nil,
            dataset: nil,
            valset: nil,
            evaluator: nil,
            objective: nil,
            background: nil,
            engine: %EngineConfig{},
            reflection: %ReflectionConfig{},
            merge: %MergeConfig{},
            refiner: %RefinerConfig{},
            tracking: %TrackingConfig{}

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    struct!(__MODULE__, %{
      seed_candidate: Map.get(opts, :seed_candidate),
      dataset: Map.get(opts, :dataset),
      valset: Map.get(opts, :valset),
      evaluator: Map.get(opts, :evaluator),
      objective: Map.get(opts, :objective),
      background: Map.get(opts, :background),
      engine: normalize_nested(opts, :engine, EngineConfig),
      reflection: normalize_nested(opts, :reflection, ReflectionConfig),
      merge: normalize_nested(opts, :merge, MergeConfig),
      refiner: normalize_nested(opts, :refiner, RefinerConfig),
      tracking: normalize_nested(opts, :tracking, TrackingConfig)
    })
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      seed_candidate: config.seed_candidate,
      dataset: config.dataset,
      valset: config.valset,
      evaluator: config.evaluator,
      objective: config.objective,
      background: config.background,
      engine: Map.from_struct(config.engine),
      reflection: Map.from_struct(config.reflection),
      merge: Map.from_struct(config.merge),
      refiner: Map.from_struct(config.refiner),
      tracking: Map.from_struct(config.tracking)
    }
  end

  defp normalize_nested(opts, key, module) do
    case Map.get(opts, key) do
      nil -> module.new()
      %{__struct__: ^module} = value -> value
      value when is_list(value) or is_map(value) -> module.new(value)
    end
  end
end

defmodule GEPA.OptimizeAnything.LogContext do
  @moduledoc """
  Process-local diagnostic log context used by optimize-anything evaluators.
  """

  @key {__MODULE__, :context}

  @spec get() :: [String.t()]
  def get, do: Process.get(@key, [])

  @spec set([String.t()]) :: :ok
  def set(entries) when is_list(entries) do
    Process.put(@key, entries)
    :ok
  end

  @spec log(term()) :: :ok
  def log(message) do
    Process.put(@key, get() ++ [to_string(message)])
    :ok
  end

  @spec capture((-> term())) :: {term(), [String.t()], String.t()}
  def capture(fun) when is_function(fun, 0) do
    previous_context = get()
    set([])
    {result, stdout} = capture_io(fun)
    logs = get()
    set(previous_context)
    {result, logs, stdout}
  end

  defp capture_io(fun) do
    {:ok, io} = StringIO.open("")
    previous = Process.group_leader()
    Process.group_leader(self(), io)

    try do
      result = fun.()
      {_input, output} = StringIO.contents(io)
      {result, output}
    after
      Process.group_leader(self(), previous)
    end
  end
end

defmodule GEPA.OptimizeAnything.EvaluatorWrapper do
  @moduledoc """
  Normalizes user evaluator signatures and return values.
  """

  alias GEPA.OptimizeAnything.LogContext

  @spec evaluate(function(), term(), term(), keyword()) :: map()
  def evaluate(evaluator, candidate, example \\ nil, opts \\ []) when is_function(evaluator) do
    opt_state = Keyword.get(opts, :opt_state)

    {result, logs, stdout} =
      LogContext.capture(fn ->
        call_evaluator(evaluator, candidate, example, opt_state)
      end)

    result
    |> normalize_result()
    |> put_captured_side_info(logs, stdout)
    |> Map.put(:logs, logs)
    |> Map.put(:stdout, stdout)
  rescue
    exception ->
      if Keyword.get(opts, :raise_on_exception, false) do
        reraise exception, __STACKTRACE__
      else
        side_info = %{"error" => Exception.message(exception)}

        %{
          score: 0.0,
          output: nil,
          scores: nil,
          side_info: side_info,
          error: Exception.format(:error, exception, __STACKTRACE__),
          logs: LogContext.get(),
          stdout: ""
        }
      end
  end

  defp call_evaluator(evaluator, candidate, nil, nil) do
    cond do
      callable_arity?(evaluator, 1) -> evaluator.(candidate)
      callable_arity?(evaluator, 2) -> evaluator.(candidate, nil)
      callable_arity?(evaluator, 3) -> evaluator.(candidate, nil, nil)
    end
  end

  defp call_evaluator(evaluator, candidate, example, nil) do
    cond do
      callable_arity?(evaluator, 2) -> evaluator.(candidate, example)
      callable_arity?(evaluator, 1) -> evaluator.(candidate)
      callable_arity?(evaluator, 3) -> evaluator.(candidate, example, nil)
    end
  end

  defp call_evaluator(evaluator, candidate, example, opt_state) do
    cond do
      callable_arity?(evaluator, 3) -> evaluator.(candidate, example, opt_state)
      callable_arity?(evaluator, 2) -> evaluator.(candidate, example)
      callable_arity?(evaluator, 1) -> evaluator.(candidate)
    end
  end

  defp callable_arity?(fun, arity) do
    {:arity, arity} in Function.info(fun)
  end

  defp normalize_result({score, side_info}) when is_number(score) and is_map(side_info) do
    side_info = stringify_keys(side_info)

    %{
      score: score * 1.0,
      output: Map.get(side_info, "output"),
      scores: map_get_any(side_info, ["scores", :scores]),
      side_info: side_info,
      error: map_get_any(side_info, ["error", :error])
    }
  end

  defp normalize_result({score, output}) when is_number(score) do
    %{score: score * 1.0, output: output, scores: nil, side_info: %{}, error: nil}
  end

  defp normalize_result(score) when is_number(score) do
    %{score: score * 1.0, output: score, scores: nil, side_info: %{}, error: nil}
  end

  defp normalize_result(%{} = result) do
    side_info =
      result
      |> Map.drop([:score, "score", :metric, "metric", :output, "output"])
      |> stringify_keys()

    score =
      result
      |> Map.get(
        :score,
        Map.get(result, "score", Map.get(result, :metric, Map.get(result, "metric", 0.0)))
      )
      |> normalize_score()

    output = Map.get(result, :output, Map.get(result, "output", result))
    scores = Map.get(result, :scores, Map.get(result, "scores"))

    %{
      score: score,
      output: output,
      scores: scores,
      side_info: side_info,
      error: Map.get(result, :error, Map.get(result, "error"))
    }
  end

  defp normalize_result(other),
    do: %{score: 0.0, output: other, scores: nil, side_info: %{}, error: nil}

  defp normalize_score(score) when is_number(score), do: score * 1.0
  defp normalize_score(_score), do: 0.0

  defp put_captured_side_info(result, logs, stdout) do
    side_info =
      result.side_info
      |> maybe_put("log", Enum.join(logs, "\n"))
      |> maybe_put("stdout", stdout)
      |> maybe_put("error", result.error)

    %{result | side_info: side_info}
  end

  defp maybe_put(side_info, _key, nil), do: side_info
  defp maybe_put(side_info, _key, ""), do: side_info
  defp maybe_put(side_info, key, value), do: Map.put_new(side_info, key, value)

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(%GEPA.Image{} = image), do: image
  defp stringify_value(%{} = map), do: stringify_keys(map)
  defp stringify_value(value), do: value

  defp map_get_any(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end
end

defmodule GEPA.OptimizeAnything.Adapter do
  @moduledoc """
  Internal adapter that lets `optimize_anything` use the normal GEPA engine.
  """

  @behaviour GEPA.Adapter

  alias GEPA.OptimizeAnything.{EvaluatorWrapper, OptimizationState}

  @refiner_prompt_template """
  You are refining a candidate to improve its performance.

  ## Instructions
  {refiner_prompt}

  ## Current Candidate (JSON)
  ```json
  {candidate_to_improve}
  ```

  ## Evaluation History
  The following shows all evaluation attempts so far, including scores and feedback:
  ```json
  {evaluation_feedback}
  ```

  ## Task
  Analyze the evaluation history and propose an improved version of the candidate.
  Return ONLY a valid JSON object with the improved parameters (no explanation, no markdown fences).
  """

  defstruct [
    :evaluator,
    :objective,
    :background,
    :cache_mode,
    :cache_dir,
    :cache_table,
    :best_evals_table,
    :parallelism,
    :refiner_config,
    :raise_on_exception,
    :str_candidate_key,
    best_example_evals_k: 30,
    top_k: 3
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      evaluator: Keyword.fetch!(opts, :evaluator),
      objective: opts[:objective],
      background: opts[:background],
      cache_mode: Keyword.get(opts, :cache_mode, :off),
      cache_dir: Keyword.get(opts, :cache_dir),
      cache_table: new_table(:gepa_oa_eval_cache),
      best_evals_table: new_table(:gepa_oa_best_evals),
      parallelism: Keyword.get(opts, :parallelism, System.schedulers_online()),
      refiner_config: opts[:refiner_config],
      raise_on_exception: Keyword.get(opts, :raise_on_exception, true),
      str_candidate_key: opts[:str_candidate_key],
      best_example_evals_k: Keyword.get(opts, :best_example_evals_k, 30),
      top_k: Keyword.get(opts, :top_k, 3)
    }
  end

  @impl true
  def evaluate(%__MODULE__{} = adapter, batch, candidate, capture_traces) do
    results =
      batch
      |> Task.async_stream(
        fn example ->
          if refiner_enabled?(adapter.refiner_config) do
            evaluate_one_with_refinement(adapter, candidate, example)
          else
            evaluate_one(adapter, candidate, example)
          end
        end,
        max_concurrency: adapter.parallelism,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, value} -> value
        {:exit, reason} -> raise "optimize_anything evaluation failed: #{inspect(reason)}"
      end)

    unless refiner_enabled?(adapter.refiner_config) do
      batch
      |> Enum.zip(results)
      |> Enum.each(fn {example, result} ->
        update_best_example_evals(adapter, example, result.score, result.side_info)
      end)
    end

    objective_scores = Enum.map(results, &objective_scores(&1.side_info, candidate))

    {:ok,
     %GEPA.EvaluationBatch{
       outputs: Enum.map(results, & &1.output),
       scores: Enum.map(results, & &1.score),
       objective_scores:
         if(Enum.any?(objective_scores, &(map_size(&1) > 0)), do: objective_scores),
       trajectories: if(capture_traces, do: Enum.map(results, & &1.side_info)),
       num_metric_calls: Enum.sum(Enum.map(results, & &1.metric_calls))
     }}
  end

  @impl true
  def make_reflective_dataset(_adapter, _candidate, eval_batch, components) do
    side_infos = eval_batch.trajectories || []

    dataset =
      Map.new(components, fn component ->
        items =
          eval_batch.scores
          |> Enum.zip(side_infos)
          |> Enum.map(fn {score, side_info} ->
            side_info
            |> normalize_reflective_side_info(component)
            |> Map.put_new("Score", score)
          end)

        {component, items}
      end)

    {:ok, dataset}
  end

  defp evaluate_one(%__MODULE__{} = adapter, candidate, example) do
    cache_key = cache_key(candidate, example)

    case cache_get(adapter, cache_key) do
      {:hit, value} ->
        %{value | cache_hit: true, metric_calls: 0}

      :miss ->
        opt_state = build_opt_state(adapter, example)

        result =
          EvaluatorWrapper.evaluate(
            adapter.evaluator,
            evaluator_candidate(adapter, candidate),
            example,
            opt_state: opt_state,
            raise_on_exception: adapter.raise_on_exception
          )

        entry = %{
          score: result.score,
          output: result.output,
          scores: result.scores,
          side_info: result.side_info,
          metric_calls: 1,
          cache_hit: false
        }

        cache_put(adapter, cache_key, entry)
        entry
    end
  end

  defp evaluate_one_with_refinement(%__MODULE__{} = adapter, candidate, example) do
    original = evaluate_one(adapter, candidate, example)
    update_best_example_evals(adapter, example, original.score, original.side_info)

    {best_refined, attempts} =
      refine_and_evaluate(adapter, candidate, example, original.score, original.side_info)

    {final_score, best_candidate} =
      if best_refined && best_refined.score > original.score do
        {best_refined.score, best_refined.candidate}
      else
        {original.score, candidate}
      end

    refiner_info = %{
      "Attempts" => attempts,
      "scores" => best_refiner_scores(original.side_info, attempts)
    }

    side_info =
      original.side_info
      |> Map.put("refiner_prompt_specific_info", refiner_info)

    %{
      score: final_score,
      output: {final_score, best_candidate, side_info},
      scores: Map.get(side_info, "scores"),
      side_info: side_info,
      metric_calls:
        original.metric_calls + Enum.sum(Enum.map(attempts, &Map.get(&1, "metric_calls", 0))),
      cache_hit: false
    }
  end

  defp refine_and_evaluate(adapter, candidate, example, original_score, original_side_info) do
    params = Map.delete(candidate, "refiner_prompt")

    original_attempt = %{
      "iteration" => 0,
      "candidate" => params,
      "score" => original_score,
      "side_info" => original_side_info,
      "metric_calls" => 0
    }

    max_attempts = max_refinements(adapter.refiner_config)

    Enum.reduce_while(1..max_attempts, {nil, [original_attempt], params, original_score}, fn
      iteration, {best_refined, attempts, current_params, best_score} ->
        adapter
        |> propose_refinement(candidate, current_params, attempts)
        |> handle_refinement_result(
          adapter,
          candidate,
          example,
          iteration,
          {best_refined, attempts, current_params, best_score}
        )
    end)
    |> then(fn {best_refined, attempts, _params, _best_score} -> {best_refined, attempts} end)
  end

  defp handle_refinement_result(
         {:ok, refined_params},
         adapter,
         candidate,
         example,
         iteration,
         {best_refined, attempts, current_params, best_score}
       ) do
    refined_candidate =
      candidate
      |> Map.take(["refiner_prompt"])
      |> Map.merge(refined_params)

    result = evaluate_one(adapter, refined_candidate, example)
    update_best_example_evals(adapter, example, result.score, result.side_info)

    attempt = %{
      "iteration" => iteration,
      "candidate" => refined_params,
      "score" => result.score,
      "side_info" => result.side_info,
      "metric_calls" => result.metric_calls
    }

    attempts = attempts ++ [attempt]

    if result.score > best_score do
      {:cont,
       {Map.put(result, :candidate, refined_candidate), attempts, refined_params, result.score}}
    else
      {:halt, {best_refined, attempts, current_params, best_score}}
    end
  end

  defp handle_refinement_result(
         {:error, reason, raw_output},
         _adapter,
         _candidate,
         _example,
         iteration,
         {best_refined, attempts, current_params, best_score}
       ) do
    attempt = %{
      "iteration" => iteration,
      "error" => inspect(reason),
      "raw_output" => raw_output,
      "score" => -1.0e9,
      "metric_calls" => 0
    }

    {:cont, {best_refined, attempts ++ [attempt], current_params, best_score}}
  end

  defp propose_refinement(adapter, candidate, current_params, attempts) do
    prompt =
      @refiner_prompt_template
      |> String.replace(
        "{refiner_prompt}",
        Map.get(candidate, "refiner_prompt", "Improve the candidate.")
      )
      |> String.replace("{candidate_to_improve}", Jason.encode!(current_params, pretty: true))
      |> String.replace("{evaluation_feedback}", Jason.encode!(attempts, pretty: true))

    with {:ok, raw_output} <- call_refiner_lm(adapter.refiner_config.refiner_lm, prompt),
         {:ok, parsed} <- parse_refiner_json(raw_output) do
      {:ok, stringify_keys(parsed)}
    else
      {:error, reason, raw_output} -> {:error, reason, raw_output}
      {:error, reason} -> {:error, reason, nil}
    end
  rescue
    exception -> {:error, exception, nil}
  end

  defp call_refiner_lm(lm, prompt) when is_function(lm, 1), do: {:ok, lm.(prompt)}

  defp call_refiner_lm(lm, prompt) do
    GEPA.LLM.complete(lm, prompt)
  end

  defp parse_refiner_json(raw_output) when is_binary(raw_output) do
    cleaned = strip_code_fence(String.trim(raw_output))

    case Jason.decode(cleaned) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, other} -> {:error, {:invalid_refiner_json, other}, cleaned}
      {:error, reason} -> {:error, {:json_parse_error, reason}, cleaned}
    end
  end

  defp parse_refiner_json(other), do: {:error, {:invalid_refiner_output, other}, inspect(other)}

  defp strip_code_fence("```" <> rest) do
    rest
    |> String.split("\n")
    |> drop_fence_language()
    |> Enum.reverse()
    |> drop_closing_fence()
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp strip_code_fence(text), do: text

  defp drop_fence_language([first | rest]) do
    if String.trim(first) in ["", "json"] do
      rest
    else
      [first | rest]
    end
  end

  defp drop_fence_language(lines), do: lines

  defp drop_closing_fence([last | rest]) do
    if String.trim(last) == "```", do: rest, else: [last | rest]
  end

  defp drop_closing_fence(lines), do: lines

  defp evaluator_candidate(%__MODULE__{str_candidate_key: key}, candidate)
       when is_binary(key) and is_map(candidate) do
    Map.fetch!(candidate, key)
  end

  defp evaluator_candidate(_adapter, candidate), do: candidate

  defp cache_get(%__MODULE__{cache_mode: :off}, _key), do: :miss

  defp cache_get(%__MODULE__{cache_mode: :memory, cache_table: table}, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:hit, value}
      [] -> :miss
    end
  end

  defp cache_get(%__MODULE__{cache_mode: mode, cache_dir: dir}, key)
       when mode in [:disk, :auto] do
    path = cache_path(dir, key)

    case File.read(path) do
      {:ok, data} -> {:hit, :erlang.binary_to_term(data)}
      {:error, _} -> :miss
    end
  end

  defp cache_put(%__MODULE__{cache_mode: mode, cache_dir: dir}, key, entry)
       when mode in [:disk, :auto] do
    path = cache_path(dir, key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(entry))
    :ok
  end

  defp cache_put(%__MODULE__{cache_mode: :memory, cache_table: table}, key, entry) do
    :ets.insert(table, {key, entry})
    :ok
  end

  defp cache_put(_adapter, _key, _entry), do: :ok

  defp cache_path(nil, key), do: cache_path(Path.join(System.tmp_dir!(), "gepa_oa_cache"), key)
  defp cache_path(dir, key), do: Path.join(dir, Base.url_encode64(key, padding: false) <> ".etf")

  defp cache_key(candidate, example), do: :erlang.term_to_binary({candidate, example})

  defp new_table(name) do
    :ets.new(name, [:set, :public, read_concurrency: true, write_concurrency: true])
  end

  defp build_opt_state(adapter, example) do
    %OptimizationState{best_example_evals: get_best_example_evals(adapter, example)}
  end

  defp get_best_example_evals(adapter, example) do
    key = example_hash(example)

    case :ets.lookup(adapter.best_evals_table, key) do
      [{^key, values}] -> values
      [] -> []
    end
  end

  defp update_best_example_evals(adapter, example, score, side_info) do
    key = example_hash(example)
    values = get_best_example_evals(adapter, example)
    entry = %{score: score, side_info: side_info}

    updated =
      [entry | values]
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(adapter.best_example_evals_k)

    :ets.insert(adapter.best_evals_table, {key, updated})
    :ok
  end

  defp example_hash(example) do
    example
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp objective_scores(side_info, candidate) do
    component_keys =
      case candidate do
        %{} -> Map.keys(candidate)
        _ -> []
      end

    top_level =
      side_info
      |> Map.get("scores", %{})
      |> normalize_score_map()

    Enum.reduce(component_keys, top_level, fn component, acc ->
      key = "#{component}_specific_info"

      component_scores =
        side_info
        |> Map.get(key, %{})
        |> Map.get("scores", %{})
        |> normalize_score_map()
        |> Map.new(fn {name, value} -> {"#{component}::#{name}", value} end)

      Map.merge(acc, component_scores)
    end)
  end

  defp normalize_score_map(%{} = scores) do
    Map.new(scores, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_score_map(_scores), do: %{}

  defp normalize_reflective_side_info(side_info, component) do
    side_info
    |> Enum.reduce(%{}, fn
      {"scores", value}, acc ->
        Map.put(acc, "Scores (Higher is Better)", value)

      {key, value}, acc ->
        cond do
          key == "#{component}_specific_info" and is_map(value) ->
            Map.merge(acc, value)

          String.ends_with?(key, "_specific_info") ->
            acc

          true ->
            Map.put(acc, key, value)
        end
    end)
  end

  defp best_refiner_scores(original_side_info, attempts) do
    if Map.has_key?(original_side_info, "scores") do
      attempts
      |> Enum.filter(&is_map(Map.get(&1, "side_info")))
      |> Enum.max_by(&Map.get(&1, "score", -1.0e9), fn -> nil end)
      |> case do
        nil -> %{}
        attempt -> get_in(attempt, ["side_info", "scores"]) || %{}
      end
    else
      %{}
    end
  end

  defp max_refinements(nil), do: 0
  defp max_refinements(%{max_refinements: value}) when is_integer(value) and value >= 0, do: value
  defp max_refinements(%{max_attempts: value}) when is_integer(value) and value >= 0, do: value
  defp max_refinements(_config), do: 1

  defp refiner_enabled?(%{enabled: true, refiner_lm: lm}) when not is_nil(lm), do: true
  defp refiner_enabled?(_config), do: false

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(%GEPA.Image{} = image), do: image
  defp stringify_value(%{} = map), do: stringify_keys(map)
  defp stringify_value(value), do: value
end

defmodule GEPA.OptimizeAnything do
  @moduledoc """
  Optimize an arbitrary candidate with a user-supplied evaluator.

  This is the Elixir port of upstream `optimize_anything`: it wraps a normal
  evaluator in a GEPA adapter, supports single-task and dataset modes, string
  candidates, seed generation, evaluator diagnostics, cache-aware evaluation,
  and the regular GEPA optimizer.
  """

  alias GEPA.LLM.Mock, as: LLMMock
  alias GEPA.OptimizeAnything.{Adapter, Config, LogContext}
  alias GEPA.Seed

  @str_candidate_key "current_candidate"
  @default_refiner_prompt """
  You are a refinement agent improving candidates in an optimization loop.

  ## What We're Optimizing For
  The overall optimization objective is:
  {objective}

  ## Domain Knowledge
  {background}

  ## Your Task
  Given a candidate and its evaluation feedback:
  1. Understand why it scored the way it did
  2. Fix any errors (errors = zero score)
  3. Make improvements that move toward the objective
  4. Return the complete improved candidate
  """

  @tracking_option_keys [
    :key_prefix,
    :attach_existing,
    :logger,
    :use_wandb,
    :wandb_api_key,
    :wandb_init_kwargs,
    :wandb_attach_existing,
    :wandb_step_metric,
    :use_mlflow,
    :mlflow_tracking_uri,
    :mlflow_experiment_name,
    :mlflow_attach_existing
  ]

  @doc "Return the internal key used to wrap string candidates."
  @spec str_candidate_key() :: String.t()
  def str_candidate_key, do: @str_candidate_key

  @doc "Return the default refiner prompt template."
  @spec default_refiner_prompt() :: String.t()
  def default_refiner_prompt, do: @default_refiner_prompt

  @doc "Build the seed-generation prompt used when `seed_candidate` is nil."
  @spec build_seed_generation_prompt(keyword() | map()) :: String.t()
  def build_seed_generation_prompt(opts), do: Seed.build_prompt(opts)

  @doc "Generate an initial seed candidate using an LM."
  @spec generate_seed_candidate(term(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def generate_seed_candidate(lm, opts) do
    opts = opts |> Map.new() |> Map.put_new(:candidate_key, @str_candidate_key)
    Seed.generate(lm, opts)
  end

  @doc "Append a diagnostic message to the process-local optimize-anything log."
  @spec log(term()) :: :ok
  defdelegate log(message), to: LogContext

  @doc "Return the process-local optimize-anything diagnostic log."
  @spec get_log_context() :: [String.t()]
  defdelegate get_log_context(), to: LogContext, as: :get

  @doc "Replace the process-local optimize-anything diagnostic log."
  @spec set_log_context([String.t()]) :: :ok
  defdelegate set_log_context(entries), to: LogContext, as: :set

  @doc """
  Optimize any candidate/evaluator pair.
  """
  @spec optimize_anything(keyword() | map() | Config.t()) ::
          {:ok, GEPA.Result.t()} | {:error, term()}
  def optimize_anything(%Config{} = config), do: run(config)
  def optimize_anything(opts), do: opts |> Config.new() |> run()

  defp run(%Config{} = config) do
    config = resolve_runtime_config!(config)

    with :ok <- validate!(config),
         {:ok, seed_candidate, string_candidate?} <- seed_candidate(config) do
      seed_candidate = maybe_inject_refiner_prompt(seed_candidate, config)
      opts = build_optimize_opts(config, seed_candidate, string_candidate?)

      case GEPA.optimize(opts) do
        {:ok, result} when string_candidate? -> {:ok, unwrap_string_result(result)}
        other -> other
      end
    end
  rescue
    exception -> {:error, exception}
  end

  defp build_optimize_opts(config, seed_candidate, string_candidate?) do
    dataset = normalize_dataset(config.dataset)
    valset = normalize_dataset(config.valset || config.dataset)
    cache_mode = cache_mode(config)
    workers = config.engine.max_workers || System.schedulers_online()

    reflection_minibatch_size =
      config.reflection.reflection_minibatch_size ||
        config.engine.reflection_minibatch_size ||
        3

    adapter =
      Adapter.new(
        evaluator: config.evaluator,
        objective: config.objective,
        background: config.background,
        cache_mode: cache_mode,
        cache_dir: cache_dir(config),
        parallelism: workers,
        refiner_config: config.refiner,
        raise_on_exception: config.engine.raise_on_exception,
        str_candidate_key: if(string_candidate?, do: @str_candidate_key),
        best_example_evals_k: config.engine.best_example_evals_k
      )

    [
      seed_candidate: seed_candidate,
      trainset: dataset,
      valset: valset,
      adapter: adapter,
      max_metric_calls: config.engine.max_metric_calls,
      max_candidate_proposals: config.engine.max_candidate_proposals,
      max_reflection_cost: config.engine.max_reflection_cost,
      max_iterations: config.engine.max_iterations,
      num_parallel_proposals:
        resolve_num_parallel_proposals(
          config.engine.num_parallel_proposals,
          workers,
          reflection_minibatch_size || 1
        ),
      reflection_minibatch_size: reflection_minibatch_size,
      run_dir: config.engine.run_dir,
      cache_evaluation: config.engine.cache_evaluation in [true, :memory],
      raise_on_exception: config.engine.raise_on_exception,
      track_best_outputs: config.engine.track_best_outputs,
      frontier_type: config.engine.frontier_type,
      candidate_selection_strategy: config.engine.candidate_selection_strategy,
      val_evaluation_policy: config.engine.val_evaluation_policy,
      acceptance_criterion: config.engine.acceptance_criterion,
      reflection_llm: config.reflection.reflection_lm,
      proposal_template: config.reflection.proposal_template,
      structured_output: config.reflection.structured_output,
      custom_candidate_proposer: config.reflection.custom_candidate_proposer,
      batch_sampler: config.reflection.batch_sampler,
      module_selector: config.reflection.module_selector,
      skip_perfect_score: config.reflection.skip_perfect_score,
      perfect_score: config.reflection.perfect_score,
      use_merge: config.merge.use_merge,
      max_merge_invocations: config.merge.max_merge_invocations,
      merge_val_overlap_floor: config.merge.merge_val_overlap_floor,
      tracker: build_tracker(config.tracking),
      progress: config.engine.display_progress_bar
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp build_tracker(%GEPA.OptimizeAnything.TrackingConfig{tracker: tracker})
       when not is_nil(tracker),
       do: tracker

  defp build_tracker(%GEPA.OptimizeAnything.TrackingConfig{} = tracking) do
    if tracking_options_present?(tracking) do
      tracking
      |> Map.from_struct()
      |> Map.delete(:tracker)
      |> GEPA.Tracking.create_experiment_tracker()
    end
  end

  defp tracking_options_present?(%GEPA.OptimizeAnything.TrackingConfig{} = tracking) do
    tracking
    |> Map.from_struct()
    |> Map.take(@tracking_option_keys)
    |> Enum.any?(fn {_key, value} -> present_tracking_value?(value) end)
  end

  defp present_tracking_value?(nil), do: false
  defp present_tracking_value?(false), do: false
  defp present_tracking_value?(_value), do: true

  defp resolve_runtime_config!(%Config{} = config) do
    reflection_lm =
      resolve_reflection_lm(
        config.reflection.reflection_lm,
        config.reflection.reflection_lm_kwargs
      )

    proposal_template = resolve_reflection_prompt_template!(config)

    reflection = %{
      config.reflection
      | reflection_lm: reflection_lm,
        proposal_template: proposal_template || config.reflection.proposal_template
    }

    %{config | reflection: reflection}
  end

  defp resolve_reflection_lm(nil, _kwargs), do: nil
  defp resolve_reflection_lm(%GEPA.LLM.Tracking{} = lm, _kwargs), do: lm

  defp resolve_reflection_lm(lm, _kwargs) when is_function(lm, 1) or is_function(lm, 2),
    do: GEPA.LLM.track(lm)

  defp resolve_reflection_lm(model_name, kwargs) when is_binary(model_name) do
    case String.split(model_name, "/", parts: 2) do
      ["mock"] ->
        LLMMock.new()

      [provider, model] ->
        provider
        |> provider_atom()
        |> GEPA.LLM.req_llm([{:model, model} | kwargs_to_keyword(kwargs)])

      [model] ->
        GEPA.LLM.req_llm(:openai, [{:model, model} | kwargs_to_keyword(kwargs)])
    end
  end

  defp resolve_reflection_lm(lm, _kwargs), do: lm

  defp provider_atom("openai"), do: :openai
  defp provider_atom("google"), do: :gemini
  defp provider_atom("gemini"), do: :gemini
  defp provider_atom("anthropic"), do: :anthropic
  defp provider_atom(_other), do: :openai

  defp kwargs_to_keyword(nil), do: []
  defp kwargs_to_keyword(kwargs) when is_list(kwargs), do: kwargs
  defp kwargs_to_keyword(kwargs) when is_map(kwargs), do: Map.to_list(kwargs)
  defp kwargs_to_keyword(_kwargs), do: []

  defp resolve_reflection_prompt_template!(%Config{} = config) do
    custom_template =
      config.reflection.reflection_prompt_template || config.reflection.proposal_template

    objective_or_background? = present?(config.objective) or present?(config.background)

    cond do
      present?(custom_template) and objective_or_background? ->
        raise ArgumentError,
              "cannot specify both objective/background and a custom reflection prompt template"

      objective_or_background? ->
        build_reflection_prompt_template(config.objective, config.background)

      true ->
        custom_template
    end
  end

  defp build_reflection_prompt_template(objective, background) do
    objective_section =
      if present?(objective) do
        "\n## Optimization Goal\n\n#{objective}\n"
      else
        ""
      end

    background_section =
      if present?(background) do
        "\n## Domain Context & Constraints\n\n#{background}\n"
      else
        ""
      end

    constraint_line =
      if present?(background) do
        "\n4. Adheres to all constraints and requirements from the domain context"
      else
        ""
      end

    """
    You are an expert optimization assistant. Your task is to analyze evaluation feedback and propose an improved version of a system component.
    #{objective_section}#{background_section}
    ## Current Component

    The component being optimized:

    ```
    <curr_param>
    ```

    ## Evaluation Results

    Performance data from evaluating the current component across test cases:

    ```
    <side_info>
    ```

    ## Your Task

    Analyze failure patterns, success patterns, root causes, and the optimization goal.

    Based on your analysis, propose an improved version that:
    1. Addresses identified failure patterns and root causes
    2. Preserves successful behaviors from the current version
    3. Makes meaningful improvements rather than superficial changes#{constraint_line}

    ## Output Format

    Provide ONLY the improved version within ``` blocks. The output must be a complete, drop-in replacement for the current component.
    """
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp validate!(%Config{} = config) do
    cond do
      not is_function(config.evaluator) ->
        raise ArgumentError, "evaluator must be a function"

      is_nil(config.seed_candidate) and not present?(config.objective) ->
        raise ArgumentError, "objective is required when seed_candidate is nil"

      true ->
        :ok
    end
  end

  defp seed_candidate(%Config{seed_candidate: nil} = config) do
    case config.reflection.reflection_lm do
      nil ->
        {:error, :reflection_lm_required_for_seedless_mode}

      lm ->
        opts = [
          objective: config.objective,
          background: config.background,
          dataset: normalize_dataset(config.dataset),
          candidate_key: @str_candidate_key
        ]

        with {:ok, candidate} <- Seed.generate(lm, opts) do
          {:ok, candidate, true}
        end
    end
  end

  defp seed_candidate(%Config{seed_candidate: seed}) when is_binary(seed) do
    {:ok, %{@str_candidate_key => seed}, true}
  end

  defp seed_candidate(%Config{seed_candidate: seed}) when is_map(seed) do
    {:ok, seed, false}
  end

  defp seed_candidate(%Config{seed_candidate: seed}) do
    {:ok, %{"candidate" => inspect(seed)}, true}
  end

  defp normalize_dataset(nil), do: [%{}]
  defp normalize_dataset([]), do: [%{}]
  defp normalize_dataset(data) when is_list(data), do: data
  defp normalize_dataset(data), do: data

  defp unwrap_string_result(%GEPA.Result{} = result) do
    unwrap = fn
      %{@str_candidate_key => candidate} -> candidate
      %{"candidate" => candidate} -> candidate
      %{candidate: candidate} -> candidate
      other -> other
    end

    unwrapped_candidates = Enum.map(result.candidates, unwrap)
    best_idx = result.best_idx || GEPA.Result.best_idx(result)

    %{
      result
      | candidates: unwrapped_candidates,
        best_candidate: Enum.at(unwrapped_candidates, best_idx)
    }
  end

  defp cache_dir(%Config{engine: %{run_dir: nil}}), do: nil
  defp cache_dir(%Config{engine: %{run_dir: run_dir}}), do: Path.join(run_dir, "fitness_cache")

  defp cache_mode(%Config{engine: engine}) do
    case engine.cache_evaluation do
      false -> :off
      nil -> :off
      :off -> :off
      true -> cache_storage_mode(engine)
      :auto -> cache_storage_mode(engine)
      :memory -> :memory
      :disk -> :disk
      other -> other
    end
  end

  defp cache_storage_mode(%{cache_evaluation_storage: storage, run_dir: nil})
       when storage in [:disk, "disk"] do
    raise ArgumentError, "cache_evaluation_storage=:disk requires engine.run_dir"
  end

  defp cache_storage_mode(%{cache_evaluation_storage: :disk}), do: :disk
  defp cache_storage_mode(%{cache_evaluation_storage: "disk"}), do: :disk
  defp cache_storage_mode(%{cache_evaluation_storage: :memory}), do: :memory
  defp cache_storage_mode(%{cache_evaluation_storage: "memory"}), do: :memory
  defp cache_storage_mode(%{run_dir: nil}), do: :memory
  defp cache_storage_mode(_engine), do: :disk

  defp resolve_num_parallel_proposals(:auto, max_workers, minibatch_size) do
    max(1, div(max_workers, max(1, minibatch_size)))
  end

  defp resolve_num_parallel_proposals("auto", max_workers, minibatch_size) do
    resolve_num_parallel_proposals(:auto, max_workers, minibatch_size)
  end

  defp resolve_num_parallel_proposals(value, _max_workers, _minibatch_size)
       when is_integer(value) and value >= 1,
       do: value

  defp resolve_num_parallel_proposals(_value, _max_workers, _minibatch_size), do: 1

  defp maybe_inject_refiner_prompt(seed_candidate, %Config{refiner: %{enabled: true}} = config) do
    Map.put_new(seed_candidate, "refiner_prompt", refiner_prompt(config))
  end

  defp maybe_inject_refiner_prompt(seed_candidate, _config), do: seed_candidate

  defp refiner_prompt(%Config{refiner: %{refiner_prompt: prompt}}) when is_binary(prompt),
    do: prompt

  defp refiner_prompt(config) do
    @default_refiner_prompt
    |> String.replace("{objective}", config.objective || "Maximize the score")
    |> String.replace("{background}", config.background || "No additional background provided.")
  end
end
