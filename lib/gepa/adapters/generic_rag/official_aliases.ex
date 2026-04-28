defmodule GEPA.Adapters.GenericRAG.VectorStoreInterface do
  @moduledoc "Compatibility facade for `GEPA.Adapters.GenericRAG.VectorStore`."
  defdelegate similarity_search(store, query, k \\ 5, filters \\ nil),
    to: GEPA.Adapters.GenericRAG.VectorStore

  defdelegate vector_search(store, query_vector, k \\ 5, filters \\ nil),
    to: GEPA.Adapters.GenericRAG.VectorStore

  defdelegate hybrid_search(store, query, k \\ 5, alpha \\ 0.5),
    to: GEPA.Adapters.GenericRAG.VectorStore

  defdelegate get_collection_info(store), to: GEPA.Adapters.GenericRAG.VectorStore
  defdelegate health_check(store), to: GEPA.Adapters.GenericRAG.VectorStore
  defdelegate create_collection(store, opts \\ []), to: GEPA.Adapters.GenericRAG.VectorStore
  defdelegate reset_collection(store, opts \\ []), to: GEPA.Adapters.GenericRAG.VectorStore

  defdelegate upsert_documents(store, documents, opts \\ []),
    to: GEPA.Adapters.GenericRAG.VectorStore

  defdelegate delete_documents(store, ids, opts \\ []), to: GEPA.Adapters.GenericRAG.VectorStore
  defdelegate embedding_dimension(store), to: GEPA.Adapters.GenericRAG.VectorStore
  defdelegate supports_hybrid_search?(store), to: GEPA.Adapters.GenericRAG.VectorStore

  defdelegate supports_metadata_filtering?(store),
    to: GEPA.Adapters.GenericRAG.VectorStore
end

defmodule GEPA.Adapters.GenericRAG.RAGEvaluationMetrics do
  @moduledoc "Compatibility facade for `GEPA.Adapters.GenericRAG.Metrics`."
  defdelegate evaluate_retrieval(retrieved_docs, relevant_doc_ids),
    to: GEPA.Adapters.GenericRAG.Metrics

  defdelegate evaluate_generation(generated_answer, ground_truth, context \\ ""),
    to: GEPA.Adapters.GenericRAG.Metrics

  defdelegate combined_rag_score(retrieval_metrics, generation_metrics, opts \\ []),
    to: GEPA.Adapters.GenericRAG.Metrics

  defdelegate exact_match?(generated, truth), to: GEPA.Adapters.GenericRAG.Metrics
  defdelegate token_f1(generated, truth), to: GEPA.Adapters.GenericRAG.Metrics
  defdelegate simple_bleu(generated, truth), to: GEPA.Adapters.GenericRAG.Metrics
  defdelegate answer_relevance(answer, context), to: GEPA.Adapters.GenericRAG.Metrics
  defdelegate faithfulness(answer, context), to: GEPA.Adapters.GenericRAG.Metrics
end
