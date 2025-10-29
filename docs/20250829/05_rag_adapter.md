# RAG Adapter - Comprehensive Technical Documentation

## Overview

The Generic RAG (Retrieval-Augmented Generation) Adapter is one of the most sophisticated adapters in the GEPA library, providing a complete framework for optimizing RAG systems with pluggable vector store support. Unlike other adapters that primarily focus on prompt optimization, the RAG adapter orchestrates a multi-stage pipeline involving retrieval, reranking, context synthesis, and generation.

### Key Capabilities

- **Vector Store Abstraction**: Unified interface supporting ChromaDB, Weaviate, Qdrant, Milvus, and LanceDB
- **Multi-Stage Pipeline**: Query reformulation → Retrieval → Reranking → Context synthesis → Answer generation
- **Comprehensive Evaluation**: Dual metrics for both retrieval quality and generation quality
- **Hybrid Search Support**: Combines semantic similarity with keyword-based search where supported
- **Component-Level Optimization**: Independently optimize each pipeline stage with targeted prompts

## Architecture Overview

### Component Structure

```
generic_rag_adapter/
├── __init__.py                    # Module exports and optional imports
├── generic_rag_adapter.py         # Main adapter implementation
├── rag_pipeline.py                # RAG orchestration logic
├── evaluation_metrics.py          # Retrieval and generation metrics
├── vector_store_interface.py      # Abstract base class for vector stores
└── vector_stores/                 # Concrete implementations
    ├── __init__.py
    ├── chroma_store.py            # ChromaDB implementation
    ├── weaviate_store.py          # Weaviate with hybrid search
    ├── qdrant_store.py            # Qdrant with filtering
    ├── milvus_store.py            # Milvus cloud-native
    └── lancedb_store.py           # LanceDB serverless
```

### Data Flow

```
User Query
    ↓
[Query Reformulation] ← Optional prompt component
    ↓
[Vector Store Retrieval] ← similarity/hybrid/vector search
    ↓
[Document Reranking] ← Optional prompt-based reranking
    ↓
[Context Synthesis] ← Optional prompt-based synthesis
    ↓
[Answer Generation] ← Required prompt component
    ↓
Final Answer + Metadata
```

## Core Components

### 1. GenericRAGAdapter (generic_rag_adapter.py)

The main adapter class implementing the `GEPAAdapter` interface for RAG systems.

#### Type Definitions

**RAGDataInst** - Training/validation examples:
```python
class RAGDataInst(TypedDict):
    query: str                      # User question
    ground_truth_answer: str        # Expected answer
    relevant_doc_ids: list[str]     # Docs that should be retrieved
    metadata: dict[str, Any]        # Additional context
```

**RAGTrajectory** - Execution trace (for reflective learning):
```python
class RAGTrajectory(TypedDict):
    original_query: str             # Original user query
    reformulated_query: str         # After query reformulation
    retrieved_docs: list[dict]      # Retrieved documents with scores
    synthesized_context: str        # Synthesized context
    generated_answer: str           # Final generated answer
    execution_metadata: dict        # Metrics and performance data
```

**RAGOutput** - Final result:
```python
class RAGOutput(TypedDict):
    final_answer: str               # Generated answer
    confidence_score: float         # Estimated confidence (0-1)
    retrieved_docs: list[dict]      # Documents used
    total_tokens: int               # Estimated token usage
```

#### Initialization

```python
def __init__(
    self,
    vector_store: VectorStoreInterface,
    llm_model,                      # LLM client or model name
    embedding_model: str = "text-embedding-3-small",
    embedding_function=None,        # Custom embedding function
    rag_config: dict | None = None, # Pipeline configuration
    failure_score: float = 0.0      # Score for failed evaluations
)
```

**Configuration Options** (rag_config):
- `retrieval_strategy`: "similarity" | "hybrid" | "vector"
- `top_k`: Number of documents to retrieve (default: 5)
- `retrieval_weight`: Weight for retrieval metrics (default: 0.3)
- `generation_weight`: Weight for generation metrics (default: 0.7)
- `hybrid_alpha`: Semantic vs keyword balance (default: 0.5)
- `filters`: Metadata filters for retrieval

#### Optimizable Prompt Components

The adapter supports optimization of four prompt components:

1. **query_reformulation**: Transform user queries for better retrieval
   - Input: Original user query
   - Output: Reformulated query for vector search
   - When: Before document retrieval

2. **context_synthesis**: Combine multiple documents into coherent context
   - Input: Retrieved documents + original query
   - Output: Synthesized context for generation
   - When: After retrieval, before generation

3. **answer_generation**: Generate final answer from context
   - Input: Query + synthesized context
   - Output: Final answer to user
   - When: Final pipeline stage (required)

4. **reranking_criteria**: Reorder retrieved documents by relevance
   - Input: Query + retrieved documents
   - Output: Reordered document list
   - When: After retrieval, before synthesis

#### Evaluation Method

