defmodule GEPA.Adapters.GenericRAG.Pipeline do
  @moduledoc """
  A small, adapter-local RAG pipeline used by `GEPA.Adapters.GenericRAG`.

  Candidate components are plain text templates. Supported placeholders:
  `{query}`, `{documents}`, `{context}`, and `{metadata}`.
  """

  alias GEPA.Adapters.GenericRAG.VectorStore

  defstruct [:vector_store, :llm, config: %{}]

  @type t :: %__MODULE__{vector_store: term(), llm: term(), config: map()}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      vector_store: Map.fetch!(opts, :vector_store),
      llm: Map.get(opts, :llm) || Map.get(opts, :model) || Map.get(opts, :llm_model),
      config: Map.get(opts, :config, %{})
    }
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
        template -> render_template(template, %{query: query, metadata: metadata})
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

    answer_prompt =
      candidate
      |> Map.get(
        "answer_generation",
        "Answer the query using the context.\n\nQuery: {query}\n\nContext:\n{context}"
      )
      |> render_template(%{
        query: reformulated_query,
        context: context,
        documents: documents_text,
        metadata: metadata
      })

    generated_answer = complete(pipeline.llm, answer_prompt)

    %{
      original_query: query,
      reformulated_query: reformulated_query,
      retrieved_docs: retrieved_docs,
      synthesized_context: context,
      generated_answer: generated_answer,
      execution_metadata: %{
        retrieval_strategy: config_get(pipeline.config, :retrieval_strategy, "similarity"),
        top_k: config_get(pipeline.config, :top_k, 5)
      }
    }
  end

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
        VectorStore.vector_search(pipeline.vector_store, embed(query), top_k, filters)

      "hybrid" ->
        VectorStore.hybrid_search(
          pipeline.vector_store,
          query,
          top_k,
          config_get(pipeline.config, :alpha, 0.5)
        )

      _ ->
        VectorStore.similarity_search(pipeline.vector_store, query, top_k, filters)
    end
  end

  defp complete(nil, prompt), do: prompt

  defp complete(model, prompt) do
    case GEPA.LLM.complete(model, prompt) do
      {:ok, text} -> text
      {:error, reason} -> "LLM error: #{inspect(reason)}"
    end
  end

  defp embed(query) do
    query
    |> to_string()
    |> String.to_charlist()
    |> Enum.map(&(&1 / 255.0))
  end

  defp stringify(%{} = map), do: inspect(map, pretty: true)
  defp stringify(list) when is_list(list), do: inspect(list, pretty: true)
  defp stringify(value), do: to_string(value)

  defp config_get(config, key, default) do
    Map.get(config, key, Map.get(config, to_string(key), default))
  end

  defp get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp get_any(_other, _keys), do: nil
end
