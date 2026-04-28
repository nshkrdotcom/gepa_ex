defmodule GEPA.Adapters.Confidence do
  @moduledoc """
  Logprob-aware classification adapter.

  This ports the upstream ConfidenceAdapter concept while keeping the Elixir
  adapter mechanism.  The adapter asks a model for structured JSON, extracts a
  target field, checks correctness against `:answer`, and optionally applies a
  confidence penalty using joint field logprob metadata.

  The optional `:logprob_extractor` seam lets tests or provider-specific code
  supply logprob data without depending on a Python package.  It may return:

    * a number joint logprob
    * `%{joint_logprob: number, top_logprobs: list}`
    * `%{"joint_logprob" => number, "top_logprobs" => list}`
  """

  @behaviour GEPA.Adapter

  alias GEPA.Adapters.Confidence.Scoring
  alias GEPA.Adapters.Confidence.Scoring.LinearBlend

  defstruct [
    :model,
    :field_path,
    :schema,
    :prompt_template,
    :logprob_extractor,
    :normalizer,
    scoring_strategy: LinearBlend.new(),
    failure_score: 0.0
  ]

  @type data_inst :: map()
  @type t :: %__MODULE__{
          model: term(),
          field_path: String.t() | [String.t() | atom()],
          schema: map() | keyword() | nil,
          prompt_template: String.t() | nil,
          logprob_extractor: function() | nil,
          normalizer: function() | nil,
          scoring_strategy: term(),
          failure_score: float()
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      model: Map.fetch!(opts, :model),
      field_path: Map.get(opts, :field_path, "answer"),
      schema: Map.get(opts, :schema),
      prompt_template: Map.get(opts, :prompt_template),
      logprob_extractor: Map.get(opts, :logprob_extractor),
      normalizer: Map.get(opts, :normalizer),
      scoring_strategy: Map.get(opts, :scoring_strategy, LinearBlend.new()),
      failure_score: Map.get(opts, :failure_score, 0.0) * 1.0
    }
  end

  @impl true
  def evaluate(%__MODULE__{} = adapter, batch, candidate, capture_traces) do
    results = Enum.map(batch, &evaluate_one(adapter, &1, candidate))

    {:ok,
     %GEPA.EvaluationBatch{
       outputs: Enum.map(results, & &1.output),
       scores: Enum.map(results, & &1.score),
       objective_scores: Enum.map(results, & &1.objective_scores),
       trajectories: if(capture_traces, do: Enum.map(results, & &1.trajectory)),
       num_metric_calls: length(batch)
     }}
  end

  @impl true
  def make_reflective_dataset(%__MODULE__{}, _candidate, eval_batch, components_to_update) do
    trajectories = eval_batch.trajectories || []

    if trajectories == [] do
      {:error, :missing_trajectories}
    else
      dataset = Map.new(components_to_update, &{&1, build_rows(trajectories)})
      {:ok, dataset}
    end
  end

  defp build_rows(trajectories) do
    Enum.map(trajectories, fn trace ->
      %{
        "Inputs" => Map.take(trace, [:input, :additional_context]),
        "Generated Outputs" => trace.output,
        "Feedback" => build_feedback(trace),
        "Scores" => trace.objective_scores
      }
    end)
  end

  @doc "Extract a nested field from a decoded JSON map."
  @spec extract_answer_from_json(map(), String.t() | [String.t() | atom()]) :: term()
  def extract_answer_from_json(decoded, field_path) when is_binary(field_path) do
    decoded
    |> extract_answer_from_json(String.split(field_path, "."))
  end

  def extract_answer_from_json(decoded, field_path) when is_list(field_path) do
    Enum.reduce_while(field_path, decoded, fn key, acc ->
      value = get_any(acc, [key, to_string(key), safe_atom(key)])

      if is_nil(value), do: {:halt, nil}, else: {:cont, value}
    end)
  end

  @doc "Build human-readable feedback for reflection."
  @spec build_feedback(map()) :: String.t()
  def build_feedback(trace) do
    prediction = Map.get(trace, :prediction)
    expected = Map.get(trace, :expected)
    probability = Map.get(trace, :probability)
    correct? = Map.get(trace, :correct?)

    confidence_text =
      if is_number(probability) do
        " Confidence probability for the target field was #{Float.round(probability, 4)}."
      else
        " Confidence metadata was unavailable."
      end

    if correct? do
      "Correct prediction #{inspect(prediction)} matched expected #{inspect(expected)}." <>
        confidence_text
    else
      "Incorrect prediction #{inspect(prediction)}. Expected #{inspect(expected)}." <>
        confidence_text
    end
  end

  defp evaluate_one(%__MODULE__{} = adapter, example, candidate) do
    prompt = render_prompt(adapter, example, candidate)

    with {:ok, raw_text} <- call_model(adapter.model, prompt, adapter.schema),
         {:ok, decoded} <- decode_json(raw_text) do
      prediction = extract_answer_from_json(decoded, adapter.field_path)
      expected = get_any(example, [:answer, "answer", :expected, "expected"])
      correct? = normalize(adapter, prediction) == normalize(adapter, expected)
      confidence = extract_logprob(adapter, raw_text, decoded, example, candidate)
      logprob = Map.get(confidence, :joint_logprob)
      probability = Scoring.probability(logprob)
      score = Scoring.score(adapter.scoring_strategy, correct?, logprob)

      objective_scores = %{
        "accuracy" => if(correct?, do: 1.0, else: 0.0),
        "confidence_adjusted_accuracy" => score
      }

      objective_scores =
        if is_number(probability) do
          Map.put(objective_scores, "probability", probability)
        else
          objective_scores
        end

      output = %{
        full_response: raw_text,
        decoded: decoded,
        prediction: prediction,
        expected: expected
      }

      trajectory = %{
        input: get_any(example, [:input, "input", :query, "query"]),
        additional_context: get_any(example, [:additional_context, "additional_context"]),
        output: output,
        prediction: prediction,
        expected: expected,
        correct?: correct?,
        joint_logprob: logprob,
        probability: probability,
        top_logprobs: Map.get(confidence, :top_logprobs, []),
        score: score,
        objective_scores: objective_scores
      }

      %{output: output, score: score, objective_scores: objective_scores, trajectory: trajectory}
    else
      {:error, reason} ->
        failure_result(adapter, example, reason)
    end
  end

  defp failure_result(%__MODULE__{} = adapter, example, reason) do
    trajectory = %{
      input: get_any(example, [:input, "input", :query, "query"]),
      expected: get_any(example, [:answer, "answer", :expected, "expected"]),
      output: nil,
      error: inspect(reason),
      correct?: false,
      score: adapter.failure_score,
      objective_scores: %{
        "accuracy" => 0.0,
        "confidence_adjusted_accuracy" => adapter.failure_score
      }
    }

    %{
      output: %{error: inspect(reason)},
      score: adapter.failure_score,
      objective_scores: trajectory.objective_scores,
      trajectory: trajectory
    }
  end

  defp render_prompt(%__MODULE__{} = adapter, example, candidate) do
    first_component = candidate |> Map.values() |> List.first()

    system_prompt =
      Map.get(candidate, "system_prompt") || Map.get(candidate, "instruction") ||
        first_component || "Classify the input."

    input = get_any(example, [:input, "input", :query, "query"]) || inspect(example)
    additional_context = get_any(example, [:additional_context, "additional_context"]) || %{}

    template =
      adapter.prompt_template ||
        """
        {system_prompt}

        Input:
        {input}

        Additional context:
        {additional_context}

        Return a JSON object that includes the field #{inspect(adapter.field_path)}.
        """

    template
    |> String.replace("{system_prompt}", to_string(system_prompt))
    |> String.replace("{input}", to_string(input))
    |> String.replace("{additional_context}", inspect(additional_context, pretty: true))
  end

  defp call_model(model, prompt, schema) do
    case schema do
      nil -> GEPA.LLM.complete(model, prompt)
      schema -> GEPA.LLM.complete_structured(model, prompt, schema: schema)
    end
    |> case do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:ok, %{} = object} -> {:ok, Jason.encode!(object)}
      other -> other
    end
  end

  defp decode_json(text) when is_binary(text) do
    text
    |> strip_code_fence()
    |> Jason.decode()
  end

  defp strip_code_fence(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "```") do
      trimmed
      |> String.replace(~r/^```\S*\n?/, "", global: false)
      |> String.replace(~r/```$/, "", global: false)
      |> String.trim()
    else
      trimmed
    end
  end

  defp extract_logprob(%__MODULE__{logprob_extractor: nil}, _raw, _decoded, _example, _candidate),
    do: %{}

  defp extract_logprob(
         %__MODULE__{logprob_extractor: extractor},
         raw,
         decoded,
         example,
         candidate
       ) do
    case Function.info(extractor, :arity) do
      {:arity, 5} -> extractor.(raw, decoded, example, candidate, %{})
      {:arity, 4} -> extractor.(raw, decoded, example, candidate)
      {:arity, 2} -> extractor.(raw, decoded)
      {:arity, 1} -> extractor.(decoded)
    end
    |> normalize_logprob()
  rescue
    _ -> %{}
  end

  defp normalize_logprob(value) when is_number(value),
    do: %{joint_logprob: value * 1.0, top_logprobs: []}

  defp normalize_logprob(%{} = value) do
    %{
      joint_logprob: get_any(value, [:joint_logprob, "joint_logprob", :logprob, "logprob"]),
      top_logprobs: get_any(value, [:top_logprobs, "top_logprobs"]) || []
    }
  end

  defp normalize_logprob(_), do: %{}

  defp normalize(%__MODULE__{normalizer: normalizer}, value) when is_function(normalizer, 1),
    do: normalizer.(value)

  defp normalize(_adapter, value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize(_adapter, value), do: value

  defp get_any(nil, _keys), do: nil

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp get_any(_other, _keys), do: nil

  defp safe_atom(value) when is_atom(value), do: value

  defp safe_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp safe_atom(_), do: nil
end
