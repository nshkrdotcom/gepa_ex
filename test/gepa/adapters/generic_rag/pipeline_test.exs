defmodule GEPA.Adapters.GenericRAG.PipelineTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.GenericRAG.Pipeline
  alias GEPA.Adapters.GenericRAG.VectorStore.InMemory

  defp mock_vector_store do
    InMemory.new(
      collection_name: "mock_collection",
      documents: [
        %{
          id: "doc1",
          content: "Machine learning is a subset of artificial intelligence.",
          metadata: %{category: "AI", score: 0.95}
        },
        %{
          id: "doc2",
          content: "Python is a popular programming language for data science.",
          metadata: %{category: "programming", score: 0.89}
        }
      ]
    )
  end

  defp llm_client(response \\ "This is a test response from the LLM.") do
    fn _prompt -> response end
  end

  defp embedding_function do
    fn _text -> List.duplicate(0.1, 384) end
  end

  defp rag_pipeline do
    Pipeline.new(
      vector_store: mock_vector_store(),
      llm_client: llm_client(),
      embedding_model: "text-embedding-3-small",
      embedding_function: embedding_function()
    )
  end

  describe "upstream RAGPipeline parity" do
    test "initialization stores vector store LLM client and default embedding model" do
      pipeline = Pipeline.new(vector_store: mock_vector_store(), llm_client: llm_client())

      assert pipeline.vector_store == mock_vector_store()
      assert is_function(pipeline.llm_client, 1)
      assert pipeline.llm == pipeline.llm_client
      assert pipeline.embedding_model == "text-embedding-3-small"
      assert is_function(pipeline.embedding_function, 1)
    end

    test "initialization accepts a custom embedding function" do
      embedding = embedding_function()

      pipeline =
        Pipeline.new(
          vector_store: mock_vector_store(),
          llm_client: llm_client(),
          embedding_function: embedding
        )

      assert pipeline.embedding_function == embedding
    end

    test "execute_rag returns the expected result structure" do
      result =
        Pipeline.execute_rag(
          rag_pipeline(),
          "What is machine learning?",
          %{"answer_generation" => "Answer: {query} using context: {context}"},
          %{"retrieval_strategy" => "similarity", "top_k" => 2}
        )

      assert is_map(result)
      assert Map.has_key?(result, :original_query)
      assert Map.has_key?(result, :reformulated_query)
      assert Map.has_key?(result, :retrieved_docs)
      assert Map.has_key?(result, :synthesized_context)
      assert Map.has_key?(result, :generated_answer)
      assert Map.has_key?(result, :metadata)
      assert is_binary(result.generated_answer)
      assert result.generated_answer != ""
    end

    test "execute_rag supports query reformulation" do
      query = "What is ML?"

      result =
        Pipeline.execute_rag(
          rag_pipeline(),
          query,
          %{
            "query_reformulation" => "Reformulate this query: {query}",
            "answer_generation" => "Answer: {query}"
          },
          %{"retrieval_strategy" => "similarity", "top_k" => 3}
        )

      assert result.original_query == query
      assert is_binary(result.reformulated_query)
      assert result.reformulated_query != ""
    end

    test "execute_rag tolerates reranking prompts" do
      config = %{"retrieval_strategy" => "similarity", "top_k" => 2}

      result =
        Pipeline.execute_rag(
          rag_pipeline(),
          "machine learning",
          %{
            "reranking_criteria" => "Rank documents by relevance to: {query}",
            "answer_generation" => "Answer using context: {context}"
          },
          config
        )

      assert is_list(result.retrieved_docs)
      assert length(result.retrieved_docs) <= config["top_k"]
    end

    test "execute_rag works with minimal configuration" do
      result =
        Pipeline.execute_rag(
          rag_pipeline(),
          "What is AI?",
          %{"answer_generation" => "Answer: {query}"},
          %{"retrieval_strategy" => "similarity", "top_k" => 1}
        )

      assert is_map(result)
      assert is_binary(result.generated_answer)
      assert result.generated_answer != ""
    end

    test "execute_rag supports similarity vector and hybrid retrieval strategies" do
      for strategy <- ["similarity", "vector", "hybrid"] do
        result =
          Pipeline.execute_rag(
            rag_pipeline(),
            "test query",
            %{"answer_generation" => "Answer: {query}"},
            %{"retrieval_strategy" => strategy, "top_k" => 2}
          )

        assert is_map(result)
        assert is_binary(result.generated_answer)
        assert is_list(result.retrieved_docs)
      end
    end

    test "execute_rag includes execution metadata" do
      result =
        Pipeline.execute_rag(
          rag_pipeline(),
          "test",
          %{"answer_generation" => "Answer: {query}"},
          %{"retrieval_strategy" => "similarity", "top_k" => 1}
        )

      assert Map.has_key?(result.metadata, :retrieval_count)
      assert Map.has_key?(result.metadata, :total_tokens)
      assert Map.has_key?(result.metadata, :vector_store_type)
      assert is_integer(result.metadata.retrieval_count)
      assert is_integer(result.metadata.total_tokens)
    end

    test "reformulate_query returns a non-empty query string" do
      reformulated =
        Pipeline.reformulate_query(
          rag_pipeline(),
          "What is ML?",
          "Reformulate this query for better search: {query}"
        )

      assert is_binary(reformulated)
      assert reformulated != ""
    end

    test "retrieve_documents returns documents for a retrieval config" do
      config = %{"retrieval_strategy" => "similarity", "top_k" => 2}
      docs = Pipeline.retrieve_documents(rag_pipeline(), "machine learning", config)

      assert is_list(docs)
      assert length(docs) <= config["top_k"]
      assert Enum.all?(docs, &is_map/1)
    end

    test "generate_answer returns a non-empty answer" do
      answer =
        Pipeline.generate_answer(
          rag_pipeline(),
          "What is AI?",
          "Artificial intelligence is machine intelligence.",
          "Answer the question: {query} using context: {context}"
        )

      assert is_binary(answer)
      assert answer != ""
    end

    test "execute_rag handles LLM failures without raising" do
      pipeline =
        Pipeline.new(
          vector_store: mock_vector_store(),
          llm_client: fn _prompt -> raise "LLM Error" end
        )

      result =
        Pipeline.execute_rag(
          pipeline,
          "test query",
          %{"answer_generation" => "Answer: {query}"},
          %{"retrieval_strategy" => "similarity", "top_k" => 1}
        )

      assert is_map(result)
      assert is_binary(result.generated_answer)
    end

    test "execute_rag handles empty prompts" do
      result =
        Pipeline.execute_rag(
          rag_pipeline(),
          "test query",
          %{},
          %{"retrieval_strategy" => "similarity", "top_k" => 1}
        )

      assert is_map(result)
      assert result.original_query == "test query"
    end
  end
end
