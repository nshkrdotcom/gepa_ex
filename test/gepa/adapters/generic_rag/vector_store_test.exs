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

  @interface_docs [
    %{
      id: "doc1",
      content: "Machine learning is a subset of artificial intelligence.",
      metadata: %{category: "AI", difficulty: "beginner"}
    },
    %{
      id: "doc2",
      content: "Neural networks are inspired by biological neural networks.",
      metadata: %{category: "AI", difficulty: "intermediate"}
    },
    %{
      id: "doc3",
      content: "Python is a popular programming language for data science.",
      metadata: %{category: "programming", difficulty: "beginner"}
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

  describe "upstream vector store interface parity" do
    test "abstract base class maps to a behaviour facade" do
      assert Code.ensure_loaded?(VectorStore)
      assert function_exported?(VectorStore, :behaviour_info, 1)
      refute function_exported?(VectorStore, :new, 0)
    end

    test "mock vector store initialization maps to an in-memory store fixture" do
      store = InMemory.new(collection_name: "test_collection", documents: @interface_docs)

      assert store.collection_name == "test_collection"
      assert length(store.documents) == 3
    end

    test "similarity search returns keyword matches within the requested limit" do
      results =
        interface_store()
        |> VectorStore.similarity_search("machine learning", 2)

      assert length(results) <= 2

      assert Enum.any?(
               results,
               &String.contains?(String.downcase(&1.content), "machine learning")
             )
    end

    test "similarity search applies metadata filters" do
      results =
        interface_store()
        |> VectorStore.similarity_search("learning", 5, %{category: "AI"})

      assert results != []
      assert Enum.all?(results, &(get_in(&1, [:metadata, :category]) == "AI"))
    end

    test "similarity search returns an empty list when no document matches" do
      assert [] = VectorStore.similarity_search(interface_store(), "quantum computing", 5)
    end

    test "vector search returns the first matching documents within the requested limit" do
      results = VectorStore.vector_search(interface_store(), List.duplicate(0.1, 384), 2)

      assert length(results) == 2
      assert Enum.all?(results, &Map.has_key?(&1, :id))
    end

    test "vector search applies metadata filters" do
      results =
        interface_store()
        |> VectorStore.vector_search(List.duplicate(0.1, 384), 5, %{difficulty: "beginner"})

      assert results != []
      assert Enum.all?(results, &(get_in(&1, [:metadata, :difficulty]) == "beginner"))
    end

    test "hybrid search returns similarity-style results" do
      store = interface_store()

      results = VectorStore.hybrid_search(store, "machine learning", 3, 0.5)
      similarity_results = VectorStore.similarity_search(store, "machine learning", 3)

      assert length(results) <= 3
      assert length(results) == length(similarity_results)
    end

    test "collection info returns name, count, and backend type" do
      store = InMemory.new(collection_name: "my_collection", documents: @interface_docs)

      assert %{
               "name" => "my_collection",
               "document_count" => 3,
               "vector_store_type" => "in_memory"
             } = VectorStore.get_collection_info(store)
    end

    test "k parameter limits similarity and vector search results" do
      store = interface_store()

      similarity_results = VectorStore.similarity_search(store, "learning", 1)
      vector_results = VectorStore.vector_search(store, List.duplicate(0.1, 384), 2)

      assert length(similarity_results) <= 1
      assert length(vector_results) <= 2
    end

    test "metadata filter matching handles exact, multiple, and missing-key checks" do
      doc = %{metadata: %{category: "AI", difficulty: "beginner"}}

      assert InMemory.matches_filters?(doc, %{category: "AI"})
      refute InMemory.matches_filters?(doc, %{category: "programming"})
      assert InMemory.matches_filters?(doc, %{category: "AI", difficulty: "beginner"})
      refute InMemory.matches_filters?(%{metadata: %{category: "AI"}}, %{difficulty: "beginner"})
    end

    test "required interface methods are behaviour callbacks" do
      callbacks = VectorStore.behaviour_info(:callbacks)

      assert {:similarity_search, 4} in callbacks
      assert {:vector_search, 4} in callbacks
      assert {:get_collection_info, 1} in callbacks
    end

    test "optional hybrid search exists without being a required callback" do
      callbacks = VectorStore.behaviour_info(:callbacks)

      assert function_exported?(VectorStore, :hybrid_search, 4)
      refute {:hybrid_search, 4} in callbacks
    end
  end

  defp interface_store do
    InMemory.new(documents: @interface_docs)
  end
end