```python
def evaluate(
    self,
    batch: list[RAGDataInst],
    candidate: dict[str, str],      # Prompt components to test
    capture_traces: bool = False    # Capture trajectories
) -> EvaluationBatch[RAGTrajectory, RAGOutput]
```

**Process**:
1. Execute RAG pipeline for each example
2. Evaluate retrieval quality (precision, recall, F1, MRR)
3. Evaluate generation quality (token F1, BLEU, faithfulness, relevance)
4. Calculate combined score using weighted metrics
5. Optionally capture execution trajectories

**Error Handling**: Individual failures return failure_score without halting batch

#### Reflective Dataset Generation

```python
def make_reflective_dataset(
    self,
    candidate: dict[str, str],
    eval_batch: EvaluationBatch[RAGTrajectory, RAGOutput],
    components_to_update: list[str]
) -> dict[str, list[dict[str, Any]]]
```

Creates component-specific improvement examples by analyzing:
- Query reformulation effectiveness
- Context synthesis quality
- Answer generation accuracy
- Document reranking impact

Each reflective example includes:
- **Inputs**: Component inputs (query, docs, current prompt)
- **Generated Outputs**: What the component currently produces
- **Feedback**: Performance analysis and improvement suggestions

### 2. RAGPipeline (rag_pipeline.py)

Orchestrates the complete RAG execution flow.

#### Pipeline Stages

**Stage 1: Query Reformulation** (Optional)
```python
def _reformulate_query(self, query: str, reformulation_prompt: str) -> str
```
- Uses LLM to transform query for better retrieval
- Falls back to original query on failure
- Enabled when `query_reformulation` prompt provided

**Stage 2: Document Retrieval** (Required)
```python
def _retrieve_documents(self, query: str, config: dict) -> list[dict]
```
- Supports three strategies:
  - **similarity**: Text-based semantic search
  - **hybrid**: Combines semantic + keyword (if supported)
  - **vector**: Uses pre-computed embeddings
- Returns documents with content, metadata, and scores

**Stage 3: Document Reranking** (Optional)
```python
def _rerank_documents(
    self,
    documents: list[dict],
    query: str,
    reranking_prompt: str,
    config: dict
) -> list[dict]
```
- Uses LLM with reranking criteria to reorder documents
- Prompts LLM to return ordered document numbers
- Falls back to original order on failure
- Enabled when `reranking_criteria` prompt provided

**Stage 4: Context Synthesis** (Optional)
```python
def _synthesize_context(
    self,
    documents: list[dict],
    query: str,
    synthesis_prompt: str
) -> str
```
- Two modes:
  - **Default**: Simple concatenation with document markers
  - **LLM-based**: Uses prompt to synthesize coherent context
- Falls back to concatenation on failure

**Stage 5: Answer Generation** (Required)
```python
def _generate_answer(self, query: str, context: str, generation_prompt: str) -> str
```
- Uses LLM to generate final answer
- Default prompt provided if none specified
- Returns error message on failure

#### Pipeline Execution

```python
def execute_rag(
    self,
    query: str,
    prompts: dict[str, str],
    config: dict[str, Any]
) -> dict[str, Any]
```

Returns complete execution trace:
```python
{
    "original_query": str,
    "reformulated_query": str,
    "retrieved_docs": list[dict],
    "synthesized_context": str,
    "generated_answer": str,
    "metadata": {
        "retrieval_count": int,
        "total_tokens": int,
        "vector_store_type": str
    }
}
```

#### Embedding Function

```python
def _default_embedding_function(self, text: str) -> list[float]
```
- Uses litellm for embedding generation
- Configurable model via `embedding_model` parameter
- Custom functions can be provided during initialization

### 3. RAGEvaluationMetrics (evaluation_metrics.py)

Provides comprehensive metrics for both retrieval and generation quality.

#### Retrieval Metrics

```python
def evaluate_retrieval(
    self,
    retrieved_docs: list[dict[str, Any]],
    relevant_doc_ids: list[str]
) -> dict[str, float]
```

**Metrics Computed**:

1. **Precision**: What fraction of retrieved docs are relevant?
   ```python
   precision = len(relevant ∩ retrieved) / len(retrieved)
   ```

2. **Recall**: What fraction of relevant docs were retrieved?
   ```python
   recall = len(relevant ∩ retrieved) / len(relevant)
   ```

3. **F1 Score**: Harmonic mean of precision and recall
   ```python
   f1 = 2 * (precision * recall) / (precision + recall)
   ```

4. **Mean Reciprocal Rank (MRR)**: Position of first relevant doc
   ```python
   mrr = 1 / (position of first relevant doc)
   ```

Returns:
```python
{
    "retrieval_precision": float,
    "retrieval_recall": float,
    "retrieval_f1": float,
    "retrieval_mrr": float
}
```

#### Generation Metrics

```python
def evaluate_generation(
    self,
    generated_answer: str,
    ground_truth: str,
    context: str
) -> dict[str, float]
```

**Metrics Computed**:

1. **Exact Match**: Case-insensitive full answer match
   ```python
   exact_match = (prediction.lower() == ground_truth.lower())
   ```

