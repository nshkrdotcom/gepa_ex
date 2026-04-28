defmodule GEPA.Adapters.GenericRAG.VectorStore do
  @moduledoc """
  Behaviour for vector-store backends used by `GEPA.Adapters.GenericRAG`.

  Documents are maps with at least `:content`/`"content"` and optional
  `:metadata`/`"metadata"`. Search callbacks may return either a list directly
  or `{:ok, list}`/`{:error, reason}` when the backend performs external IO.
  """

  @type document :: %{optional(String.t() | atom()) => term()}
  @type filters :: map() | nil
  @type search_result :: [document()] | {:ok, [document()]} | {:error, term()}

  @callback similarity_search(term(), String.t(), pos_integer(), filters()) :: search_result()
  @callback vector_search(term(), [number()], pos_integer(), filters()) :: search_result()
  @callback get_collection_info(term()) :: map()
  @callback health_check(term()) :: :ok | {:error, term()}
  @callback create_collection(term(), keyword() | map()) :: :ok | {:error, term()}
  @callback reset_collection(term(), keyword() | map()) :: :ok | {:error, term()}
  @callback upsert_documents(term(), [document()], keyword() | map()) ::
              {:ok, [term()]} | {:error, term()}
  @callback delete_documents(term(), [term()], keyword() | map()) :: :ok | {:error, term()}
  @callback embedding_dimension(term()) :: pos_integer() | nil
  @callback supports_hybrid_search?(term()) :: boolean()
  @callback supports_metadata_filtering?(term()) :: boolean()

  @optional_callbacks health_check: 1,
                      create_collection: 2,
                      reset_collection: 2,
                      upsert_documents: 3,
                      delete_documents: 3,
                      embedding_dimension: 1,
                      supports_hybrid_search?: 1,
                      supports_metadata_filtering?: 1

  @doc "Perform a hybrid search. Defaults to similarity search."
  @spec hybrid_search(term(), String.t(), pos_integer(), float()) :: search_result()
  def hybrid_search(store, query, k \\ 5, alpha \\ 0.5) do
    module = adapter_module(store)

    if module != nil and function_exported?(module, :hybrid_search, 4) do
      module.hybrid_search(store, query, k, alpha)
    else
      similarity_search(store, query, k, nil)
    end
  end

  @spec similarity_search(term(), String.t(), pos_integer(), filters()) :: search_result()
  def similarity_search(store, query, k \\ 5, filters \\ nil) do
    module = adapter_module(store)
    module.similarity_search(store, query, k, filters)
  end

  @spec vector_search(term(), [number()], pos_integer(), filters()) :: search_result()
  def vector_search(store, query_vector, k \\ 5, filters \\ nil) do
    module = adapter_module(store)
    module.vector_search(store, query_vector, k, filters)
  end

  @spec get_collection_info(term()) :: map()
  def get_collection_info(store), do: adapter_module(store).get_collection_info(store)

  @spec health_check(term()) :: :ok | {:error, term()}
  def health_check(store) do
    call_optional(store, :health_check, [store], :ok)
  end

  @spec create_collection(term(), keyword() | map()) :: :ok | {:error, term()}
  def create_collection(store, opts \\ []) do
    call_optional(store, :create_collection, [store, opts], {:error, :unsupported})
  end

  @spec reset_collection(term(), keyword() | map()) :: :ok | {:error, term()}
  def reset_collection(store, opts \\ []) do
    call_optional(store, :reset_collection, [store, opts], {:error, :unsupported})
  end

  @spec upsert_documents(term(), [document()], keyword() | map()) ::
          {:ok, [term()]} | {:error, term()}
  def upsert_documents(store, documents, opts \\ []) do
    call_optional(store, :upsert_documents, [store, documents, opts], {:error, :unsupported})
  end

  @spec delete_documents(term(), [term()], keyword() | map()) :: :ok | {:error, term()}
  def delete_documents(store, ids, opts \\ []) do
    call_optional(store, :delete_documents, [store, ids, opts], {:error, :unsupported})
  end

  @spec embedding_dimension(term()) :: pos_integer() | nil
  def embedding_dimension(store) do
    case call_optional(store, :embedding_dimension, [store], nil) do
      nil ->
        store
        |> get_collection_info()
        |> dimension_from_collection_info()

      dimension ->
        dimension
    end
  rescue
    _exception -> nil
  end

  @spec supports_hybrid_search?(term()) :: boolean()
  def supports_hybrid_search?(store) do
    call_optional(store, :supports_hybrid_search?, [store], false)
  end

  @spec supports_metadata_filtering?(term()) :: boolean()
  def supports_metadata_filtering?(store) do
    call_optional(store, :supports_metadata_filtering?, [store], false)
  end

  defp call_optional(store, function, args, default) do
    module = adapter_module(store)

    if module != nil and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      default
    end
  end

  defp dimension_from_collection_info(info) when is_map(info) do
    Map.get(info, "embedding_dimension") || Map.get(info, :embedding_dimension)
  end

  defp dimension_from_collection_info(_info), do: nil

  defp adapter_module(%module{}), do: module
  defp adapter_module(module) when is_atom(module), do: module
