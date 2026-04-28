defmodule GEPA.Embeddings.ReqLLM do
  @moduledoc """
  ReqLLM-backed embedding provider.

  Gemini is the default provider because the integration-foundation path uses
  ReqLLM for Gemini embeddings while inference defaults to Agent Session
  Manager's Gemini CLI adapter.
  """

  @behaviour GEPA.Embeddings

  defstruct [
    :api_key,
    :dimensions,
    :env,
    :req_llm_module,
    provider: :gemini,
    model: "gemini-embedding-001",
    req_options: [],
    provider_options: []
  ]

  @type provider :: :gemini | :openai
  @type t :: %__MODULE__{
          provider: provider(),
          model: String.t(),
          api_key: String.t() | nil,
          dimensions: pos_integer() | nil,
          req_options: keyword(),
          provider_options: keyword() | map(),
          req_llm_module: module(),
          env: (String.t() -> String.t() | nil)
        }

  @providers [:gemini, :openai]

  @default_models %{
    gemini: "gemini-embedding-001",
    openai: "text-embedding-3-small"
  }

  @env_vars %{
    gemini: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
    openai: ["OPENAI_API_KEY"]
  }

  @doc "Build a ReqLLM embedding provider."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    opts = to_keyword(opts)

    with {:ok, provider} <- fetch_provider(opts) do
      {:ok,
       %__MODULE__{
         provider: provider,
         model: Keyword.get(opts, :model, Map.fetch!(@default_models, provider)),
         api_key: Keyword.get(opts, :api_key),
         dimensions: Keyword.get(opts, :dimensions),
         req_options: Keyword.get(opts, :req_options, []),
         provider_options: Keyword.get(opts, :provider_options, []),
         req_llm_module: Keyword.get(opts, :req_llm_module, ReqLLM),
         env: Keyword.get(opts, :env, &System.get_env/1)
       }}
    end
  end

  @doc "Build a ReqLLM embedding provider or raise."
  @spec new!(keyword() | map()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, provider} ->
        provider

      {:error, reason} ->
        raise ArgumentError, "invalid ReqLLM embedding options: #{inspect(reason)}"
    end
  end

  @impl true
  def embed(%__MODULE__{} = provider, text, opts \\ []) when is_binary(text) do
    with :ok <- maybe_put_provider_key(provider),
         {:ok, embedding} <-
           provider.req_llm_module.embed(
             model_spec(provider.provider, provider.model),
             text,
             request_opts(provider, opts)
           ) do
      normalize_single_embedding(embedding)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def embed_batch(%__MODULE__{} = provider, texts, opts \\ []) when is_list(texts) do
    with :ok <- maybe_put_provider_key(provider),
         {:ok, embeddings} <-
           provider.req_llm_module.embed(
             model_spec(provider.provider, provider.model),
             Enum.map(texts, &to_string/1),
             request_opts(provider, opts)
           ) do
      normalize_batch_embedding(embeddings)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def dimensions(%__MODULE__{dimensions: dimensions}), do: dimensions

  @impl true
  def model(%__MODULE__{} = provider), do: model_spec(provider.provider, provider.model)

  defp fetch_provider(opts) do
    case Keyword.get(opts, :provider, :gemini) do
      provider when provider in @providers -> {:ok, provider}
      provider -> {:error, {:invalid_provider, provider, @providers}}
    end
  end

  defp maybe_put_provider_key(%__MODULE__{} = provider) do
    case provider.api_key || env_api_key(provider) do
      nil -> :ok
      api_key -> provider.req_llm_module.put_key(provider_key(provider.provider), api_key)
    end
  end

  defp env_api_key(%__MODULE__{} = provider) do
    @env_vars
    |> Map.fetch!(provider.provider)
    |> Enum.find_value(fn key ->
      case provider.env.(key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp request_opts(%__MODULE__{} = provider, opts) do
    provider.req_options
    |> Keyword.merge(List.wrap(opts))
    |> maybe_add_dimensions(provider.dimensions)
    |> maybe_add_provider_options(provider.provider_options)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_add_dimensions(opts, nil), do: opts
  defp maybe_add_dimensions(opts, dimensions), do: Keyword.put(opts, :dimensions, dimensions)

  defp maybe_add_provider_options(opts, []), do: opts

  defp maybe_add_provider_options(opts, provider_options),
    do: Keyword.put(opts, :provider_options, provider_options)

  defp normalize_single_embedding(%{embedding: embedding}) when is_list(embedding),
    do: normalize_single_embedding(embedding)

  defp normalize_single_embedding(%{"embedding" => embedding}) when is_list(embedding),
    do: normalize_single_embedding(embedding)

  defp normalize_single_embedding(embedding) when is_list(embedding) do
    if Enum.all?(embedding, &number?/1) do
      {:ok, Enum.map(embedding, &(&1 * 1.0))}
    else
      {:error, {:invalid_embedding, embedding}}
    end
  end

  defp normalize_single_embedding(other), do: {:error, {:invalid_embedding, other}}

  defp normalize_batch_embedding(%{embedding: embeddings}) when is_list(embeddings),
    do: normalize_batch_embedding(embeddings)

  defp normalize_batch_embedding(%{"embedding" => embeddings}) when is_list(embeddings),
    do: normalize_batch_embedding(embeddings)

  defp normalize_batch_embedding(embeddings) when is_list(embeddings) do
    embeddings
    |> Enum.reduce_while({:ok, []}, fn embedding, {:ok, acc} ->
      case normalize_single_embedding(embedding) do
        {:ok, vector} -> {:cont, {:ok, [vector | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, vectors} -> {:ok, Enum.reverse(vectors)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_batch_embedding(other), do: {:error, {:invalid_embedding_batch, other}}

  defp number?(value), do: is_integer(value) or is_float(value)

  defp model_spec(:gemini, model), do: "google:#{model}"
  defp model_spec(:openai, model), do: "openai:#{model}"

  defp provider_key(:gemini), do: :google_api_key
  defp provider_key(:openai), do: :openai_api_key

  defp to_keyword(%{} = opts), do: Map.to_list(opts)
  defp to_keyword(opts), do: opts
end
