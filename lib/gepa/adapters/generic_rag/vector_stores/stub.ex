defmodule GEPA.Adapters.GenericRAG.VectorStores.Stub do
  @moduledoc false

  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)

    quote do
      @behaviour GEPA.Adapters.GenericRAG.VectorStore

      defstruct backend: unquote(backend), opts: []

      def new(opts \\ []), do: %__MODULE__{opts: opts}

      @impl true
      def health_check(store), do: GEPA.Adapters.GenericRAG.VectorStores.Stub.error(store)

      @impl true
      def create_collection(store, _opts),
        do: GEPA.Adapters.GenericRAG.VectorStores.Stub.error(store)

      @impl true
      def reset_collection(store, _opts),
        do: GEPA.Adapters.GenericRAG.VectorStores.Stub.error(store)

      @impl true
      def upsert_documents(store, _documents, _opts),
        do: GEPA.Adapters.GenericRAG.VectorStores.Stub.error(store)

      @impl true
      def delete_documents(store, _ids, _opts),
        do: GEPA.Adapters.GenericRAG.VectorStores.Stub.error(store)

      @impl true
      def similarity_search(store, _query, _k, _filters),
        do: GEPA.Adapters.GenericRAG.VectorStores.Stub.error(store)

      @impl true
      def vector_search(store, _vector, _k, _filters),
        do: GEPA.Adapters.GenericRAG.VectorStores.Stub.error(store)

      @impl true
      def get_collection_info(store), do: GEPA.Adapters.GenericRAG.VectorStores.Stub.info(store)

      @impl true
      def embedding_dimension(_store), do: nil

      @impl true
      def supports_hybrid_search?(_store), do: false

      @impl true
      def supports_metadata_filtering?(_store), do: false
    end
  end

  def error(%{backend: backend}) do
    {:error, {:not_configured, backend}}
  end

  def info(%{backend: backend}) do
    %{
      "name" => to_string(backend),
      "document_count" => 0,
      "vector_store_type" => to_string(backend),
      "embedding_dimension" => nil,
      "status" => "not_configured"
    }
  end
end

defmodule GEPA.Adapters.GenericRAG.VectorStores.Pgvector do
  @moduledoc """
  Pgvector adapter placeholder behind the Generic RAG vector-store behaviour.

  The module is intentionally explicit and non-operational until a production
  PostgreSQL/pgvector integration is selected.
  """

  use GEPA.Adapters.GenericRAG.VectorStores.Stub, backend: :pgvector
end

defmodule GEPA.Adapters.GenericRAG.VectorStores.Weaviate do
  @moduledoc "Weaviate vector-store placeholder behind the Generic RAG behaviour."

  use GEPA.Adapters.GenericRAG.VectorStores.Stub, backend: :weaviate
end

defmodule GEPA.Adapters.GenericRAG.VectorStores.LanceDB do
  @moduledoc "LanceDB vector-store placeholder behind the Generic RAG behaviour."

  use GEPA.Adapters.GenericRAG.VectorStores.Stub, backend: :lancedb
end

defmodule GEPA.Adapters.GenericRAG.VectorStores.Chroma do
  @moduledoc "Chroma vector-store placeholder behind the Generic RAG behaviour."

  use GEPA.Adapters.GenericRAG.VectorStores.Stub, backend: :chroma
end

defmodule GEPA.Adapters.GenericRAG.VectorStores.Milvus do
  @moduledoc "Milvus vector-store placeholder behind the Generic RAG behaviour."

  use GEPA.Adapters.GenericRAG.VectorStores.Stub, backend: :milvus
end
