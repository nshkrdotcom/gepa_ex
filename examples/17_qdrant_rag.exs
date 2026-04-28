#!/usr/bin/env elixir

Code.require_file("support/live_cli.exs", __DIR__)

defmodule Example17QdrantRAG do
  @moduledoc false

  alias GEPA.Adapters.GenericRAG
  alias GEPA.Adapters.GenericRAG.VectorStore
  alias GEPA.Adapters.GenericRAG.VectorStores.Qdrant

  @example [
    name: "GEPA Qdrant RAG Live Example",
    script: "examples/17_qdrant_rag.exs",
    summary:
      "Runs Generic RAG with real Qdrant storage, real ReqLLM/Gemini embeddings, and real ASM/Gemini inference.",
    required: []
  ]

  def main(argv) do
    argv = default_to_asm_gemini(argv)
    config = LiveCLI.parse_or_halt(argv, @example)
    max_metric_calls = cli_integer(argv, "--max-metric-calls") || 2
    embedding_model = config.embedding_model || "gemini-embedding-001"
    qdrant_url = config.qdrant_url || "http://localhost:6333"
    collection = config.collection || "gepa_ex_qdrant_rag"
    embedding_api_key = embedding_api_key!()
    embedder = build_embedder(embedding_model, embedding_api_key, config.embedding_dimensions)

    IO.puts(
      LiveCLI.cost_warning(@example[:name], config.adapter, config.provider, max_metric_calls * 2)
    )

    IO.puts("""
    GEPA Qdrant RAG Live Example
    ============================

    Inference adapter/provider: #{config.adapter}/#{config.provider}
    Inference model: #{config.model || "(provider default)"}
    Embedding model: #{GEPA.Embeddings.model(embedder)}
    Qdrant URL: #{qdrant_url}
    Collection: #{collection}
    Max metric calls: #{max_metric_calls}
    """)

    probe_vector = GEPA.Embeddings.embed!(embedder, "GEPA Qdrant dimension probe")

    store =
      Qdrant.new(
        url: qdrant_url,
        collection_name: collection,
        embedder: embedder,
        vector_size: length(probe_vector)
      )

    ensure_qdrant!(store, qdrant_url)
    :ok = VectorStore.reset_collection(store)
    {:ok, ids} = VectorStore.upsert_documents(store, corpus())

    adapter =
      GenericRAG.new(
        vector_store: store,
        llm_model: config.client,
        embedder: embedder,
        rag_config: %{
          "retrieval_strategy" => "similarity",
          "top_k" => 2,
          "retrieval_weight" => 0.4,
          "generation_weight" => 0.6,
          "filters" => %{source: "integration_example"}
        }
      )

    {:ok, result} =
      GEPA.optimize(
        seed_candidate: seed_candidate(),
        trainset: trainset(),
        valset: valset(),
        adapter: adapter,
        max_metric_calls: max_metric_calls,
        reflection_llm: config.client,
        reflection_minibatch_size: config.minibatch_size,
        structured_output: false
      )

    IO.puts("""

    Qdrant RAG Integration Complete
    ===============================

    Inserted documents: #{Enum.join(ids, ", ")}
    Best score: #{Float.round(GEPA.Result.best_score(result), 4)}
    Iterations: #{result.i}
    Total evaluations: #{result.total_num_evals}
    Vector store info:
    #{Jason.encode!(VectorStore.get_collection_info(store), pretty: true)}
    """)
  end

  defp build_embedder(embedding_model, api_key, dimensions) do
    GEPA.Embeddings.ReqLLM.new!(
      provider: :gemini,
      model: embedding_model,
      api_key: api_key,
      dimensions: dimensions
    )
  end

  defp ensure_qdrant!(store, qdrant_url) do
    case VectorStore.health_check(store) do
      :ok -> :ok
      {:error, reason} -> raise "Qdrant is not reachable at #{qdrant_url}: #{inspect(reason)}"
    end
  end

  defp embedding_api_key! do
    System.get_env("GEMINI_API_KEY") ||
      System.get_env("GOOGLE_API_KEY") ||
      raise("""
      missing Gemini embedding API key; set GEMINI_API_KEY or GOOGLE_API_KEY.
      Qdrant stores vectors only, so this example needs ReqLLM/Gemini to create embeddings.
      """)
  end

  defp corpus do
    [
      %{
        id: "gepa_core",
        content:
          "GEPA optimizes prompt components by evaluating candidates, reflecting on trajectories, and proposing improved instructions.",
        metadata: %{topic: "gepa", source: "integration_example"}
      },
      %{
        id: "qdrant_role",
        content:
          "Qdrant is the vector database in this example. It stores and searches embeddings but does not generate embeddings.",
        metadata: %{topic: "qdrant", source: "integration_example"}
      },
      %{
        id: "adapter_plan",
        content:
          "GEPA Elixir separates inference adapters, embedding adapters, vector-store adapters, and tracking adapters behind behaviours.",
        metadata: %{topic: "architecture", source: "integration_example"}
      }
    ]
  end

  defp trainset do
    [
      %GenericRAG.DataInst{
        query: "What does GEPA optimize and how does it improve candidates?",
        ground_truth_answer: "GEPA optimizes prompt components using evaluations and reflection.",
        relevant_doc_ids: ["gepa_core"],
        filters: %{source: "integration_example"}
      },
      %GenericRAG.DataInst{
        query: "Does Qdrant create embeddings in this setup?",
        ground_truth_answer:
          "No. ReqLLM with Gemini creates embeddings; Qdrant stores and searches vectors.",
        relevant_doc_ids: ["qdrant_role"],
        filters: %{source: "integration_example"}
      }
    ]
  end

  defp valset do
    [
      %GenericRAG.DataInst{
        query: "What integration boundaries does the Elixir GEPA port use?",
        ground_truth_answer:
          "It separates inference, embeddings, vector stores, and tracking behind behaviours.",
        relevant_doc_ids: ["adapter_plan"],
        filters: %{source: "integration_example"}
      }
    ]
  end

  defp seed_candidate do
    %{
      "answer_generation" =>
        "Answer using only the provided context. Be direct.\n\nQuery: {query}\n\nContext:\n{context}"
    }
  end

  defp default_to_asm_gemini(argv) do
    cond do
      match?(["--" | _rest], argv) ->
        ["--" | default_to_asm_gemini(tl(argv))]

      option_present?(argv, "--help") ->
        argv

      option_present?(argv, "--adapter") ->
        argv

      true ->
        ["--adapter", "asm" | argv]
    end
  end

  defp cli_integer(argv, option) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^option, value] -> String.to_integer(value)
      _other -> nil
    end)
  end

  defp option_present?(argv, option) do
    Enum.any?(argv, &(&1 == option or String.starts_with?(&1, option <> "=")))
  end
end

Example17QdrantRAG.main(System.argv())