end

defmodule GEPA.Adapters.GenericRAG.VectorStore.InMemory do
  @moduledoc """
  Deterministic in-memory vector-store implementation for tests, examples, and
  local development. Similarity is simple token overlap.
  """

  @behaviour GEPA.Adapters.GenericRAG.VectorStore

  defstruct collection_name: "in_memory", documents: []

  @type t :: %__MODULE__{collection_name: String.t(), documents: [map()]}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      collection_name: Map.get(opts, :collection_name, "in_memory"),
      documents: Map.get(opts, :documents, [])
    }
  end

  @impl true
  def similarity_search(%__MODULE__{} = store, query, k, filters) do
    query_tokens = tokens(query)

    store.documents
    |> Enum.filter(&matches_filters?(&1, filters))
    |> Enum.map(fn doc -> {doc, overlap_score(tokens(content(doc)), query_tokens)} end)
    |> Enum.filter(fn {_doc, score} -> score > 0 end)
    |> Enum.sort_by(fn {_doc, score} -> -score end)
    |> Enum.take(k)
    |> Enum.map(&elem(&1, 0))
  end

  @impl true
  def vector_search(%__MODULE__{} = store, _query_vector, k, filters) do
    store.documents
    |> Enum.filter(&matches_filters?(&1, filters))
    |> Enum.take(k)
  end

  def hybrid_search(%__MODULE__{} = store, query, k, _alpha) do
    similarity_search(store, query, k, nil)
  end

  @impl true
  def health_check(%__MODULE__{}), do: :ok

  @impl true
  def create_collection(%__MODULE__{}, _opts), do: :ok

  @impl true
  def reset_collection(%__MODULE__{}, _opts), do: :ok

  @impl true
  def upsert_documents(%__MODULE__{}, documents, _opts) do
    ids = Enum.map(documents, &(Map.get(&1, :id) || Map.get(&1, "id")))
    {:ok, ids}
  end

  @impl true
  def delete_documents(%__MODULE__{}, _ids, _opts), do: :ok

  @impl true
  def embedding_dimension(%__MODULE__{}), do: 384

  @impl true
  def supports_hybrid_search?(%__MODULE__{}), do: true

  @impl true
  def supports_metadata_filtering?(%__MODULE__{}), do: true

  @impl true
  def get_collection_info(%__MODULE__{} = store) do
    %{
      "name" => store.collection_name,
      "document_count" => length(store.documents),
      "vector_store_type" => "in_memory",
      "embedding_dimension" => 384
    }
  end

  def matches_filters?(_doc, nil), do: true
  def matches_filters?(_doc, filters) when filters == %{}, do: true

  def matches_filters?(doc, filters) when is_map(filters) do
    metadata = metadata(doc)

    Enum.all?(filters, fn {key, value} ->
      case fetch_metadata(metadata, key) do
        {:ok, actual} -> filter_value_matches?(actual, value)
        :error -> false
      end
    end)
  end

  defp fetch_metadata(metadata, key) do
    case Enum.find(metadata, fn {metadata_key, _value} ->
           metadata_key == key or to_string(metadata_key) == to_string(key)
         end) do
      {_metadata_key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp filter_value_matches?(actual, %{} = operators) do
    Enum.all?(operators, fn
      {op, expected} when op in ["$gt", :"$gt"] -> actual > expected
      {op, expected} when op in ["$lt", :"$lt"] -> actual < expected
      {op, expected} when op in ["$gte", :"$gte"] -> actual >= expected
      {op, expected} when op in ["$lte", :"$lte"] -> actual <= expected
      {op, expected} when op in ["$ne", :"$ne"] -> actual != expected
      {op, expected} when op in ["$in", :"$in"] -> actual in List.wrap(expected)
      {_op, _expected} -> false
    end)
  end

  defp filter_value_matches?(actual, expected), do: actual == expected

  defp content(doc), do: Map.get(doc, :content) || Map.get(doc, "content") || ""
  defp metadata(doc), do: Map.get(doc, :metadata) || Map.get(doc, "metadata") || %{}

  defp tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]]+/, trim: true)
    |> MapSet.new()
  end

  defp overlap_score(tokens_a, tokens_b), do: MapSet.size(MapSet.intersection(tokens_a, tokens_b))
end
