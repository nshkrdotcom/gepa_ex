defmodule GEPA.Adapters.GenericRAG.VectorStore do
  @moduledoc """
  Behaviour for vector-store backends used by `GEPA.Adapters.GenericRAG`.

  Documents are maps with at least `:content`/`"content"` and optional
  `:metadata`/`"metadata"`. Backends may be real vector stores or in-memory
  test doubles.
  """

  @type document :: %{optional(String.t() | atom()) => term()}
  @type filters :: map() | nil

  @callback similarity_search(term(), String.t(), pos_integer(), filters()) :: [document()]
  @callback vector_search(term(), [number()], pos_integer(), filters()) :: [document()]
  @callback get_collection_info(term()) :: map()

  @doc "Perform a hybrid search. Defaults to similarity search."
  @spec hybrid_search(term(), String.t(), pos_integer(), float()) :: [document()]
  def hybrid_search(store, query, k \\ 5, _alpha \\ 0.5) do
    module = adapter_module(store)

    cond do
      is_atom(module) and function_exported?(module, :hybrid_search, 4) ->
        module.hybrid_search(store, query, k, 0.5)

      true ->
        similarity_search(store, query, k, nil)
    end
  end

  @spec similarity_search(term(), String.t(), pos_integer(), filters()) :: [document()]
  def similarity_search(store, query, k \\ 5, filters \\ nil) do
    module = adapter_module(store)
    module.similarity_search(store, query, k, filters)
  end

  @spec vector_search(term(), [number()], pos_integer(), filters()) :: [document()]
  def vector_search(store, query_vector, k \\ 5, filters \\ nil) do
    module = adapter_module(store)
    module.vector_search(store, query_vector, k, filters)
  end

  @spec get_collection_info(term()) :: map()
  def get_collection_info(store), do: adapter_module(store).get_collection_info(store)

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
  def get_collection_info(%__MODULE__{} = store) do
    %{
      "name" => store.collection_name,
      "document_count" => length(store.documents),
      "vector_store_type" => "in_memory"
    }
  end

  def matches_filters?(_doc, nil), do: true
  def matches_filters?(_doc, filters) when filters == %{}, do: true

  def matches_filters?(doc, filters) when is_map(filters) do
    metadata = metadata(doc)

    Enum.all?(filters, fn {key, value} ->
      Map.get(metadata, key) == value or Map.get(metadata, to_string(key)) == value
    end)
  end

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
