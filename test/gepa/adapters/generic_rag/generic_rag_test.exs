defmodule GEPA.Adapters.GenericRAGTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.GenericRAG
  alias GEPA.Adapters.GenericRAG.VectorStore.InMemory

  test "evaluates examples and captures RAG trajectories" do
    store =
      InMemory.new(
        documents: [
          %{
            id: "doc1",
            content: "Machine learning is a subset of AI.",
            metadata: %{doc_id: "doc1"}
          }
        ]
      )

    model = fn prompt ->
      assert prompt =~ "Machine learning"
      "Machine learning is a subset of AI."
    end

    adapter = GenericRAG.new(vector_store: store, llm: model, rag_config: %{top_k: 1})

    batch = [
      %{
        query: "What is machine learning?",
        ground_truth_answer: "Machine learning is a subset of AI.",
        relevant_doc_ids: ["doc1"]
      }
    ]

    candidate = %{"answer_generation" => "Answer {query} using {context}"}

    assert {:ok, eval_batch} = GenericRAG.evaluate(adapter, batch, candidate, true)
    assert [score] = eval_batch.scores
    assert score > 0.0
    assert [%{retrieved_docs: [_], generated_answer: _}] = eval_batch.trajectories

    assert {:ok, dataset} =
             GenericRAG.make_reflective_dataset(adapter, candidate, eval_batch, [
               "answer_generation"
             ])

    assert [%{"Feedback" => feedback}] = dataset["answer_generation"]
    assert feedback =~ "Generated answer"
  end
end