2. **Token F1**: Overlap of word tokens
   ```python
   precision = len(pred_tokens ∩ truth_tokens) / len(pred_tokens)
   recall = len(pred_tokens ∩ truth_tokens) / len(truth_tokens)
   f1 = 2 * (precision * recall) / (precision + recall)
   ```

3. **BLEU Score**: N-gram overlap (default n=2)
   ```python
   bleu = len(pred_ngrams ∩ truth_ngrams) / len(pred_ngrams)
   ```

4. **Answer Relevance**: Overlap with context
   ```python
   relevance = len(answer_words ∩ context_words) / len(answer_words)
   ```

5. **Faithfulness**: How well answer is supported by context
   ```python
   faithfulness = len(supported_phrases) / len(answer_phrases)
   ```
   - Extracts key phrases (2-4 word sequences)
   - Checks if answer phrases appear in context

6. **Answer Confidence**: Combined metric
   ```python
   confidence = (token_f1 + relevance + faithfulness) / 3.0
   ```

Returns:
```python
{
    "exact_match": float,
    "token_f1": float,
    "bleu_score": float,
    "answer_relevance": float,
    "faithfulness": float,
    "answer_confidence": float
}
```

#### Combined RAG Score

```python
def combined_rag_score(
    self,
    retrieval_metrics: dict[str, float],
    generation_metrics: dict[str, float],
    retrieval_weight: float = 0.3,
    generation_weight: float = 0.7
) -> float
```

**Calculation**:
```python
retrieval_score = retrieval_f1
generation_score = (
    token_f1 * 0.4 +
    answer_relevance * 0.3 +
    faithfulness * 0.3
)
combined = (
    retrieval_weight * retrieval_score +
    generation_weight * generation_score
)
```

**Default Weights**: 30% retrieval, 70% generation
- Reflects typical importance in RAG systems
- Configurable via rag_config

#### Text Normalization

All metrics use normalized text for fair comparison:
```python
def _normalize_text(self, text: str) -> str
```
- Lowercase conversion
- Punctuation removal
- Whitespace normalization

### 4. VectorStoreInterface (vector_store_interface.py)

Abstract base class defining the contract for all vector store implementations.

#### Core Methods

**Similarity Search** (Required):
```python
@abstractmethod
def similarity_search(
    self,
    query: str,
    k: int = 5,
    filters: dict[str, Any] | None = None
) -> list[dict[str, Any]]
```
- Semantic search using query text
- Returns top-k most similar documents
- Each result includes:
  - `content`: Document text
  - `metadata`: Document metadata (including doc_id)
  - `score`: Similarity score (0.0-1.0, higher is better)

**Vector Search** (Required):
```python
@abstractmethod
def vector_search(
    self,
    query_vector: list[float],
    k: int = 5,
    filters: dict[str, Any] | None = None
) -> list[dict[str, Any]]
```
- Direct vector similarity search
- Uses pre-computed embeddings
- Same return format as similarity_search

**Collection Info** (Required):
```python
@abstractmethod
def get_collection_info(self) -> dict[str, Any]
```
- Returns metadata about the collection:
  - `name`: Collection name
  - `document_count`: Total documents
  - `dimension`: Vector dimension
  - `vector_store_type`: Store identifier

**Hybrid Search** (Optional):
```python
def hybrid_search(
    self,
    query: str,
    k: int = 5,
    alpha: float = 0.5,
    filters: dict[str, Any] | None = None
) -> list[dict[str, Any]]
```
- Combines semantic + keyword search
- alpha parameter:
  - 0.0 = pure keyword (BM25)
  - 1.0 = pure semantic (vector)
  - 0.5 = balanced hybrid
- Default implementation falls back to similarity_search

#### Capability Methods

```python
def supports_hybrid_search(self) -> bool
def supports_metadata_filtering(self) -> bool
def get_embedding_dimension(self) -> int
```

#### Filter Format

Generic filter format (converted by each implementation):
```python
filters = {
    "key": "value",              # Exact match
    "key2": {"$gt": 5},          # Greater than
    "key3": ["val1", "val2"],    # Match any
    "key4": {                    # Range query
        "gte": 10,
        "lt": 100
    }
}
```

## Vector Store Implementations

### 1. ChromaVectorStore (chroma_store.py)

**Characteristics**:
- Local/persistent storage
- Simple setup, no external dependencies
- Built-in embedding functions
- SQLite-based backend

**Features**:
- Metadata filtering with operator support
- Document and embedding storage
- Persistent and in-memory modes

**Implementation Details**:

```python
class ChromaVectorStore(VectorStoreInterface):
    def __init__(self, client, collection_name: str, embedding_function=None)
```

**Factory Methods**:
```python
@classmethod
def create_local(
    cls,
    persist_directory: str,
    collection_name: str,
    embedding_function=None
) -> "ChromaVectorStore"

@classmethod
def create_memory(
    cls,
    collection_name: str,
    embedding_function=None
) -> "ChromaVectorStore"
```

