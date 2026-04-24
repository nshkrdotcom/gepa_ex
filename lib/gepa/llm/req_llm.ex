defmodule GEPA.LLM.ReqLLM do
  @moduledoc """
  Backward-compatible ReqLLM implementation.

  New code should prefer `GEPA.LLM.req_llm/2`, which returns a normalized
  `GEPA.LLM.Client`. This module preserves the original struct-returning API
  used by existing examples and tests while delegating all provider behavior to
  `GEPA.LLM.Adapters.ReqLLM`.
  """

  @behaviour GEPA.LLM

  alias GEPA.LLM.Adapters.ReqLLM, as: Adapter

  defstruct [
    :provider,
    :model,
    :api_key,
    :temperature,
    :max_tokens,
    :top_p,
    :timeout,
    :req_llm_module,
    :response_module,
    req_options: [],
    provider_opts: []
  ]

  @type provider :: :openai | :gemini | :anthropic
  @type t :: %__MODULE__{
          provider: provider(),
          model: String.t(),
          api_key: String.t() | nil,
          temperature: float() | nil,
          max_tokens: pos_integer() | nil,
          top_p: float() | nil,
          timeout: pos_integer() | nil,
          req_options: keyword(),
          provider_opts: keyword(),
          req_llm_module: module(),
          response_module: module()
        }

  @doc """
  Creates a backward-compatible ReqLLM provider struct.

  Supported providers are `:openai`, `:gemini`, and `:anthropic`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    case Adapter.build_state(opts) do
      {:ok, %Adapter{} = state} ->
        from_adapter_state(state)

      {:error, {:invalid_provider, provider, providers}} ->
        raise ArgumentError,
              "provider must be one of #{inspect(providers)}, got: #{inspect(provider)}"

      {:error, :missing_provider} ->
        raise KeyError, key: :provider, term: opts
    end
  end

  @impl GEPA.LLM
  @spec complete(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(%__MODULE__{} = llm, prompt, opts \\ []) when is_binary(prompt) do
    llm
    |> to_adapter_state()
    |> Adapter.complete_legacy(prompt, opts)
  end

  @impl GEPA.LLM
  @spec complete_structured(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_structured(%__MODULE__{} = llm, prompt, opts \\ []) when is_binary(prompt) do
    llm
    |> to_adapter_state()
    |> Adapter.complete_structured_legacy(prompt, opts)
  end

  defp from_adapter_state(%Adapter{} = state) do
    %__MODULE__{
      provider: state.provider,
      model: state.model,
      api_key: state.api_key,
      temperature: state.temperature,
      max_tokens: state.max_tokens,
      top_p: state.top_p,
      timeout: state.timeout,
      req_options: state.req_options,
      provider_opts: state.provider_opts,
      req_llm_module: state.req_llm_module,
      response_module: state.response_module
    }
  end

  defp to_adapter_state(%__MODULE__{} = llm) do
    %Adapter{
      provider: llm.provider,
      model: llm.model,
      api_key: llm.api_key,
      temperature: llm.temperature,
      max_tokens: llm.max_tokens,
      top_p: llm.top_p,
      timeout: llm.timeout,
      req_options: llm.req_options,
      provider_opts: llm.provider_opts,
      req_llm_module: llm.req_llm_module || ReqLLM,
      response_module: llm.response_module || ReqLLM.Response
    }
  end
end
