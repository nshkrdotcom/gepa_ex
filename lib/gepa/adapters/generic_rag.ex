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

  defstruct [
    :vector_store,
    :llm_model,
    :pipeline,
    :rag_pipeline,
    :evaluator,
    config: %{},
    failure_score: 0.0
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)
    config = get_any(opts, [:rag_config, "rag_config", :config, "config"]) || default_config()
    vector_store = fetch_any!(opts, [:vector_store, "vector_store"])
    llm = get_any(opts, [:llm, "llm", :llm_model, "llm_model", :model, "model"])

    pipeline =
      get_any(opts, [:pipeline, "pipeline", :rag_pipeline, "rag_pipeline"]) ||
        Pipeline.new(vector_store: vector_store, llm: llm, config: config)

    %__MODULE__{
      vector_store: vector_store,
      llm_model: llm,
      pipeline: pipeline,
      rag_pipeline: pipeline,
      evaluator: Metrics,
      config: config,
      failure_score: (get_any(opts, [:failure_score, "failure_score"]) || 0.0) * 1.0
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
    execution_metadata = execution_metadata(trace, retrieval_metrics, generation_metrics, score)

    trajectory =
      trace
      |> Map.put(:execution_metadata, execution_metadata)
      |> Map.put(:score, score)
      |> Map.put(:objective_scores, objective_scores)
      |> Map.put(
        :ground_truth_answer,
        get_any(example, [:ground_truth_answer, "ground_truth_answer", :answer, "answer"])
      )

    %{
      output: rag_output(trace, generation_metrics, execution_metadata),
      score: score,
      objective_scores: objective_scores,
      trajectory: trajectory
    }
  rescue
    exception ->
      error_message = Exception.message(exception)

      %{
        output: %{
          final_answer: "Error: #{error_message}",
          confidence_score: 0.0,
          retrieved_docs: [],
          total_tokens: 0
        },
        score: adapter.failure_score,
        objective_scores: %{"error" => 1.0},
        trajectory: %{
          original_query: get_any(example, [:query, "query", :input, "input"]),
          reformulated_query: get_any(example, [:query, "query", :input, "input"]),
          retrieved_docs: [],
          synthesized_context: "",
          generated_answer: "Error: #{error_message}",
          error: Exception.format(:error, exception, __STACKTRACE__),
          execution_metadata: %{error: error_message},
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

  defp default_config do
    %{
      "retrieval_strategy" => "similarity",
      "top_k" => 5,
      "retrieval_weight" => 0.3,
      "generation_weight" => 0.7,
      "hybrid_alpha" => 0.5,
      "filters" => nil
    }
  end

  defp execution_metadata(trace, retrieval_metrics, generation_metrics, score) do
    trace
    |> Map.get(:execution_metadata, %{})
    |> Map.merge(%{
      retrieval_metrics: retrieval_metrics,
      generation_metrics: generation_metrics,
      overall_score: score
    })
  end

  defp rag_output(trace, generation_metrics, execution_metadata) do
    %{
      final_answer: trace.generated_answer,
      confidence_score: Map.get(generation_metrics, "answer_confidence", 0.5),
      retrieved_docs: trace.retrieved_docs,
      total_tokens:
        Map.get(
          execution_metadata,
          :total_tokens,
          estimate_token_count(trace.synthesized_context <> trace.generated_answer)
        )
    }
  end

  defp estimate_token_count(text), do: div(String.length(to_string(text)), 4)

  defp get_any(%GEPA.Adapters.GenericRAG.DataInst{} = struct, keys),
    do: struct |> Map.from_struct() |> get_any(keys)

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp get_any(_other, _keys), do: nil

  defp fetch_any!(map, keys) do
    case get_any(map, keys) do
      nil -> raise KeyError, key: hd(keys), term: map
      value -> value
    end
  end

  defp config_get(config, key, default),
    do: Map.get(config, key, Map.get(config, to_string(key), default))
end