**Filter Conversion**:
```python
# Generic format
{"category": "AI", "score": {"$gt": 0.8}}

# ChromaDB format
{"category": {"$eq": "AI"}, "score": {"$gt": 0.8}}
```

**Distance to Similarity**:
- ChromaDB returns cosine distance (0-2)
- Converted to similarity: `1 - distance`
- Handles numpy scalars and array types

**Embedding Function**:
- Can use ChromaDB's DefaultEmbeddingFunction
- Or custom functions via parameter
- Function applied automatically in query()

### 2. WeaviateVectorStore (weaviate_store.py)

**Characteristics**:
- Cloud-native vector database
- Native hybrid search support
- Powerful filtering capabilities
- Both local and cloud deployments

**Features**:
- Hybrid semantic + keyword search (BM25)
- GraphQL-based API
- Named vectors support
- Advanced inverted index configuration

**Implementation Details**:

```python
class WeaviateVectorStore(VectorStoreInterface):
    def __init__(self, client, collection_name: str, embedding_function=None)
```

**Factory Methods**:
```python
@classmethod
def create_local(
    cls,
    host: str = "localhost",
    port: int = 8080,
    grpc_port: int = 50051,
    collection_name: str = "Documents",
    headers: dict[str, str] | None = None
) -> "WeaviateVectorStore"

@classmethod
def create_cloud(
    cls,
    cluster_url: str,
    auth_credentials,
    collection_name: str = "Documents",
    headers: dict[str, str] | None = None
) -> "WeaviateVectorStore"

@classmethod
def create_custom(
    cls,
    url: str,
    auth_credentials=None,
    collection_name: str = "Documents",
    headers: dict[str, str] | None = None,
    grpc_port: int | None = None
) -> "WeaviateVectorStore"
```

**Hybrid Search**:
```python
def hybrid_search(
    self,
    query: str,
    k: int = 5,
    alpha: float = 0.5,  # 0=keyword, 1=semantic
    filters: dict[str, Any] | None = None
) -> list[dict[str, Any]]
```
- Native Weaviate hybrid query
- Combines vector similarity with BM25
- Configurable weighting via alpha

**Filter Conversion**:
```python
# Generic format
{"category": "AI", "score": {"$gt": 0.8}}

# Weaviate Filter format
Filter.by_property("category").equal("AI") &
Filter.by_property("score").greater_than(0.8)
```

Supported operators:
- `$eq`: equal
- `$ne`: not_equal
- `$gt`: greater_than
- `$gte`: greater_or_equal
- `$lt`: less_than
- `$lte`: less_or_equal
- `$in`: contains_any
- `$like`: like (pattern matching)

**Result Formatting**:
- Handles both GenerativeReturn and direct lists
- Extracts content from multiple field names
- UUID stored as doc_id
- Score from metadata.score or converted from distance

**Content Field Priority**:
Tries fields in order: content, text, document, body, description

### 3. QdrantVectorStore (qdrant_store.py)

**Characteristics**:
- High-performance Rust-based core
- Excellent filtering capabilities
- Both REST and gRPC APIs
- In-memory and persistent modes

**Features**:
- Advanced payload filtering
- Quantization support
- Distributed deployment ready
- Snapshot and backup support

**Implementation Details**:

```python
class QdrantVectorStore(VectorStoreInterface):
    def __init__(self, client, collection_name: str, embedding_function=None)
```

**Factory Methods**:
```python
@classmethod
def create_local(
    cls,
    collection_name: str,
    embedding_function=None,
    path: str = ":memory:",
    vector_size: int = 384
)

@classmethod
def create_remote(
    cls,
    collection_name: str,
    embedding_function=None,
    host: str = "localhost",
    port: int = 6333,
    api_key: str | None = None,
    vector_size: int = 384
)
```

**Document Management**:
```python
def add_documents(
    self,
    documents: list[dict[str, Any]],
    embeddings: list[list[float]],
    ids: list[str] | None = None
) -> list[str]

def delete_documents(self, ids: list[str]) -> bool
```

**ID Handling**:
- Qdrant requires integer IDs
- Stores original string IDs in payload as `original_id`
- Maps between formats automatically

**Filter Conversion**:
```python
# Generic format
{"category": "AI", "score": {"gte": 0.8, "lt": 1.0}}

# Qdrant Filter format
Filter(must=[
    FieldCondition(key="category", match=MatchValue(value="AI")),
    FieldCondition(key="score", range=Range(gte=0.8, lt=1.0))
])
```

Supported types:
- String: MatchValue
- Numeric: MatchValue or Range
- List: MatchAny
- Range: gte, gt, lte, lt

**Query API**:
- Uses modern `query_points` API
- Supports score thresholds
- Returns similarity scores (higher is better)

**Collection Info**:
- Handles both named and unnamed vectors
- Returns distance metric configuration
- Provides collection status

### 4. MilvusVectorStore (milvus_store.py)

**Characteristics**:
- Cloud-native, built for scale
- Multiple index types (HNSW, IVF, etc.)
- Milvus Lite for local development
- Production-ready clustering

