defmodule GEPA.Adapters.GenericRAG.VectorStoreTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.GenericRAG.VectorStore
  alias GEPA.Adapters.GenericRAG.VectorStore.InMemory

  @docs [
    %{
      id: "doc1",
      content: "Machine learning is a subset of artificial intelligence.",
      metadata: %{category: "AI"}
    },
    %{
      id: "doc2",
      content: "Python is popular for data science.",
      metadata: %{category: "programming"}
    }
  ]

  test "in-memory similarity search uses token overlap and filters" do
    store = InMemory.new(documents: @docs)

    assert [%{id: "doc1"}] =
             VectorStore.similarity_search(store, "machine learning", 5, %{category: "AI"})

    assert [] =
             VectorStore.similarity_search(store, "machine learning", 5, %{
               category: "programming"
             })
  end

  test "collection info is exposed" do
    store = InMemory.new(collection_name: "docs", documents: @docs)
    assert %{"name" => "docs", "document_count" => 2} = VectorStore.get_collection_info(store)
  end
end
