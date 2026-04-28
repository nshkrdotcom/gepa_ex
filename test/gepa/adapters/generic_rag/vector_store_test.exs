defmodule GEPA.Adapters.GenericRAG.VectorStoreTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.GenericRAG
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

  @fixture_docs [
    %{
      id: "doc1",
      content:
        "Machine learning is a subset of artificial intelligence that uses statistical techniques.",
      metadata: %{category: "AI", difficulty: "intermediate", relevance: "high", score: 0.9}
    },
    %{
      id: "doc2",
      content:
        "Python is a high-level programming language widely used for data science and machine learning.",
      metadata: %{
        category: "programming",
        difficulty: "beginner",
        relevance: "medium",
        score: 0.5
      }
    },
    %{
      id: "doc3",
      content: "Neural networks are computing systems inspired by biological neural networks.",
      metadata: %{category: "AI", difficulty: "advanced", relevance: "high", score: 0.95}
    },
    %{
      id: "doc4",
      content: "Data preprocessing is a crucial step in machine learning pipelines.",
      metadata: %{
        category: "data-science",
        difficulty: "intermediate",
        relevance: "medium",
        score: 0.6
      }
    },
    %{
      id: "doc5",
      content:
        "Deep learning is a subset of machine learning based on artificial neural networks.",
      metadata: %{category: "AI", difficulty: "advanced", relevance: "high", score: 0.85}
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

  test "upstream fixture-style vector store supports keyword, vector, hybrid, and operator filters" do
    store = InMemory.new(collection_name: "pytest_test_collection", documents: @fixture_docs)

    assert %{
             "name" => "pytest_test_collection",
             "document_count" => 5,
             "vector_store_type" => "in_memory",
             "embedding_dimension" => 384
           } = VectorStore.get_collection_info(store)

    assert [%{id: "doc1"} | _] = VectorStore.similarity_search(store, "machine learning", 5)
    assert [%{id: "doc3"} | _] = VectorStore.hybrid_search(store, "neural networks", 5, 0.7)

    assert [%{id: "doc3"}, %{id: "doc5"}] =
             VectorStore.vector_search(store, [0.1, 0.2], 5, %{
               category: "AI",
               difficulty: %{"$in" => ["advanced"]},
               score: %{"$gt" => 0.8}
             })

    assert [] = VectorStore.similarity_search(store, "machine learning", 5, %{missing: "value"})
  end

  test "upstream fixture-style RAG data directory is available as a writable temp dir" do
    data_dir = Path.join(System.tmp_dir!(), "rag_test_data_#{System.unique_integer([:positive])}")
    File.mkdir_p!(data_dir)

    on_exit(fn -> File.rm_rf!(data_dir) end)

    assert File.dir?(data_dir)
    test_file = Path.join(data_dir, "fixture.txt")
    File.write!(test_file, "ok")
    assert File.read!(test_file) == "ok"
  end

  describe "upstream interface-only parity" do
    test "RAG data instance exposes expected fields" do
      data_inst = %GenericRAG.DataInst{
        query: "What is machine learning?",
        ground_truth_answer: "ML is a subset of AI.",
        relevant_doc_ids: ["doc1", "doc2"],
        metadata: %{category: "AI", difficulty: "beginner"}
      }

      assert data_inst.query == "What is machine learning?"
      assert data_inst.ground_truth_answer == "ML is a subset of AI."
      assert data_inst.relevant_doc_ids == ["doc1", "doc2"]
      assert data_inst.metadata.category == "AI"
    end

    test "RAG data instance required fields are present with list and map defaults" do
      data_inst = %GenericRAG.DataInst{
        query: "Test query",
        ground_truth_answer: "Test answer",
        relevant_doc_ids: [],
        metadata: %{}
      }

      assert Map.has_key?(data_inst, :query)
      assert Map.has_key?(data_inst, :ground_truth_answer)
      assert Map.has_key?(data_inst, :relevant_doc_ids)
      assert Map.has_key?(data_inst, :metadata)
      assert is_list(data_inst.relevant_doc_ids)
      assert is_map(data_inst.metadata)
    end

    test "vector store interface is a behaviour facade, not an instantiable store" do
      assert Code.ensure_loaded?(VectorStore)
      assert function_exported?(VectorStore, :behaviour_info, 1)
      refute function_exported?(VectorStore, :new, 0)
    end

    test "vector store interface defines required callback methods" do
      callbacks = VectorStore.behaviour_info(:callbacks)

      assert {:similarity_search, 4} in callbacks
      assert {:vector_search, 4} in callbacks
      assert {:get_collection_info, 1} in callbacks
    end

    test "vector store interface defines optional hybrid search facade" do
      callbacks = VectorStore.behaviour_info(:callbacks)

      assert function_exported?(VectorStore, :hybrid_search, 4)
      refute {:hybrid_search, 4} in callbacks
    end
  end
end