**Features**:
- Dynamic schema with enable_dynamic_field
- Multiple distance metrics (COSINE, L2, IP)
- Index configuration per field
- Time travel queries

**Implementation Details**:

```python
class MilvusVectorStore(VectorStoreInterface):
    def __init__(self, client, collection_name: str, embedding_function=None)
```

**Factory Methods**:
```python
@classmethod
def create_local(
    cls,
    collection_name: str,
    embedding_function=None,
    vector_size: int = 384,
    uri: str = "./milvus_demo.db"
)

@classmethod
def create_remote(
    cls,
    collection_name: str,
    embedding_function=None,
    uri: str = "http://localhost:19530",
    user: str = "",
    password: str = "",
    token: str = "",
    vector_size: int = 384
)
```

**Schema Management**:
```python
# Explicit schema creation
schema = client.create_schema(
    auto_id=False,
    enable_dynamic_field=True  # Allows flexible metadata
)

# Required fields
schema.add_field(
    field_name="id",
    datatype=DataType.VARCHAR,
    is_primary=True,
    max_length=512
)

schema.add_field(
    field_name="vector",
    datatype=DataType.FLOAT_VECTOR,
    dim=vector_size
)

schema.add_field(
    field_name="content",
    datatype=DataType.VARCHAR,
    max_length=65535
)
```

**Index Configuration**:
```python
index_params = client.prepare_index_params()
index_params.add_index(
    field_name="vector",
    metric_type="COSINE"
)
client.create_index(collection_name, index_params)
```

**Filter Conversion**:
```python
# Generic format
{"category": "AI", "score": {"gte": 0.8}}

# Milvus expression format
'category == "AI" and score >= 0.8'
```

Supported expressions:
- Equality: `field == value`
- Comparison: `field > value`, `field >= value`, etc.
- IN clause: `field in ["val1", "val2"]`
- AND/OR: `expr1 and expr2`

**Document Management**:
```python
def add_documents(
    self,
    documents: list[dict[str, Any]],
    embeddings: list[list[float]],
    ids: list[str] | None = None
) -> list[str]

def delete_documents(self, ids: list[str]) -> bool
```

**Collection Loading**:
- Must load collection into memory for search
- Auto-loads on initialization
- Required for query operations

**Distance to Similarity**:
- For COSINE: `similarity = 1 - distance` (if distance ≤ 1)
- For L2: `similarity = 1 / (1 + distance)`

### 5. LanceDBVectorStore (lancedb_store.py)

**Characteristics**:
- Developer-friendly serverless DB
- Apache Arrow/Parquet based
- SQL-like filtering
- Local and cloud deployment

**Features**:
- Full-text search integration
- PyArrow DataFrame integration
- Automatic schema inference
- Version control for data

**Implementation Details**:

```python
class LanceDBVectorStore(VectorStoreInterface):
    def __init__(self, db, table_name: str, embedding_function=None)
```

**Factory Methods**:
```python
@classmethod
def create_local(
    cls,
    table_name: str,
    embedding_function=None,
    db_path: str = "./lancedb",
    vector_size: int = 384
)

@classmethod
def create_remote(
    cls,
    table_name: str,
    embedding_function=None,
    uri: str | None = None,
    api_key: str | None = None,
    region: str = "us-east-1",
    vector_size: int = 384
)
```

**Table Creation**:
```python
# Deferred until first add_documents call
# Allows LanceDB to infer schema from data
if self.table is None:
    self.table = self.db.create_table(table_name, data=data_to_insert)
else:
    self.table.add(data_to_insert, mode="append")
```

**Hybrid Search**:
```python
def hybrid_search(
    self,
    query: str,
    k: int = 5,
    alpha: float = 0.5,
    filters: dict[str, Any] | None = None
) -> list[dict[str, Any]]
```
- Combines vector search with full-text search (FTS)
- Uses LanceDB's FtsQuery for text matching
- Falls back to vector-only if FTS unavailable

**Filter Conversion**:
```python
# Generic format
{"category": "AI", "score": {"gte": 0.8}}

# LanceDB SQL format
"category = 'AI' AND score >= 0.8"
```

String escaping:
```python
# Properly escapes quotes and backslashes
value.replace("\\", "\\\\").replace("'", "''")
```

**Query Building**:
```python
query_builder = self.table.search(query_vector).limit(k)
if filters:
    query_builder = query_builder.where(filter_expr)
results = query_builder.to_pandas()
```

**Result Formatting**:
- Results returned as pandas DataFrame
- Converts numpy types to Python types
- Handles `_distance` column automatically
- Extracts content from multiple field names

**Distance to Similarity**:
```python
if distance <= 1.0:
    score = max(0.0, 1.0 - distance)  # Cosine-like
else:
    score = 1.0 / (1.0 + distance)     # L2-like
```

**Document Management**:
```python
def add_documents(
    self,
    documents: list[dict[str, Any]],
    embeddings: list[list[float]],
    ids: list[str] | None = None
) -> list[str]

def delete_documents(self, ids: list[str]) -> bool
```

## Vector Store Comparison Matrix

