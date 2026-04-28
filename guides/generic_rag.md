# Generic RAG and Vector Stores

Generic RAG is headless. It optimizes prompt components for retrieval and
answer generation without owning a UI, a hosted ingestion service, or a
provider-specific vector subsystem.

## Architecture

The integration boundary is split into three behaviours/facades:

- `GEPA.LLM` handles inference through ReqLLM or Agent Session Manager.
- `GEPA.Embeddings` creates vectors. The first real adapter is `GEPA.Embeddings.ReqLLM`.
- `GEPA.Adapters.GenericRAG.VectorStore` stores and searches vectors.

Qdrant is a vector store only. It does not create embeddings. The live default
for embeddings is ReqLLM with Gemini model `google:gemini-embedding-001`.

## Vector Store Contract

The Generic RAG vector-store behaviour covers:

- `similarity_search/4`
- `vector_search/4`
- `get_collection_info/1`
- optional `hybrid_search/4`
- optional health, create, reset, upsert, delete, dimension, and capability callbacks

Search callbacks may return a list directly or `{:ok, list}` / `{:error, reason}`
for external IO backends. The pipeline fails explicitly on `{:error, reason}`.

Documents use this normalized shape:

```elixir
%{
  id: "doc-id",
  content: "document text",
  metadata: %{source: "my-corpus"},
  embedding: [0.1, 0.2, 0.3]
}
```

Search results add `:score` when the backend returns one.

## Local Qdrant

Start Qdrant:

```bash
docker compose up -d qdrant
```

Check readiness:

```bash
curl http://localhost:6333/collections
```

Stop it:

```bash
docker compose stop qdrant
```

Remove local data:

```bash
docker compose down
rm -rf tmp/qdrant
```

The default local URL is `http://localhost:6333`; `tmp/qdrant/` is gitignored.

## ReqLLM Embeddings

Build an embedder:

```elixir
embedder =
  GEPA.Embeddings.ReqLLM.new!(
    provider: :gemini,
    model: "gemini-embedding-001",
    api_key: System.fetch_env!("GEMINI_API_KEY")
  )

{:ok, vector} = GEPA.Embeddings.embed(embedder, "GEPA optimizes prompts.")
dimension = length(vector)
```

`GEMINI_API_KEY` and `GOOGLE_API_KEY` are both accepted by the example path.

## Qdrant Adapter

Create a collection and upsert documents:

```elixir
store =
  GEPA.Adapters.GenericRAG.VectorStores.Qdrant.new(
    url: "http://localhost:6333",
    collection_name: "gepa_docs",
    embedder: embedder,
    vector_size: dimension
  )

:ok = GEPA.Adapters.GenericRAG.VectorStore.health_check(store)
:ok = GEPA.Adapters.GenericRAG.VectorStore.reset_collection(store)

{:ok, _ids} =
  GEPA.Adapters.GenericRAG.VectorStore.upsert_documents(store, [
    %{id: "one", content: "GEPA uses reflection.", metadata: %{topic: "gepa"}}
  ])
```

The Qdrant adapter currently uses direct HTTP calls through `Req`. That is
intentional: the module is small and replaceable by a proper Qdrant client or a
larger vector subsystem later.

## Live Example

Run the complete live smoke:

```bash
docker compose up -d qdrant
mix run examples/17_qdrant_rag.exs -- --simple
```

This uses:

- Qdrant at `http://localhost:6333`
- ReqLLM/Gemini embeddings with `google:gemini-embedding-001`
- Agent Session Manager/Gemini inference with `gemini-3.1-flash-lite-preview`

Override service settings:

```bash
mix run examples/17_qdrant_rag.exs -- \
  --adapter asm \
  --provider gemini \
  --qdrant-url http://localhost:6333 \
  --collection gepa_ex_qdrant_rag \
  --embedding-model gemini-embedding-001 \
  --max-metric-calls 2
```

## Stub Backends

These modules compile and fail explicitly with `{:error, {:not_configured, backend}}`:

- `GEPA.Adapters.GenericRAG.VectorStores.Pgvector`
- `GEPA.Adapters.GenericRAG.VectorStores.Weaviate`
- `GEPA.Adapters.GenericRAG.VectorStores.LanceDB`
- `GEPA.Adapters.GenericRAG.VectorStores.Chroma`
- `GEPA.Adapters.GenericRAG.VectorStores.Milvus`

They are placeholders for a future vector subsystem, not hidden fallbacks.
