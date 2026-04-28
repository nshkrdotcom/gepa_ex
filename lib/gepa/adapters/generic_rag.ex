defmodule GEPA.Adapters.GenericRAG.DataInst do
  @moduledoc "Task instance for the Generic RAG adapter."
  defstruct query: nil,
            ground_truth_answer: nil,
            relevant_doc_ids: [],
            metadata: %{},
            filters: nil
end

defmodule GEPA.Adapters.GenericRAG do
  @moduledoc """
  Vector-store-agnostic RAG adapter.

  Candidate components optimized by GEPA include:

    * `query_reformulation`
    * `context_synthesis`
    * `answer_generation`
    * `reranking_criteria` (reserved for custom pipelines)

  The adapter uses deterministic retrieval/generation metrics so it can be
  tested without hosted services, while still allowing any `GEPA.LLM` model for
  answer generation.
  """

  @behaviour GEPA.Adapter

  alias GEPA.Adapters.GenericRAG.{Metrics, Pipeline}

  defstruct [:vector_store, :llm_model, :pipeline, config: %{}, failure_score: 0.0]

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)
    config = Map.get(opts, :rag_config, Map.get(opts, :config, %{}))
    vector_store = Map.fetch!(opts, :vector_store)
    llm = Map.get(opts, :llm) || Map.get(opts, :llm_model) || Map.get(opts, :model)

    pipeline =
      Map.get(opts, :pipeline) ||
        Pipeline.new(vector_store: vector_store, llm: llm, config: config)

    %__MODULE__{
      vector_store: vector_store,
      llm_model: llm,
      pipeline: pipeline,
      config: config,
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
  def make_reflective_dataset(_adapter, _candidate, eval_batch, components_to_update) do
    trajectories = eval_batch.trajectories || []

    if trajectories == [] do
      {:error, :missing_trajectories}
    else
      dataset = Map.new(components_to_update, &{&1, build_rows_for_component(&1, trajectories)})
      {:ok, dataset}
    end
  end

  defp build_rows_for_component(component, trajectories) do
    Enum.map(trajectories, fn trace ->
      %{
        "Inputs" => %{"query" => trace.original_query},
        "Generated Outputs" => %{
          "reformulated_query" => trace.reformulated_query,
          "context" => trace.synthesized_context,
          "answer" => trace.generated_answer
        },
        "Feedback" => feedback_for_component(component, trace),
        "Scores" => trace.objective_scores
      }
    end)
  end

  defp evaluate_one(%__MODULE__{} = adapter, example, candidate) do
    trace =
      Pipeline.run(adapter.pipeline, normalize_example(example), stringify_candidate(candidate))

    retrieval_metrics =
      Metrics.evaluate_retrieval(
        trace.retrieved_docs,
        get_any(example, [:relevant_doc_ids, "relevant_doc_ids"]) || []
      )

    generation_metrics =
      Metrics.evaluate_generation(
        trace.generated_answer,
        get_any(example, [:ground_truth_answer, "ground_truth_answer", :answer, "answer"]) ||
          "",
        trace.synthesized_context
      )

    score =
      Metrics.combined_rag_score(retrieval_metrics, generation_metrics,
        retrieval_weight: config_get(adapter.config, :retrieval_weight, 0.3),
        generation_weight: config_get(adapter.config, :generation_weight, 0.7)
      )

    objective_scores = Map.merge(retrieval_metrics, generation_metrics)

    trajectory =
      trace
      |> Map.put(:score, score)
      |> Map.put(:objective_scores, objective_scores)
      |> Map.put(
        :ground_truth_answer,
        get_any(example, [:ground_truth_answer, "ground_truth_answer", :answer, "answer"])
      )

    %{
      output: trace.generated_answer,
      score: score,
      objective_scores: objective_scores,
      trajectory: trajectory
    }
  rescue
    exception ->
      %{
        output: %{error: Exception.message(exception)},
        score: adapter.failure_score,
        objective_scores: %{"error" => 1.0},
        trajectory: %{
          original_query: get_any(example, [:query, "query", :input, "input"]),
          error: Exception.format(:error, exception, __STACKTRACE__),
          score: adapter.failure_score,
          objective_scores: %{"error" => 1.0}
        }
      }
  end

  defp feedback_for_component("query_reformulation", trace) do
    "Original query: #{trace.original_query}\nReformulated query: #{trace.reformulated_query}\nRetrieval metrics: #{inspect(Map.take(trace.objective_scores, ["retrieval_precision", "retrieval_recall", "retrieval_f1", "retrieval_mrr"]))}"
  end

  defp feedback_for_component("context_synthesis", trace) do
    "Retrieved documents: #{length(trace.retrieved_docs)}\nSynthesized context:\n#{trace.synthesized_context}\nFaithfulness: #{Map.get(trace.objective_scores, "faithfulness")}"
  end

  defp feedback_for_component(_component, trace) do
    "Generated answer: #{trace.generated_answer}\nGround truth: #{trace.ground_truth_answer}\nMetrics: #{inspect(trace.objective_scores)}"
  end

  defp normalize_example(%GEPA.Adapters.GenericRAG.DataInst{} = example),
    do: Map.from_struct(example)

  defp normalize_example(example), do: example

  defp stringify_candidate(candidate) do
    Map.new(candidate, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp get_any(%GEPA.Adapters.GenericRAG.DataInst{} = struct, keys),
    do: struct |> Map.from_struct() |> get_any(keys)

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp get_any(_other, _keys), do: nil

  defp config_get(config, key, default),
    do: Map.get(config, key, Map.get(config, to_string(key), default))
end
