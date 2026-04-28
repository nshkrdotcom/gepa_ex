defmodule GEPA.Embeddings do
  @moduledoc """
  Behaviour and facade for embedding providers.

  GEPA keeps embedding generation separate from LLM text generation so RAG
  pipelines can mix a local/CLI inference adapter with a hosted embedding
  provider. Implementations return explicit `{:ok, value}` or `{:error, reason}`
  tuples; they should not silently fall back to synthetic vectors.
  """

  @type text :: String.t()
  @type vector :: [float()]
  @type provider :: module() | struct()

  @callback embed(provider(), text(), keyword()) :: {:ok, vector()} | {:error, term()}
  @callback embed_batch(provider(), [text()], keyword()) :: {:ok, [vector()]} | {:error, term()}
  @callback dimensions(provider()) :: pos_integer() | nil
  @callback model(provider()) :: String.t() | nil

  @optional_callbacks dimensions: 1, model: 1

  @doc "Generate one embedding vector."
  @spec embed(provider(), text(), keyword()) :: {:ok, vector()} | {:error, term()}
  def embed(provider, text, opts \\ []) when is_binary(text) do
    adapter_module(provider).embed(provider, text, opts)
  end

  @doc "Generate embeddings for a batch of texts."
  @spec embed_batch(provider(), [text()], keyword()) :: {:ok, [vector()]} | {:error, term()}
  def embed_batch(provider, texts, opts \\ []) when is_list(texts) do
    adapter_module(provider).embed_batch(provider, texts, opts)
  end

  @doc "Generate one embedding vector or raise."
  @spec embed!(provider(), text(), keyword()) :: vector()
  def embed!(provider, text, opts \\ []) do
    case embed(provider, text, opts) do
      {:ok, vector} -> vector
      {:error, reason} -> raise RuntimeError, "embedding failed: #{inspect(reason)}"
    end
  end

  @doc "Generate a batch of embedding vectors or raise."
  @spec embed_batch!(provider(), [text()], keyword()) :: [vector()]
  def embed_batch!(provider, texts, opts \\ []) do
    case embed_batch(provider, texts, opts) do
      {:ok, vectors} -> vectors
      {:error, reason} -> raise RuntimeError, "embedding batch failed: #{inspect(reason)}"
    end
  end

  @doc "Return the configured embedding dimension when the provider exposes it."
  @spec dimensions(provider()) :: pos_integer() | nil
  def dimensions(provider) do
    module = adapter_module(provider)

    if function_exported?(module, :dimensions, 1) do
      module.dimensions(provider)
    end
  end

  @doc "Return the configured embedding model name when the provider exposes it."
  @spec model(provider()) :: String.t() | nil
  def model(provider) do
    module = adapter_module(provider)

    if function_exported?(module, :model, 1) do
      module.model(provider)
    end
  end

  defp adapter_module(%module{}), do: module
  defp adapter_module(module) when is_atom(module), do: module
end
