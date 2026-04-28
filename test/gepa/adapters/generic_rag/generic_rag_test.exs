defmodule GEPA.Adapters.GenericRAGTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.GenericRAG
  alias GEPA.Adapters.GenericRAG.Metrics
  alias GEPA.Adapters.GenericRAG.VectorStore.InMemory
  alias GEPA.Adapters.GenericRAGAdapter

  defp mock_vector_store do
    InMemory.new(
      documents: [
        %{
          id: "doc1",
          content: "Machine learning is a subset of artificial intelligence.",
          metadata: %{doc_id: "doc1", category: "AI"}
        },
        %{
          id: "doc2",
          content: "Python is a popular programming language for data science.",
          metadata: %{doc_id: "doc2", category: "programming"}
        }
      ]
    )
  end

  defp sample_rag_config do
    %{
      "retrieval_strategy" => "similarity",
      "top_k" => 3,
      "retrieval_weight" => 0.3,
      "generation_weight" => 0.7
    }
  end

  defp sample_training_data do
    [
      %GenericRAG.DataInst{
        query: "What is machine learning?",
        ground_truth_answer: "Machine learning is a subset of AI.",
        relevant_doc_ids: ["doc1"],
        metadata: %{difficulty: "beginner"}
      },
      %GenericRAG.DataInst{
        query: "What programming language is used for ML?",
        ground_truth_answer: "Python is commonly used for ML.",
        relevant_doc_ids: ["doc2"],
        metadata: %{difficulty: "beginner"}
      }
    ]
  end

  defp model(response \\ "Test answer") do
    fn _prompt -> response end
  end

  describe "upstream GenericRAGAdapter parity" do
    test "initialization stores vector store config pipeline and evaluator" do
      adapter =
        GenericRAGAdapter.new(
          vector_store: mock_vector_store(),
          llm_model: model("test response"),
          rag_config: sample_rag_config()
        )

      assert adapter.vector_store == mock_vector_store()
      assert adapter.config == sample_rag_config()
      assert adapter.rag_pipeline != nil
      assert adapter.pipeline == adapter.rag_pipeline
      assert adapter.evaluator == Metrics
    end

    test "initialization with defaults uses upstream default RAG configuration" do
      adapter = GenericRAGAdapter.new(vector_store: mock_vector_store(), llm_model: model())

      assert adapter.config["retrieval_strategy"] == "similarity"
      assert adapter.config["top_k"] == 5
      assert adapter.config["retrieval_weight"] == 0.3
      assert adapter.config["generation_weight"] == 0.7
      assert adapter.config["hybrid_alpha"] == 0.5
      assert is_nil(adapter.config["filters"])
    end

    test "evaluate handles a single example" do
      adapter =
        GenericRAGAdapter.new(
          vector_store: mock_vector_store(),
          llm_model: model("Machine learning is a subset of AI."),
          rag_config: sample_rag_config()
        )

      candidate = %{"answer_generation" => "Answer: {query} using {context}"}
      example = hd(sample_training_data())

      assert {:ok, result} = GenericRAGAdapter.evaluate(adapter, [example], candidate)
      assert %GEPA.EvaluationBatch{} = result
      assert length(result.scores) == 1
      assert length(result.outputs) == 1
      assert is_float(hd(result.scores))
      assert hd(result.scores) >= 0.0 and hd(result.scores) <= 1.0

      assert %{
               final_answer: "Machine learning is a subset of AI.",
               confidence_score: confidence,
               retrieved_docs: retrieved_docs,
               total_tokens: total_tokens
             } = hd(result.outputs)

      assert confidence >= 0.0 and confidence <= 1.0
      assert is_list(retrieved_docs)
      assert is_integer(total_tokens)
    end

    test "evaluate handles a batch of examples" do
      adapter =
        GenericRAGAdapter.new(
          vector_store: mock_vector_store(),
          llm_model: model(),
          rag_config: sample_rag_config()
        )

      candidate = %{"answer_generation" => "Answer: {query}"}
      data = sample_training_data()

      assert {:ok, result} = GenericRAGAdapter.evaluate(adapter, data, candidate)
      assert %GEPA.EvaluationBatch{} = result
      assert length(result.scores) == length(data)
      assert length(result.outputs) == length(data)
      assert Enum.all?(result.scores, &is_float/1)
      assert Enum.all?(result.scores, &(&1 >= 0.0 and &1 <= 1.0))
    end

    test "evaluate captures trajectories when requested" do
      adapter =
        GenericRAGAdapter.new(
          vector_store: mock_vector_store(),
          llm_model: model(),
          rag_config: sample_rag_config()
        )

      candidate = %{"answer_generation" => "Answer: {query}"}
      data = sample_training_data()

      assert {:ok, result} = GenericRAGAdapter.evaluate(adapter, data, candidate, true)
      assert %GEPA.EvaluationBatch{} = result
      assert length(result.trajectories) == length(data)

      trajectory = hd(result.trajectories)
      assert Map.has_key?(trajectory, :original_query)
      assert Map.has_key?(trajectory, :reformulated_query)
      assert Map.has_key?(trajectory, :retrieved_docs)
      assert Map.has_key?(trajectory, :synthesized_context)
      assert Map.has_key?(trajectory, :generated_answer)
      assert Map.has_key?(trajectory, :execution_metadata)
    end

    test "score computation applies configured retrieval and generation weights" do
      config = %{
        "retrieval_strategy" => "similarity",
        "top_k" => 2,
        "retrieval_weight" => 0.4,
        "generation_weight" => 0.6
      }

      adapter =
        GenericRAGAdapter.new(
          vector_store: mock_vector_store(),
          llm_model: model("Machine learning is AI."),
          rag_config: config
        )

      example = %GenericRAG.DataInst{
        query: "What is ML?",
        ground_truth_answer: "Machine learning is AI.",
        relevant_doc_ids: ["doc1"],
        metadata: %{}
      }

      assert {:ok, result} =
               GenericRAGAdapter.evaluate(adapter, [example], %{
                 "answer_generation" => "Answer: {query}"
               })

      assert length(result.scores) == 1
      assert is_float(hd(result.scores))
      assert hd(result.scores) >= 0.0 and hd(result.scores) <= 1.0
    end

    test "different retrieval strategies evaluate successfully" do
      for strategy <- ["similarity", "vector", "hybrid"] do
        adapter =
          GenericRAGAdapter.new(
            vector_store: mock_vector_store(),
            llm_model: model("Test response"),
            rag_config: %{"retrieval_strategy" => strategy, "top_k" => 2}
          )

        example = %GenericRAG.DataInst{
          query: "Test query",
          ground_truth_answer: "Test answer",
          relevant_doc_ids: ["doc1"],
          metadata: %{}
        }

        assert {:ok, result} =
                 GenericRAGAdapter.evaluate(adapter, [example], %{
                   "answer_generation" => "Answer: {query}"
                 })

        assert %GEPA.EvaluationBatch{} = result
        assert length(result.scores) == 1
        assert is_float(hd(result.scores))
      end
    end

    test "make_reflective_dataset builds component examples" do
      adapter =
        GenericRAGAdapter.new(
          vector_store: mock_vector_store(),
          llm_model: model("Test answer"),
          rag_config: sample_rag_config()
        )

      candidate = %{"answer_generation" => "Answer: {query}"}

      assert {:ok, eval_batch} =
               GenericRAGAdapter.evaluate(adapter, sample_training_data(), candidate, true)

      assert {:ok, reflective_data} =
               GenericRAGAdapter.make_reflective_dataset(adapter, candidate, eval_batch, [
                 "answer_generation"
               ])

      assert is_map(reflective_data)
      assert is_list(reflective_data["answer_generation"])
      assert [%{} | _] = reflective_data["answer_generation"]
    end

    test "evaluation handles LLM errors gracefully" do
      failing_model = fn _prompt -> raise "LLM Error" end

      adapter =
        GenericRAGAdapter.new(
          vector_store: mock_vector_store(),
          llm_model: failing_model,
          rag_config: sample_rag_config()
        )

      example = %GenericRAG.DataInst{
        query: "Test query",
        ground_truth_answer: "Test answer",
        relevant_doc_ids: ["doc1"],
        metadata: %{}
      }

      assert {:ok, result} =
               GenericRAGAdapter.evaluate(adapter, [example], %{
                 "answer_generation" => "Answer: {query}"
               })

      assert %GEPA.EvaluationBatch{} = result
      assert length(result.scores) == 1
      assert is_float(hd(result.scores))
      assert hd(result.scores) >= 0.0 and hd(result.scores) <= 1.0
    end

    test "prompt template variations execute without errors" do
      adapter =
        GenericRAGAdapter.new(
          vector_store: mock_vector_store(),
          llm_model: model("Valid response"),
          rag_config: sample_rag_config()
        )

      example = %GenericRAG.DataInst{
        query: "What is AI?",
        ground_truth_answer: "AI is artificial intelligence.",
        relevant_doc_ids: ["doc1"],
        metadata: %{}
      }

      candidates = [
        %{"answer_generation" => "Answer: {query}"},
        %{
          "query_reformulation" => "Improve query: {query}",
          "context_synthesis" => "Synthesize: {documents} for {query}",
          "answer_generation" => "Answer {query} using context: {context}",
          "reranking_criteria" => "Rank documents for {query}"
        },
        %{"answer_generation" => "Provide a comprehensive answer."}
      ]

      for candidate <- candidates do
        assert {:ok, result} = GenericRAGAdapter.evaluate(adapter, [example], candidate)
        assert %GEPA.EvaluationBatch{} = result
        assert length(result.scores) == 1
      end
    end
  end
end