| Feature | ChromaDB | Weaviate | Qdrant | Milvus | LanceDB |
|---------|----------|----------|--------|--------|---------|
| **Deployment** | Local | Local/Cloud | Local/Cloud | Local/Cloud | Local/Cloud |
| **Setup Complexity** | Low | Medium | Low | Medium | Low |
| **External Dependencies** | None | Docker (local) | Optional | Optional | None |
| **Hybrid Search** | No | Yes (native) | Limited | Limited | Yes (FTS) |
| **Metadata Filtering** | Yes | Yes (advanced) | Yes (advanced) | Yes | Yes (SQL) |
| **Distance Metrics** | Cosine, L2, IP | Multiple | Cosine, Dot, Euclidean | Multiple | Cosine, L2 |
| **Dynamic Schema** | Yes | No | Yes | Yes (with flag) | Yes |
| **Production Scale** | Small-Medium | Large | Large | Very Large | Small-Large |
| **Best For** | Prototyping | Production hybrid search | High-performance filtering | Large-scale deployments | Developer productivity |

## RAG Optimization Workflow

### 1. Initial Setup

```python
from gepa.adapters.generic_rag_adapter import (
    GenericRAGAdapter,
    ChromaVectorStore,
    RAGDataInst
)

# Create vector store
vector_store = ChromaVectorStore.create_local(
    persist_directory="./my_kb",
    collection_name="documents"
)

# Populate with documents
# ... add documents to vector store ...

# Create adapter
adapter = GenericRAGAdapter(
    vector_store=vector_store,
    llm_model="gpt-4o-mini",
    rag_config={
        "retrieval_strategy": "similarity",
        "top_k": 5,
        "retrieval_weight": 0.3,
        "generation_weight": 0.7
    }
)
```

### 2. Prepare Training Data

```python
train_data = [
    RAGDataInst(
        query="What is machine learning?",
        ground_truth_answer="Machine learning is...",
        relevant_doc_ids=["doc_001", "doc_042"],
        metadata={"category": "definition"}
    ),
    # ... more examples ...
]

val_data = [
    # ... validation examples ...
]
```

### 3. Define Initial Prompts

```python
seed_prompts = {
    "answer_generation": """
        You are an expert AI assistant. Answer the question
        based on the provided context. Be accurate and concise.

        Context: {context}
        Question: {query}
        Answer:
    """,

    "query_reformulation": """
        Reformulate the user's query to be more specific
        and suitable for semantic search in a knowledge base.

        Original query: {query}
        Reformulated query:
    """,

    "context_synthesis": """
        Synthesize the following documents into a coherent
        context that addresses the query.

        Query: {query}
        Documents: {documents}
        Synthesized context:
    """
}
```

### 4. Run GEPA Optimization

```python
import gepa

result = gepa.optimize(
    seed_candidate=seed_prompts,
    trainset=train_data,
    valset=val_data,
    adapter=adapter,
    max_metric_calls=50,
    components_to_optimize=[
        "answer_generation",
        "query_reformulation",
        "context_synthesis"
    ]
)

# Access optimized prompts
best_prompts = result.best_candidate
print(f"Best score: {result.val_aggregate_scores[result.best_idx]}")
```

### 5. Evaluate Results

```python
# Test optimized system
eval_batch = adapter.evaluate(
    batch=val_data,
    candidate=best_prompts,
    capture_traces=True
)

# Analyze performance
for i, (output, score, trajectory) in enumerate(
    zip(eval_batch.outputs, eval_batch.scores, eval_batch.trajectories)
):
    print(f"\nExample {i+1}:")
    print(f"  Score: {score:.3f}")
    print(f"  Answer: {output['final_answer'][:100]}...")
    print(f"  Retrieved docs: {len(trajectory['retrieved_docs'])}")
    print(f"  Retrieval F1: {trajectory['execution_metadata']['retrieval_metrics']['retrieval_f1']:.3f}")
    print(f"  Generation F1: {trajectory['execution_metadata']['generation_metrics']['token_f1']:.3f}")
```

## Key Differences from Other Adapters

### 1. Multi-Stage Pipeline

Unlike `DefaultAdapter` (single LLM call) or `DSPyAdapter` (single program), RAG adapter orchestrates:
- Query transformation
- Vector retrieval
- Document reranking
- Context synthesis
- Answer generation

### 2. External Dependencies

RAG adapter requires:
- Vector store (database)
- Embedding model
- Document corpus
- LLM for generation

Other adapters only need LLM access.

### 3. Dual Evaluation

Evaluates both:
- **Retrieval**: Are the right documents found?
- **Generation**: Is the answer correct?

Other adapters only evaluate final output.

### 4. Infrastructure Complexity

Setup involves:
- Initializing vector store
- Populating with documents
- Configuring embedding function
- Managing external services (for some stores)

### 5. Prompt Scoping

Each prompt component has specific scope:
- `query_reformulation`: Query text only
- `reranking_criteria`: Documents + query
- `context_synthesis`: Documents + query
- `answer_generation`: Context + query

Other adapters typically have single prompt scope.

