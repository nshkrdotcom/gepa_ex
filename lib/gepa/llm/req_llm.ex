defmodule GEPA.LLM.ReqLLM do
  @moduledoc """
  Production LLM implementation using ReqLLM library.

  Supports multiple LLM providers through a unified interface:
  - OpenAI (gpt-4o-mini, gpt-4o, etc.)
  - Google Gemini (gemini-2.0-flash-exp, gemini-1.5-pro, etc.)

  ## Configuration

  API keys can be provided via:
  1. Runtime options
  2. Application config
  3. Environment variables

  ### Environment Variables

  - `OPENAI_API_KEY` - OpenAI API key
  - `GEMINI_API_KEY` or `GOOGLE_API_KEY` - Google Gemini API key

  ### Application Config

      config :gepa_ex, :llm,
        provider: :openai,
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o-mini",
        temperature: 0.7,
        max_tokens: 2000

  ## Examples

      # OpenAI with defaults
      llm = GEPA.LLM.ReqLLM.new(provider: :openai)
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA in one sentence")

      # Gemini with custom model
      llm = GEPA.LLM.ReqLLM.new(
        provider: :gemini,
        model: "gemini-1.5-pro",
        temperature: 0.9
      )
      {:ok, response} = GEPA.LLM.complete(llm, "Write a haiku about Elixir")

      # Override options per call
      {:ok, response} = GEPA.LLM.complete(llm, prompt, temperature: 0.1, max_tokens: 100)
  """

  @behaviour GEPA.LLM

  defstruct [
    :provider,
    :model,
    :api_key,
    :temperature,
    :max_tokens,
    :top_p,
    :timeout,
    :req_options
  ]

  @type provider :: :openai | :gemini
  @type t :: %__MODULE__{
          provider: provider(),
          model: String.t(),
          api_key: String.t() | nil,
          temperature: float() | nil,
          max_tokens: pos_integer() | nil,
          top_p: float() | nil,
          timeout: pos_integer() | nil,
          req_options: keyword()
        }

  @default_models %{
    openai: "gpt-4o-mini",
    gemini: "gemini-2.0-flash-exp"
  }

  @default_temperature 0.7
  @default_max_tokens 2000
  @default_timeout 60_000

  @doc """
  Creates a new ReqLLM instance.

  ## Options

    - `:provider` - LLM provider (:openai or :gemini), required
    - `:model` - Model name (defaults: "gpt-4o-mini" for OpenAI, "gemini-2.0-flash-exp" for Gemini)
    - `:api_key` - API key (falls back to env vars if not provided)
    - `:temperature` - Sampling temperature 0.0-1.0 (default: 0.7)
    - `:max_tokens` - Maximum tokens to generate (default: 2000)
    - `:top_p` - Nucleus sampling parameter (optional)
    - `:timeout` - Request timeout in milliseconds (default: 60000)
    - `:req_options` - Additional options to pass to Req

  ## Examples

      llm = GEPA.LLM.ReqLLM.new(provider: :openai)
      llm = GEPA.LLM.ReqLLM.new(provider: :gemini, temperature: 0.9)
      llm = GEPA.LLM.ReqLLM.new(
        provider: :openai,
        model: "gpt-4o",
        api_key: "sk-...",
        max_tokens: 1000
      )
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    provider = Keyword.fetch!(opts, :provider)

    unless provider in [:openai, :gemini] do
      raise ArgumentError, "provider must be :openai or :gemini, got: #{inspect(provider)}"
    end

    model = Keyword.get(opts, :model, @default_models[provider])
    api_key = Keyword.get(opts, :api_key) || get_default_api_key(provider)

    %__MODULE__{
      provider: provider,
      model: model,
      api_key: api_key,
      temperature: Keyword.get(opts, :temperature, @default_temperature),
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
      top_p: Keyword.get(opts, :top_p),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @impl GEPA.LLM
  def complete(%__MODULE__{} = llm, prompt, opts \\ []) when is_binary(prompt) do
    # Merge instance config with per-call options
    merged_opts = merge_options(llm, opts)

    case llm.provider do
      :openai -> complete_openai(prompt, merged_opts)
      :gemini -> complete_gemini(prompt, merged_opts)
    end
  rescue
    error ->
      {:error, format_error(error)}
  end

  ## Private Functions

  defp merge_options(llm, opts) do
    [
      model: Keyword.get(opts, :model, llm.model),
      api_key: Keyword.get(opts, :api_key, llm.api_key),
      temperature: Keyword.get(opts, :temperature, llm.temperature),
      max_tokens: Keyword.get(opts, :max_tokens, llm.max_tokens),
      top_p: Keyword.get(opts, :top_p, llm.top_p),
      timeout: Keyword.get(opts, :timeout, llm.timeout),
      req_options: Keyword.get(opts, :req_options, llm.req_options)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp complete_openai(prompt, opts) do
    model = Keyword.fetch!(opts, :model)
    api_key = Keyword.fetch!(opts, :api_key)

    # Build model spec for ReqLLM
    model_opts =
      [
        temperature: Keyword.get(opts, :temperature, @default_temperature),
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)
      ]
      |> maybe_add_opt(:top_p, Keyword.get(opts, :top_p))

    model_spec = {:openai, model, model_opts}

    # Set API key for the request
    ReqLLM.put_key(:openai_api_key, api_key)

    # Use unified ReqLLM API
    case ReqLLM.generate_text(model_spec, prompt) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_gemini(prompt, opts) do
    model = Keyword.fetch!(opts, :model)
    api_key = Keyword.fetch!(opts, :api_key)

    # Build model spec for ReqLLM
    model_opts =
      [
        temperature: Keyword.get(opts, :temperature, @default_temperature),
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)
      ]
      |> maybe_add_opt(:top_p, Keyword.get(opts, :top_p))

    model_spec = {:google, model, model_opts}

    # Set API key for the request
    ReqLLM.put_key(:gemini_api_key, api_key)

    # Use unified ReqLLM API
    case ReqLLM.generate_text(model_spec, prompt) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_opt(list, _key, nil), do: list
  defp maybe_add_opt(list, key, value), do: Keyword.put(list, key, value)

  defp get_default_api_key(:openai) do
    System.get_env("OPENAI_API_KEY")
  end

  defp get_default_api_key(:gemini) do
    System.get_env("GEMINI_API_KEY") || System.get_env("GOOGLE_API_KEY")
  end

  defp format_error(error) when is_exception(error) do
    Exception.message(error)
  end

  defp format_error(error), do: error
end
