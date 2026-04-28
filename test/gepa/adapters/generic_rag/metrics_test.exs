defmodule GEPA.Adapters.GenericRAG.MetricsTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.GenericRAG.Metrics

  describe "retrieval metrics upstream parity" do
    test "initialization facade is available" do
      assert Code.ensure_loaded?(Metrics)
      assert function_exported?(Metrics, :evaluate_retrieval, 2)
      assert function_exported?(Metrics, :evaluate_generation, 3)
      assert function_exported?(Metrics, :combined_rag_score, 3)
    end

    test "perfect retrieval returns all one scores" do
      docs = [
        %{"metadata" => %{"doc_id" => "doc1"}},
        %{"metadata" => %{"doc_id" => "doc2"}},
        %{"metadata" => %{"doc_id" => "doc3"}}
      ]

      metrics = Metrics.evaluate_retrieval(docs, ["doc1", "doc2", "doc3"])

      assert metrics["retrieval_precision"] == 1.0
      assert metrics["retrieval_recall"] == 1.0
      assert metrics["retrieval_f1"] == 1.0
      assert metrics["retrieval_mrr"] == 1.0
    end

    test "partial retrieval calculates precision recall and MRR" do
      docs = [
        %{"metadata" => %{"doc_id" => "doc1"}},
        %{"metadata" => %{"doc_id" => "doc2"}},
        %{"metadata" => %{"doc_id" => "doc3"}},
        %{"metadata" => %{"doc_id" => "doc4"}}
      ]

      metrics = Metrics.evaluate_retrieval(docs, ["doc1", "doc3"])

      assert metrics["retrieval_precision"] == 0.5
      assert metrics["retrieval_recall"] == 1.0
      assert metrics["retrieval_mrr"] == 1.0
    end

    test "retrieval with no relevant retrieved documents returns zero scores" do
      docs = [%{"metadata" => %{"doc_id" => "doc1"}}, %{"metadata" => %{"doc_id" => "doc2"}}]

      metrics = Metrics.evaluate_retrieval(docs, ["doc3", "doc4"])

      assert metrics["retrieval_precision"] == 0.0
      assert metrics["retrieval_recall"] == 0.0
      assert metrics["retrieval_f1"] == 0.0
      assert metrics["retrieval_mrr"] == 0.0
    end

    test "retrieval with empty retrieved list returns zero scores" do
      metrics = Metrics.evaluate_retrieval([], ["doc1", "doc2"])

      assert metrics["retrieval_precision"] == 0.0
      assert metrics["retrieval_recall"] == 0.0
      assert metrics["retrieval_f1"] == 0.0
      assert metrics["retrieval_mrr"] == 0.0
    end

    test "retrieval with empty relevant list returns zero scores" do
      docs = [%{"metadata" => %{"doc_id" => "doc1"}}, %{"metadata" => %{"doc_id" => "doc2"}}]

      metrics = Metrics.evaluate_retrieval(docs, [])

      assert metrics["retrieval_precision"] == 0.0
      assert metrics["retrieval_recall"] == 0.0
      assert metrics["retrieval_f1"] == 0.0
      assert metrics["retrieval_mrr"] == 0.0
    end

    test "retrieval accepts id field variations" do
      docs = [%{"metadata" => %{"id" => "doc1"}}, %{"metadata" => %{"id" => "doc2"}}]

      metrics = Metrics.evaluate_retrieval(docs, ["doc1"])

      assert metrics["retrieval_precision"] == 0.5
      assert metrics["retrieval_recall"] == 1.0
      assert metrics["retrieval_mrr"] == 1.0
    end
  end

  describe "generation metrics upstream parity" do
    test "perfect generation match includes expected scores" do
      metrics =
        Metrics.evaluate_generation(
          "Machine learning is a subset of AI.",
          "Machine learning is a subset of AI.",
          "Machine learning is a subset of artificial intelligence."
        )

      assert metrics["exact_match"] == 1.0
      assert metrics["token_f1"] == 1.0
      assert Map.has_key?(metrics, "answer_relevance")
      assert Map.has_key?(metrics, "faithfulness")
      assert Map.has_key?(metrics, "answer_confidence")
    end

    test "partial generation match produces bounded overlap scores" do
      metrics =
        Metrics.evaluate_generation(
          "Machine learning uses algorithms to learn patterns.",
          "Machine learning is a subset of AI that employs algorithms.",
          "Machine learning algorithms learn patterns from data."
        )

      assert metrics["exact_match"] == 0.0
      assert metrics["token_f1"] > 0.0
      assert metrics["token_f1"] < 1.0
      assert metrics["answer_relevance"] >= 0.0 and metrics["answer_relevance"] <= 1.0
      assert metrics["faithfulness"] >= 0.0 and metrics["faithfulness"] <= 1.0
      assert metrics["answer_confidence"] >= 0.0 and metrics["answer_confidence"] <= 1.0
    end

    test "empty generated answer has zero answer scores and full faithfulness" do
      metrics =
        Metrics.evaluate_generation(
          "",
          "Machine learning is AI.",
          "Context about machine learning."
        )

      assert metrics["exact_match"] == 0.0
      assert metrics["token_f1"] == 0.0
      assert metrics["answer_relevance"] == 0.0
      assert metrics["faithfulness"] == 1.0
    end
  end

  describe "combined score upstream parity" do
    test "balanced combined RAG score is bounded" do
      retrieval = %{
        "retrieval_precision" => 0.8,
        "retrieval_recall" => 0.6,
        "retrieval_f1" => 0.69,
        "retrieval_mrr" => 0.5
      }

      generation = %{
        "exact_match" => 0.0,
        "token_f1" => 0.8,
        "bleu_score" => 0.7,
        "answer_relevance" => 0.9,
        "faithfulness" => 0.85,
        "answer_confidence" => 0.85
      }

      score =
        Metrics.combined_rag_score(retrieval, generation,
          retrieval_weight: 0.3,
          generation_weight: 0.7
        )

      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "combined RAG score uses default weights" do
      retrieval = %{"retrieval_f1" => 0.8}
      generation = %{"token_f1" => 0.7, "answer_relevance" => 0.6, "faithfulness" => 0.9}

      expected_generation = 0.7 * 0.4 + 0.6 * 0.3 + 0.9 * 0.3
      expected = 0.3 * 0.8 + 0.7 * expected_generation

      assert_in_delta Metrics.combined_rag_score(retrieval, generation), expected, 1.0e-8
    end
  end

  describe "helper metrics upstream parity" do
    test "exact match is case insensitive" do
      assert Metrics.exact_match?("Hello World", "hello world")
      assert Metrics.exact_match?("HELLO WORLD", "hello world")
      refute Metrics.exact_match?("Hello World", "Hello Universe")
    end

    test "exact match trims ordinary surrounding whitespace but preserves tab differences" do
      assert Metrics.exact_match?("  hello world  ", "hello world")
      refute Metrics.exact_match?("hello\tworld", "hello world")
    end

    test "token F1 handles perfect match" do
      assert Metrics.token_f1("machine learning is great", "machine learning is great") == 1.0
    end

    test "token F1 handles partial overlap" do
      f1 = Metrics.token_f1("machine learning algorithms", "machine learning techniques")

      assert_in_delta f1, 2 / 3, 1.0e-8
    end

    test "token F1 handles no overlap" do
      assert Metrics.token_f1("python programming", "java development") == 0.0
    end

    test "token F1 handles empty strings" do
      assert Metrics.token_f1("", "") == 1.0
      assert Metrics.token_f1("hello", "") == 0.0
      assert Metrics.token_f1("", "hello") == 0.0
    end

    test "simple BLEU score handles perfect partial and no overlap" do
      assert Metrics.simple_bleu("machine learning is amazing", "machine learning is amazing") ==
               1.0

      partial = Metrics.simple_bleu("machine learning algorithms", "machine learning techniques")
      assert partial >= 0.0 and partial <= 1.0
      assert Metrics.simple_bleu("completely different", "totally unrelated") == 0.0
    end

    test "answer relevance calculates overlap with context" do
      relevance =
        Metrics.answer_relevance(
          "machine learning algorithms are powerful",
          "machine learning uses algorithms to solve problems"
        )

      assert relevance > 0.0 and relevance <= 1.0
      assert Metrics.answer_relevance("python programming", "java development") == 0.0
    end

    test "faithfulness score is bounded and empty answer is faithful" do
      faithfulness =
        Metrics.faithfulness(
          "machine learning uses algorithms",
          "machine learning algorithms are used to learn patterns"
        )

      assert faithfulness >= 0.0 and faithfulness <= 1.0
      assert Metrics.faithfulness("", "context") == 1.0
    end

    test "extract phrases returns a non-empty set for meaningful text" do
      phrases = Metrics.extract_phrases("machine learning algorithms are very powerful tools")

      assert %MapSet{} = phrases
      assert MapSet.size(phrases) > 0
    end

    test "normalize text removes punctuation lowercases and normalizes ordinary spaces" do
      assert Metrics.normalize_text("  Hello, World!  This is a TEST.  ") ==
               "hello world this is a test"
    end

    test "normalize text removes punctuation characters" do
      normalized = Metrics.normalize_text("Hello! How are you? I'm fine, thanks.")

      refute normalized =~ "!"
      refute normalized =~ "?"
      refute normalized =~ ","
      refute normalized =~ "."
      refute normalized =~ "'"
    end
  end

  describe "integration scenario upstream parity" do
    test "typical RAG evaluation scenario calculates bounded retrieval generation and combined scores" do
      retrieved_docs = [
        %{"metadata" => %{"doc_id" => "doc1"}},
        %{"metadata" => %{"doc_id" => "doc2"}},
        %{"metadata" => %{"doc_id" => "doc3"}},
        %{"metadata" => %{"doc_id" => "doc4"}},
        %{"metadata" => %{"doc_id" => "doc5"}}
      ]

      relevant_docs = ["doc1", "doc3", "doc6"]

      retrieval = Metrics.evaluate_retrieval(retrieved_docs, relevant_docs)

      generation =
        Metrics.evaluate_generation(
          "Machine learning is a subset of artificial intelligence that uses algorithms.",
          "Machine learning is a subset of AI that employs algorithms to learn patterns.",
          "Machine learning, a subset of artificial intelligence, employs various algorithms."
        )

      combined_score = Metrics.combined_rag_score(retrieval, generation)

      assert retrieval["retrieval_precision"] == 0.4
      assert retrieval["retrieval_recall"] == 2 / 3
      assert retrieval["retrieval_mrr"] == 1.0

      for value <- Map.values(retrieval) ++ Map.values(generation) ++ [combined_score] do
        assert value >= 0.0 and value <= 1.0
      end
    end
  end
end
