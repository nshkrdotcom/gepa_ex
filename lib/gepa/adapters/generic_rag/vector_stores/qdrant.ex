defmodule GEPA.Adapters.GenericRAG.VectorStores.Qdrant do
  @moduledoc """
  Qdrant HTTP vector-store adapter for Generic RAG.

  This module intentionally uses Qdrant's HTTP API directly. The behaviour
  surface keeps the implementation replaceable by a dedicated client library or
  a larger vector subsystem later.
  """

  @behaviour GEPA.Adapters.GenericRAG.VectorStore

  defstruct [
    :api_key,
    :embedder,
    :vector_size,
    url: "http://localhost:6333",
    collection_name: "gepa_documents",
    distance: "Cosine",
    timeout: 60_000,
    req_options: []
  ]

  @type t :: %__MODULE__{
          url: String.t(),
          collection_name: String.t(),
          api_key: String.t() | nil,
          embedder: GEPA.Embeddings.provider() | nil,
          vector_size: pos_integer() | nil,
          distance: String.t(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  @doc "Build a Qdrant vector store."
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      url: Map.get(opts, :url, Map.get(opts, "url", "http://localhost:6333")),
      collection_name:
        Map.get(opts, :collection_name, Map.get(opts, "collection_name", "gepa_documents")),
      api_key: Map.get(opts, :api_key, Map.get(opts, "api_key")),
      embedder: Map.get(opts, :embedder, Map.get(opts, "embedder")),
      vector_size: Map.get(opts, :vector_size, Map.get(opts, "vector_size")),
      distance: Map.get(opts, :distance, Map.get(opts, "distance", "Cosine")),
      timeout: Map.get(opts, :timeout, Map.get(opts, "timeout", 60_000)),
      req_options: Map.get(opts, :req_options, Map.get(opts, "req_options", []))
    }
  end

  @impl true
  def health_check(%__MODULE__{} = store) do
    case request(store, :get, "/collections") do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_collection(%__MODULE__{} = store, opts \\ []) do
    with {:ok, vector_size} <- collection_dimension(store, opts),
         {:ok, _body} <-
           request(store, :put, "/collections/#{store.collection_name}", %{
             "vectors" => %{"size" => vector_size, "distance" => store.distance}
           }) do
      :ok
    end
  end

  @impl true
  def reset_collection(%__MODULE__{} = store, opts \\ []) do
    case request(store, :delete, "/collections/#{store.collection_name}") do
      {:ok, _body} -> create_collection(store, opts)
      {:error, {:http_error, 404, _body}} -> create_collection(store, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def upsert_documents(%__MODULE__{} = store, documents, opts \\ []) when is_list(documents) do
    with {:ok, docs_with_embeddings} <- attach_embeddings(store, documents, opts),
         {:ok, points} <- build_points(docs_with_embeddings),
         {:ok, _body} <-
           request(store, :put, "/collections/#{store.collection_name}/points?wait=true", %{
             "points" => points
           }) do
      {:ok, Enum.map(points, & &1["payload"]["original_id"])}
    end
  end

  @impl true
  def delete_documents(%__MODULE__{} = store, ids, _opts \\ []) when is_list(ids) do
    with {:ok, _body} <-
           request(
             store,
             :post,
             "/collections/#{store.collection_name}/points/delete?wait=true",
             %{
               "points" => Enum.map(ids, &point_id/1)
             }
           ) do
      :ok
    end
  end

  @impl true
  def similarity_search(%__MODULE__{} = store, query, k, filters) do
    with {:ok, vector} <- embed_query(store, query) do
      vector_search(store, vector, k, filters)
    end
  end

  @impl true
  def vector_search(%__MODULE__{} = store, query_vector, k, filters) do
    body =
      %{
        "vector" => Enum.map(query_vector, &(&1 * 1.0)),
        "limit" => k,
        "with_payload" => true,
        "with_vector" => false
      }
      |> maybe_put_filter(filters)

    with {:ok, body} <-
           request(store, :post, "/collections/#{store.collection_name}/points/search", body) do
      {:ok, parse_search_results(body)}
    end
  end

  def hybrid_search(%__MODULE__{} = store, query, k, _alpha) do
    similarity_search(store, query, k, nil)
  end

  @impl true
  def get_collection_info(%__MODULE__{} = store) do
    case request(store, :get, "/collections/#{store.collection_name}") do
      {:ok, %{"result" => result}} ->
        %{
          "name" => store.collection_name,
          "document_count" => result["points_count"] || 0,
          "vector_store_type" => "qdrant",
          "embedding_dimension" => result_embedding_dimension(result)
        }

      {:ok, _body} ->
        %{
          "name" => store.collection_name,
          "document_count" => 0,
          "vector_store_type" => "qdrant",
          "embedding_dimension" => store.vector_size
        }

      {:error, reason} ->
        %{
          "name" => store.collection_name,
          "document_count" => 0,
          "vector_store_type" => "qdrant",
          "embedding_dimension" => store.vector_size,
          "error" => inspect(reason)
        }
    end
  end

  @impl true
  def embedding_dimension(%__MODULE__{} = store), do: store.vector_size

  @impl true
  def supports_hybrid_search?(%__MODULE__{}), do: false

  @impl true
  def supports_metadata_filtering?(%__MODULE__{}), do: true

  defp collection_dimension(%__MODULE__{} = store, opts) do
    dimension =
      get_opt(opts, :vector_size) ||
        get_opt(opts, :embedding_dimension) ||
        store.vector_size ||
        if(store.embedder, do: GEPA.Embeddings.dimensions(store.embedder))

    case dimension do
      value when is_integer(value) and value > 0 -> {:ok, value}
      nil -> {:error, :missing_vector_size}
      value -> {:error, {:invalid_vector_size, value}}
    end
  end

  defp attach_embeddings(%__MODULE__{} = store, documents, opts) do
    documents = Enum.map(documents, &normalize_document/1)
    missing = Enum.filter(documents, &(is_nil(&1.embedding) or &1.embedding == []))

    cond do
      missing == [] ->
        {:ok, documents}

      is_nil(store.embedder) ->
        {:error, :missing_embedder}

      true ->
        texts = Enum.map(missing, & &1.content)

        with {:ok, embeddings} <-
               GEPA.Embeddings.embed_batch(store.embedder, texts, List.wrap(opts)) do
          merge_embeddings(documents, embeddings)
        end
    end
  end

  defp merge_embeddings(documents, embeddings) do
    {merged, []} =
      Enum.map_reduce(documents, embeddings, fn
        %{embedding: embedding} = doc, remaining when is_list(embedding) and embedding != [] ->
          {doc, remaining}

        doc, [embedding | remaining] ->
          {%{doc | embedding: embedding}, remaining}
      end)

    {:ok, merged}
  rescue
    _error -> {:error, :embedding_count_mismatch}
  end

  defp build_points(documents) do
    documents
    |> Enum.reduce_while({:ok, []}, fn doc, {:ok, acc} ->
      case doc.embedding do
        embedding when is_list(embedding) and embedding != [] ->
          point = %{
            "id" => point_id(doc.id),
            "vector" => Enum.map(embedding, &(&1 * 1.0)),
            "payload" => %{
              "original_id" => doc.id,
              "content" => doc.content,
              "metadata" => doc.metadata
            }
          }

          {:cont, {:ok, [point | acc]}}

        _embedding ->
          {:halt, {:error, {:missing_embedding, doc.id}}}
      end
    end)
    |> case do
      {:ok, points} -> {:ok, Enum.reverse(points)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_document(%{} = doc) do
    id = Map.get(doc, :id) || Map.get(doc, "id") || document_id(doc)

    %{
      id: to_string(id),
      content:
        to_string(
          Map.get(doc, :content) || Map.get(doc, "content") || Map.get(doc, :text) ||
            Map.get(doc, "text") || ""
        ),
      metadata: Map.get(doc, :metadata) || Map.get(doc, "metadata") || %{},
      embedding:
        Map.get(doc, :embedding) || Map.get(doc, "embedding") || Map.get(doc, :vector) ||
          Map.get(doc, "vector")
    }
  end

  defp embed_query(%__MODULE__{embedder: nil}, _query), do: {:error, :missing_embedder}

  defp embed_query(%__MODULE__{} = store, query) do
    GEPA.Embeddings.embed(store.embedder, to_string(query))
  end

  defp parse_search_results(%{"result" => results}) when is_list(results) do
    Enum.map(results, &search_result_to_document/1)
  end

  defp parse_search_results(%{"result" => %{"points" => results}}) when is_list(results) do
    Enum.map(results, &search_result_to_document/1)
  end

  defp parse_search_results(_body), do: []

  defp search_result_to_document(%{"payload" => payload, "score" => score})
       when is_map(payload) do
    %{
      id: payload["original_id"],
      content: payload["content"],
      metadata: payload["metadata"] || %{},
      score: score
    }
  end

  defp search_result_to_document(other), do: %{content: inspect(other), metadata: %{}}

  defp maybe_put_filter(body, nil), do: body
  defp maybe_put_filter(body, filters) when filters == %{}, do: body

  defp maybe_put_filter(body, filters) when is_map(filters) do
    case qdrant_filter(filters) do
      nil -> body
      filter -> Map.put(body, "filter", filter)
    end
  end

  defp qdrant_filter(filters) do
    must =
      filters
      |> Enum.map(&qdrant_condition/1)
      |> Enum.reject(&is_nil/1)

    if must == [], do: nil, else: %{"must" => must}
  end

  defp qdrant_condition({key, %{} = operators}) do
    field = metadata_field(key)

    cond do
      Map.has_key?(operators, "$in") or Map.has_key?(operators, :"$in") ->
        %{"key" => field, "match" => %{"any" => operator_value(operators, "$in")}}

      range = qdrant_range(operators) ->
        %{"key" => field, "range" => range}

      true ->
        nil
    end
  end

  defp qdrant_condition({key, value}) do
    %{"key" => metadata_field(key), "match" => %{"value" => value}}
  end

  defp qdrant_range(operators) do
    [
      gt: operator_value(operators, "$gt"),
      gte: operator_value(operators, "$gte"),
      lt: operator_value(operators, "$lt"),
      lte: operator_value(operators, "$lte")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      empty when empty == %{} -> nil
      range -> range
    end
  end

  defp operator_value(operators, key) do
    Map.get(operators, key) || Map.get(operators, operator_atom(key))
  end

  defp operator_atom("$gt"), do: :"$gt"
  defp operator_atom("$gte"), do: :"$gte"
  defp operator_atom("$lt"), do: :"$lt"
  defp operator_atom("$lte"), do: :"$lte"
  defp operator_atom("$in"), do: :"$in"

  defp metadata_field(key), do: "metadata.#{key}"

  defp request(%__MODULE__{} = store, method, path, body \\ nil) do
    opts =
      [
        url: store.url |> String.trim_trailing("/") |> Kernel.<>(path),
        headers: headers(store),
        receive_timeout: store.timeout
      ]
      |> maybe_add_json(body)
      |> Keyword.merge(store.req_options)

    case apply(Req, method, [opts]) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body || %{}}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_json(opts, nil), do: opts
  defp maybe_add_json(opts, body), do: Keyword.put(opts, :json, body)

  defp headers(%__MODULE__{api_key: nil}), do: []
  defp headers(%__MODULE__{api_key: api_key}), do: [{"api-key", api_key}]

  defp result_embedding_dimension(%{"config" => %{"params" => %{"vectors" => %{"size" => size}}}}),
    do: size

  defp result_embedding_dimension(_result), do: nil

  defp document_id(doc), do: :erlang.phash2(doc)

  defp point_id(id), do: :erlang.phash2(to_string(id), 2_147_483_647)

  defp get_opt(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp get_opt(opts, key), do: Keyword.get(opts, key)
end
