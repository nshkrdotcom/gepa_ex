defmodule GEPA.Adapters.GenericRAG.Pipeline do
  @moduledoc """
  A small, adapter-local RAG pipeline used by `GEPA.Adapters.GenericRAG`.

  Candidate components are plain text templates. Supported placeholders:
  `{query}`, `{documents}`, `{context}`, and `{metadata}`.
  """

  alias GEPA.Adapters.GenericRAG.VectorStore

  defstruct [
    :vector_store,
    :llm,
    :llm_client,
    :embedding_model,
    :embedding_function,
    config: %{}
  ]

  @type t :: %__MODULE__{
          vector_store: term(),
          llm: term(),
          llm_client: term(),
          embedding_model: String.t(),
          embedding_function: (String.t() -> [number()]),
          config: map()
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    llm =
      get_any(opts, [
        :llm,
        "llm",
        :llm_client,
        "llm_client",
        :model,
        "model",
        :llm_model,
        "llm_model"
      ])

    %__MODULE__{
      vector_store: fetch_any!(opts, [:vector_store, "vector_store"]),
      llm: llm,
      llm_client: llm,
      embedding_model:
        get_any(opts, [:embedding_model, "embedding_model"]) || "text-embedding-3-small",
      embedding_function:
        get_any(opts, [:embedding_function, "embedding_function"]) ||
          (&__MODULE__.default_embedding_function/1),
      config: get_any(opts, [:config, "config"]) || %{}
    }
  end

  @doc "Execute a RAG pipeline using explicit query, prompt, and config arguments."
  @spec execute_rag(t(), String.t(), map(), map()) :: map()
  def execute_rag(%__MODULE__{} = pipeline, query, prompts, config) do
    pipeline
    |> Map.put(:config, config || %{})
    |> run(%{"query" => query}, stringify_prompts(prompts || %{}))
    |> then(fn result -> Map.put(result, :metadata, result.execution_metadata) end)
  end

  @spec run(t(), map(), map()) :: map()
  def run(%__MODULE__{} = pipeline, example, candidate) do
    query = get_any(example, [:query, "query", :input, "input"]) |> to_string()
    metadata = get_any(example, [:metadata, "metadata"]) || %{}

    reformulated_query =
      candidate
      |> Map.get("query_reformulation")
      |> case do
        nil -> query
        template -> reformulate_query(pipeline, query, template, metadata)
      end

    retrieved_docs = retrieve(pipeline, reformulated_query, example)
    documents_text = format_documents(retrieved_docs)

    context =
      candidate
      |> Map.get("context_synthesis")
      |> case do
        nil ->
          documents_text

        template ->
          render_template(template, %{
            query: reformulated_query,
            documents: documents_text,
            metadata: metadata
          })
      end

    generated_answer =
      generate_answer(
        pipeline,
        reformulated_query,
        context,
        Map.get(candidate, "answer_generation", default_generation_prompt()),
        documents_text,
        metadata
      )

    result = %{
      original_query: query,
      reformulated_query: reformulated_query,
      retrieved_docs: retrieved_docs,
      synthesized_context: context,
      generated_answer: generated_answer,
      execution_metadata: %{
        retrieval_strategy: config_get(pipeline.config, :retrieval_strategy, "similarity"),
        top_k: config_get(pipeline.config, :top_k, 5),
        retrieval_count: length(retrieved_docs),
        total_tokens: estimate_token_count(context <> generated_answer),
        vector_store_type: vector_store_type(pipeline.vector_store)
      }
    }

    Map.put(result, :metadata, result.execution_metadata)
  end

  @doc "Reformulate a query with a prompt template."
  @spec reformulate_query(t(), String.t(), String.t()) :: String.t()
  def reformulate_query(%__MODULE__{} = pipeline, query, prompt) do
    reformulate_query(pipeline, query, prompt, %{})
  end

  @doc "Retrieve documents for a query under the provided config."
  @spec retrieve_documents(t(), String.t(), map()) :: [map()]
  def retrieve_documents(%__MODULE__{} = pipeline, query, config) do
    pipeline
    |> Map.put(:config, config || %{})
    |> retrieve(query, %{})
  end

  @doc "Generate an answer from query, context, and a prompt template."
  @spec generate_answer(t(), String.t(), String.t(), String.t()) :: String.t()
  def generate_answer(%__MODULE__{} = pipeline, query, context, prompt) do
    generate_answer(pipeline, query, context, prompt, context, %{})
  end

  @doc "Deterministic fallback embedding function used when no custom embedding function is supplied."
  @spec default_embedding_function(String.t()) :: [float()]
  def default_embedding_function(_text), do: List.duplicate(0.0, 384)

  @spec render_template(String.t(), map()) :: String.t()
  def render_template(template, vars) do
    Enum.reduce(vars, template, fn {key, value}, acc ->
      String.replace(acc, "{#{key}}", stringify(value))
    end)
  end

  @spec format_documents([map()]) :: String.t()
  def format_documents(docs) do
    docs
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {doc, idx} ->
      metadata = get_any(doc, [:metadata, "metadata"]) || %{}
      content = get_any(doc, [:content, "content", :text, "text"]) || inspect(doc)
      "[Document #{idx}]\nMetadata: #{inspect(metadata)}\n#{content}"
    end)
  end

  defp retrieve(%__MODULE__{} = pipeline, query, example) do
    strategy = config_get(pipeline.config, :retrieval_strategy, "similarity")
    top_k = config_get(pipeline.config, :top_k, 5)

    filters =
      get_any(example, [:filters, "filters"]) || config_get(pipeline.config, :filters, nil)

    case to_string(strategy) do
      "vector" ->
        VectorStore.vector_search(pipeline.vector_store, embed(pipeline, query), top_k, filters)

      "hybrid" ->
        VectorStore.hybrid_search(
          pipeline.vector_store,
          query,
          top_k,
          config_get(pipeline.config, :hybrid_alpha, config_get(pipeline.config, :alpha, 0.5))
        )

      _ ->
        VectorStore.similarity_search(pipeline.vector_store, query, top_k, filters)
    end
  end

  defp reformulate_query(_pipeline, query, prompt, _metadata)
       when is_nil(prompt) or prompt == "" do
    query
  end

  defp reformulate_query(%__MODULE__{} = pipeline, query, prompt, metadata) do
    prompt
    |> render_template(%{query: query, metadata: metadata})
    |> then(&complete(pipeline.llm, &1))
    |> non_empty_or(query)
  end

  defp generate_answer(
         %__MODULE__{} = pipeline,
         query,
         context,
         prompt,
         documents_text,
         metadata
       ) do
    prompt =
      if is_nil(prompt) or prompt == "" do
        default_generation_prompt()
      else
        prompt
      end

    prompt
    |> render_template(%{
      query: query,
      context: context,
      documents: documents_text,
      metadata: metadata
    })
    |> then(&complete(pipeline.llm, &1))
    |> non_empty_or("I couldn't generate an answer based on the provided context.")
  end

  defp default_generation_prompt do
    "Answer the query using the context.\n\nQuery: {query}\n\nContext:\n{context}"
  end

  defp complete(nil, prompt), do: prompt

  defp complete(model, prompt) do
    case GEPA.LLM.complete(model, prompt) do
      {:ok, text} -> text
      {:error, reason} -> "LLM error: #{inspect(reason)}"
    end
  end

  defp embed(%__MODULE__{embedding_function: embedding_function}, query)
       when is_function(embedding_function, 1) do
    embedding_function.(to_string(query))
  rescue
    _exception -> default_embedding_function(to_string(query))
  end

  defp embed(_pipeline, query), do: default_embedding_function(to_string(query))

  defp non_empty_or(value, fallback) do
    value = to_string(value)
    if String.trim(value) == "", do: fallback, else: value
  end

  defp stringify_prompts(prompts) when is_map(prompts) do
    Map.new(prompts, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp stringify(%{} = map), do: inspect(map, pretty: true)
  defp stringify(list) when is_list(list), do: inspect(list, pretty: true)
  defp stringify(value), do: to_string(value)

  defp estimate_token_count(text), do: div(String.length(to_string(text)), 4)

  defp vector_store_type(store) do
    collection_info = VectorStore.get_collection_info(store)
    get_any(collection_info, [:vector_store_type, "vector_store_type"]) || "unknown"
  rescue
    _exception -> "unknown"
  end

  defp config_get(config, key, default) do
    Map.get(config, key, Map.get(config, to_string(key), default))
  end

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
end
