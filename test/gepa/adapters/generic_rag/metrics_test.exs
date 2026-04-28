defmodule GEPA.Adapters.GenericRAG.MetricsTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.GenericRAG.Metrics

  test "retrieval metrics calculate precision recall f1 and mrr" do
    docs = [
      %{"metadata" => %{"doc_id" => "doc1"}},
      %{"metadata" => %{"doc_id" => "doc2"}},
      %{"metadata" => %{"doc_id" => "doc3"}}
    ]

    metrics = Metrics.evaluate_retrieval(docs, ["doc1", "doc3"])

    assert metrics["retrieval_precision"] == 2 / 3
    assert metrics["retrieval_recall"] == 1.0
    assert metrics["retrieval_mrr"] == 1.0
  end

  test "generation metrics handle exact and partial matches" do
    perfect =
      Metrics.evaluate_generation(
        "Machine learning is AI",
        "Machine learning is AI",
        "Machine learning is AI"
      )

    assert perfect["exact_match"] == 1.0
    assert perfect["token_f1"] == 1.0

    partial =
      Metrics.evaluate_generation(
        "machine learning algorithms",
        "machine learning techniques",
        "machine learning"
      )

    assert partial["exact_match"] == 0.0
    assert partial["token_f1"] > 0.0
  end

  test "combined RAG score uses default weights" do
    retrieval = %{"retrieval_f1" => 0.8}
    generation = %{"token_f1" => 0.7, "answer_relevance" => 0.6, "faithfulness" => 0.9}

    expected_generation = 0.7 * 0.4 + 0.6 * 0.3 + 0.9 * 0.3
    expected = 0.3 * 0.8 + 0.7 * expected_generation

    assert_in_delta Metrics.combined_rag_score(retrieval, generation), expected, 1.0e-8
  end
end