## Considerations for Elixir Port

### 1. Vector Store Clients

**Available Elixir Libraries**:

- **Qdrant**: `qdrant_ex` (community library)
  - HTTP client for Qdrant
  - May need gRPC support for production

- **Weaviate**: HTTP client via `HTTPoison` or `Req`
  - REST API well-documented
  - GraphQL queries possible

- **Milvus**: HTTP/gRPC client needed
  - Consider `grpc` library
  - REST API available

- **ChromaDB**: HTTP client via `HTTPoison`
  - REST API available
  - May lack some features

- **LanceDB**: May need Rust NIFs
  - Arrow/Parquet support needed
  - Consider `explorer` for DataFrames

**Recommendation**: Start with Qdrant or Weaviate (good HTTP APIs)

### 2. Concurrent Request Handling

**Python Approach**: Sequential processing
```python
for data_inst in batch:
    result = self.rag_pipeline.execute_rag(...)
```

**Elixir Approach**: Leverage OTP for concurrency
```elixir
batch
|> Task.async_stream(&execute_rag/1, max_concurrency: 10)
|> Enum.map(&handle_result/1)
```

**Benefits**:
- Parallel vector searches
- Concurrent LLM calls
- Better throughput for large batches

**Considerations**:
- Rate limiting for LLM APIs
- Connection pooling for vector stores
- Memory usage for large batches

### 3. Streaming Support

**Current Python**: No streaming
```python
answer = self._generate_answer(query, context, prompt)
# Waits for complete response
```

**Elixir Opportunity**: Stream responses
```elixir
RAGPipeline.generate_answer(query, context, prompt)
|> Stream.map(&process_token/1)
|> Stream.each(&send_to_client/1)
|> Stream.run()
```

**Use Cases**:
- Real-time UI updates
- Early stopping on bad responses
- Reduced perceived latency

### 4. Embedding Caching

**Strategy**: Cache embeddings to avoid recomputation
```elixir
defmodule EmbeddingCache do
  use GenServer

  def get_or_compute(text, embedding_fn) do
    case :ets.lookup(:embeddings, text) do
      [{^text, embedding}] -> embedding
      [] ->
        embedding = embedding_fn.(text)
        :ets.insert(:embeddings, {text, embedding})
        embedding
    end
  end
end
```

**Benefits**:
- Faster query reformulation
- Reduced API calls
- Lower costs

### 5. Process Architecture

**Proposed Structure**:
```elixir
VectorStorePool (Poolboy/Supervisor)
├── VectorStoreWorker (GenServer)
│   └── HTTP Client
└── ...

RAGPipeline (GenServer)
├── QueryReformulator
├── DocumentRetriever
├── ContextSynthesizer
└── AnswerGenerator

EvaluationMetrics (module functions)
```

**Benefits**:
- Fault tolerance
- Connection pooling
- State management
- Graceful degradation

### 6. Error Handling

**Python Approach**: Try/catch with fallbacks
```python
try:
    reformulated = self._reformulate_query(...)
except Exception:
    reformulated = query  # Fallback
```

**Elixir Approach**: Pattern matching and supervision
```elixir
case QueryReformulator.reformulate(query) do
  {:ok, reformulated} -> reformulated
  {:error, _reason} -> query  # Fallback
end
```

**Supervision Strategy**:
- Restart workers on crash
- Circuit breakers for external services
- Graceful degradation

### 7. Configuration Management

**Recommended Approach**:
```elixir
config :gepa_ex, :rag,
  retrieval_strategy: :similarity,
  top_k: 5,
  retrieval_weight: 0.3,
  generation_weight: 0.7,
  timeout: 30_000

config :gepa_ex, :vector_store,
  adapter: GepaEx.VectorStore.Qdrant,
  host: "localhost",
  port: 6333,
  pool_size: 10
```

### 8. Type Safety

**Python**: TypedDict with runtime validation
```python
class RAGDataInst(TypedDict):
    query: str
    ground_truth_answer: str
    relevant_doc_ids: list[str]
    metadata: dict[str, Any]
```

**Elixir**: Structs with typespecs
```elixir
defmodule GepaEx.RAGDataInst do
  @type t :: %__MODULE__{
    query: String.t(),
    ground_truth_answer: String.t(),
    relevant_doc_ids: [String.t()],
    metadata: map()
  }

  @enforce_keys [:query, :ground_truth_answer, :relevant_doc_ids]
  defstruct [:query, :ground_truth_answer, :relevant_doc_ids, metadata: %{}]
end
```

### 9. Vector Store Protocol

**Elixir Protocol Approach**:
```elixir
defprotocol GepaEx.VectorStore do
  @spec similarity_search(t(), String.t(), keyword()) ::
    {:ok, [document()]} | {:error, term()}
  def similarity_search(store, query, opts \\ [])

  @spec vector_search(t(), [float()], keyword()) ::
    {:ok, [document()]} | {:error, term()}
  def vector_search(store, vector, opts \\ [])

  @spec get_collection_info(t()) ::
    {:ok, map()} | {:error, term()}
  def get_collection_info(store)
end

defimpl GepaEx.VectorStore, for: GepaEx.VectorStore.Qdrant do
  def similarity_search(store, query, opts) do
    # Implementation
  end
end
```

