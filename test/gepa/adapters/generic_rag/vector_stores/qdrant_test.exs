defmodule GEPA.Adapters.GenericRAG.VectorStores.QdrantTest do
  use ExUnit.Case, async: false

  alias GEPA.Adapters.GenericRAG.VectorStore
  alias GEPA.Adapters.GenericRAG.VectorStores
  alias GEPA.Adapters.GenericRAG.VectorStores.Qdrant

  defmodule StaticEmbedder do
    @behaviour GEPA.Embeddings

    defstruct []

    def embed(_provider, text, _opts), do: {:ok, vector_for(text)}
    def embed_batch(_provider, texts, _opts), do: {:ok, Enum.map(texts, &vector_for/1)}
    def dimensions(_provider), do: 3
    def model(_provider), do: "static-test-embedding"

    defp vector_for(text) do
      cond do
        String.contains?(String.downcase(to_string(text)), "alpha") -> [1.0, 0.0, 0.0]
        String.contains?(String.downcase(to_string(text)), "beta") -> [0.0, 1.0, 0.0]
        true -> [0.0, 0.0, 1.0]
      end
    end
  end

  test "Qdrant adapter reports missing vector size before collection creation" do
    store = Qdrant.new(collection_name: "missing_vector_size_test")

    assert {:error, :missing_vector_size} = VectorStore.create_collection(store)
  end

  test "placeholder vector stores fail explicitly until configured" do
    backends = [
      {VectorStores.Pgvector, :pgvector},
      {VectorStores.Weaviate, :weaviate},
      {VectorStores.LanceDB, :lancedb},
      {VectorStores.Chroma, :chroma},
      {VectorStores.Milvus, :milvus}
    ]

    for {module, backend} <- backends do
      store = module.new()

      assert {:error, {:not_configured, ^backend}} = VectorStore.health_check(store)

      assert {:error, {:not_configured, ^backend}} =
               VectorStore.similarity_search(store, "query", 1)

      assert %{"status" => "not_configured", "vector_store_type" => type} =
               VectorStore.get_collection_info(store)

      assert type == to_string(backend)
    end
  end

  test "live Qdrant smoke stores and searches vectors when opted in" do
    unless System.get_env("GEPA_LIVE_QDRANT") == "1" do
      assert true
    else
      collection = "gepa_ex_test_#{System.unique_integer([:positive])}"

      store =
        Qdrant.new(
          collection_name: collection,
          embedder: %StaticEmbedder{},
          vector_size: 3
        )

      assert :ok = VectorStore.health_check(store)
      assert :ok = VectorStore.reset_collection(store)

      assert {:ok, ["alpha", "beta"]} =
               VectorStore.upsert_documents(store, [
                 %{id: "alpha", content: "alpha document", metadata: %{kind: "a"}},
                 %{id: "beta", content: "beta document", metadata: %{kind: "b"}}
               ])

      assert {:ok, [%{id: "alpha"} | _]} =
               VectorStore.similarity_search(store, "alpha question", 2, %{kind: "a"})
    end
  end
end