**Benefits**:
- Polymorphic behavior
- Type safety
- Clear contracts
- Easy testing with mocks

### 10. Metric Calculations

**Consider Nx for numerical operations**:
```elixir
defmodule GepaEx.RAGMetrics do
  import Nx.Defn

  defn token_f1(pred_tokens, truth_tokens) do
    intersection = Nx.logical_and(pred_tokens, truth_tokens)
    precision = Nx.sum(intersection) / Nx.sum(pred_tokens)
    recall = Nx.sum(intersection) / Nx.sum(truth_tokens)
    2 * precision * recall / (precision + recall)
  end
end
```

**Benefits**:
- GPU acceleration (if available)
- Efficient batch operations
- Numerical stability

### 11. Testing Strategy

**Mock Vector Stores**:
```elixir
defmodule GepaEx.VectorStore.Mock do
  @behaviour GepaEx.VectorStore

  def similarity_search(_store, _query, _opts) do
    {:ok, [
      %{content: "Mock doc", metadata: %{doc_id: "1"}, score: 0.9}
    ]}
  end
end
```

**Property-Based Testing**:
```elixir
property "retrieval metrics are between 0 and 1" do
  check all(
    retrieved <- list_of(doc()),
    relevant <- list_of(string())
  ) do
    metrics = RAGMetrics.evaluate_retrieval(retrieved, relevant)

    assert metrics.retrieval_precision >= 0.0
    assert metrics.retrieval_precision <= 1.0
    assert metrics.retrieval_f1 >= 0.0
    assert metrics.retrieval_f1 <= 1.0
  end
end
```

### 12. Integration Patterns

**Vector Store Connection**:
```elixir
defmodule GepaEx.Application do
  def start(_type, _args) do
    children = [
      {GepaEx.VectorStore.QdrantPool, [
        name: :qdrant_pool,
        host: "localhost",
        port: 6333,
        pool_size: 10
      ]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

**Pipeline Execution**:
```elixir
defmodule GepaEx.RAGPipeline do
  def execute(query, prompts, config) do
    with {:ok, reformed} <- reformulate_query(query, prompts),
         {:ok, docs} <- retrieve_documents(reformed, config),
         {:ok, reranked} <- rerank_documents(docs, query, prompts),
         {:ok, context} <- synthesize_context(reranked, query, prompts),
         {:ok, answer} <- generate_answer(query, context, prompts) do
      {:ok, build_result(query, reformed, docs, context, answer)}
    end
  end
end
```

## Performance Considerations

### 1. Bottlenecks

**Retrieval Latency**:
- Vector similarity computation: O(n*d) where n=docs, d=dimensions
- Mitigated by indexes (HNSW, IVF)
- Typically 10-100ms for k=5-10

**LLM Calls**:
- Query reformulation: ~1-2s
- Context synthesis: ~2-3s
- Answer generation: ~2-4s
- Total: 5-9s per query

**Elixir Optimization**:
- Pipeline stages in parallel where possible
- Cache query reformulations
- Reuse connections with pooling

### 2. Memory Usage

**Vector Embeddings**:
- 384 dimensions × 4 bytes = 1.5KB per document
- 100K documents = 150MB
- Consider quantization for large collections

**Trajectory Capture**:
- Only enable for small validation sets
- Each trajectory: ~10-50KB depending on context
- Batch of 100: 1-5MB

### 3. Scaling Strategies

**Horizontal Scaling**:
- Multiple vector store replicas
- Load balancing across replicas
- Sharding by document category

**Vertical Scaling**:
- GPU for embeddings (Nx support)
- Larger vector store instances
- SSD for faster retrieval

## Summary

The RAG Adapter represents a sophisticated orchestration layer that:

1. **Abstracts Vector Stores**: Unified interface for 5+ vector databases
2. **Orchestrates Multi-Stage Pipeline**: Query → Retrieval → Reranking → Synthesis → Generation
3. **Provides Comprehensive Metrics**: Dual evaluation of retrieval and generation
4. **Enables Component Optimization**: Target specific pipeline stages
5. **Supports Hybrid Search**: Combines semantic and keyword search
6. **Handles Multiple Retrieval Strategies**: Similarity, hybrid, and vector search

For Elixir port, key opportunities:

- **Concurrency**: Leverage OTP for parallel processing
- **Fault Tolerance**: Supervision trees for reliability
- **Connection Pooling**: Efficient resource management
- **Streaming**: Real-time response generation
- **Type Safety**: Protocols and specs for clear contracts

Priority implementations:
1. Vector store interface (protocol)
2. Qdrant/Weaviate adapters (HTTP clients available)
3. RAG pipeline orchestration
4. Evaluation metrics (consider Nx)
5. GenericRAGAdapter with GEPA integration

The modular design makes incremental porting straightforward, with each vector store and pipeline component independently testable.
