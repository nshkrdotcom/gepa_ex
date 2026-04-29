defmodule GEPA.LLM.Adapters.ReqLLM do
  @moduledoc """
  GEPA compatibility adapter backed by the shared `:inference` ReqLLM adapter.

  This module preserves the public `GEPA.LLM.Client` surface while moving
  provider-specific ReqLLM behavior into `Inference.Adapters.ReqLLM`.
  """

  alias GEPA.LLM.{Client, Request, Response}

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
    :env,
    :inference_client,
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
          response_module: module(),
          env: (String.t() -> String.t() | nil),
          inference_client: Inference.Client.t() | nil
        }

  @providers [:openai, :gemini, :anthropic]

  @default_models %{
    openai: "gpt-5.4-mini",
    gemini: "gemini-3.1-flash-lite-preview",
    anthropic: "claude-haiku-4-5"
  }

  @default_temperature 0.7
  @default_max_tokens 2000
  @default_timeout 60_000

  @instruction_schema [
    instruction: [type: :string, required: true, doc: "The improved instruction text."]
  ]

  @spec instruction_schema() :: keyword()
  def instruction_schema, do: @instruction_schema

  @spec new(keyword()) :: {:ok, Client.t()} | {:error, term()}
  def new(opts \\ []) do
    with {:ok, state} <- build_state(opts) do
      {:ok,
       %Client{
         adapter: __MODULE__,
         adapter_state: state,
         provider: state.provider,
         model: state.model,
         defaults: state_defaults(state),
         capabilities: MapSet.new([:text, :messages, :structured_output, :tools, :cost]),
         metadata: %{inference_adapter: Inference.Adapters.ReqLLM}
       }}
    end
  end

  @spec new!(keyword()) :: Client.t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, client} ->
        client

      {:error, reason} ->
        raise ArgumentError, "invalid ReqLLM adapter options: #{inspect(reason)}"
    end
  end

  @spec build_state(keyword()) :: {:ok, t()} | {:error, term()}
  def build_state(opts) do
    with {:ok, provider} <- fetch_provider(opts) do
      state = %__MODULE__{
        provider: provider,
        model: Keyword.get(opts, :model, @default_models[provider]),
        api_key: Keyword.get(opts, :api_key),
        temperature: Keyword.get(opts, :temperature, @default_temperature),
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
        top_p: Keyword.get(opts, :top_p),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        req_options: Keyword.get(opts, :req_options, []),
        provider_opts: Keyword.get(opts, :provider_opts, []),
        req_llm_module: Keyword.get(opts, :req_llm_module, ReqLLM),
        response_module: Keyword.get(opts, :response_module, ReqLLM.Response),
        env: Keyword.get(opts, :env, &System.get_env/1)
      }

      {:ok, %{state | inference_client: inference_client(state)}}
    end
  end

  @spec complete(Client.t(), Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Client{adapter_state: %__MODULE__{} = state}, %Request{} = request) do
    state
    |> run_inference(request, nil)
    |> map_result(__MODULE__)
  end

  @spec stream(Client.t(), Request.t()) :: {:error, term()}
  def stream(%Client{} = client, %Request{} = _request) do
    {:error,
     {:unsupported_capability, :stream, %{adapter: client.adapter, provider: client.provider}}}
  end

  @spec capabilities(Client.t()) :: MapSet.t(atom())
  def capabilities(%Client{capabilities: capabilities}), do: capabilities

  @spec close(Client.t()) :: :ok
  def close(%Client{}), do: :ok

  @spec complete_legacy(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete_legacy(%__MODULE__{} = state, prompt, opts \\ []) when is_binary(prompt) do
    request = Request.from_prompt(prompt, opts)

    with {:ok, %Response{} = response} <-
           state
           |> run_inference(request, nil)
           |> map_result(__MODULE__) do
      {:ok, Response.text(response)}
    end
  end

  @spec complete_structured_legacy(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_structured_legacy(%__MODULE__{} = state, prompt, opts \\ [])
      when is_binary(prompt) do
    request = Request.structured(prompt, Keyword.put_new(opts, :schema, @instruction_schema))

    case state
         |> run_inference(request, request.schema || @instruction_schema)
         |> map_result(__MODULE__) do
      {:ok, %Response{object: object}} when is_map(object) -> {:ok, object}
      {:ok, %Response{} = response} -> {:ok, %{"instruction" => Response.text(response)}}
      {:error, _} = error -> error
    end
  end

  defp run_inference(%__MODULE__{} = state, %Request{} = request, response_format) do
    opts = inference_request_opts(state, request, response_format)
    Inference.complete(inference_client(state, request), request_text(request), opts)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp map_result({:ok, %Inference.Response{} = response}, adapter) do
    {:ok,
     %Response{
       text: Inference.Response.text(response),
       object: response.object,
       usage: response.usage,
       stop_reason: response.finish_reason,
       adapter: adapter,
       provider: response.provider,
       model: response.model,
       raw: response.raw,
       metadata: response.metadata
     }}
  end

  defp map_result({:error, error}, _adapter), do: {:error, error}

  defp inference_client(%__MODULE__{} = state) do
    Inference.Client.new!(
      adapter: Inference.Adapters.ReqLLM,
      provider: state.provider,
      model: state.model,
      defaults: inference_defaults(state),
      adapter_opts: [
        req_llm_module: state.req_llm_module,
        response_module: state.response_module,
        api_key: state.api_key,
        env: state.env,
        model_spec: model_spec(state.provider, state.model)
      ]
    )
  end

  defp inference_client(%__MODULE__{} = state, %Request{} = request) do
    client = state.inference_client || inference_client(state)
    model = request.model || state.model

    %{
      client
      | model: model,
        adapter_opts:
          Keyword.put(client.adapter_opts, :model_spec, model_spec(state.provider, model))
    }
  end

  defp inference_defaults(%__MODULE__{} = state) do
    [
      temperature: state.temperature,
      max_tokens: state.max_tokens,
      top_p: state.top_p,
      receive_timeout: state.timeout
    ]
    |> Keyword.merge(state.req_options)
    |> Keyword.merge(state.provider_opts)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp inference_request_opts(%__MODULE__{} = state, %Request{} = request, response_format) do
    provider_opts =
      state.provider_opts
      |> Keyword.merge(request.provider_opts)
      |> maybe_put(:api_key, request_api_key(state, request))
      |> maybe_put(:tools, request.tools)
      |> maybe_put(:prompt, Request.prompt(request))

    [
      temperature: request.temperature,
      model: request.model,
      max_tokens: request.max_tokens,
      top_p: request.top_p,
      response_format: response_format || request.schema,
      options: provider_opts
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
  end

  defp request_api_key(%__MODULE__{} = state, %Request{} = request) do
    Keyword.get(request.provider_opts, :api_key) || state.api_key
  end

  defp request_text(%Request{} = request), do: Request.to_text(Request.prompt(request))

  defp state_defaults(%__MODULE__{} = state) do
    [
      model: state.model,
      temperature: state.temperature,
      max_tokens: state.max_tokens,
      top_p: state.top_p,
      timeout: state.timeout
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fetch_provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} when provider in @providers -> {:ok, provider}
      {:ok, provider} -> {:error, {:invalid_provider, provider, @providers}}
      :error -> {:error, :missing_provider}
    end
  end

  defp model_spec(:openai, model), do: "openai:#{model}"
  defp model_spec(:gemini, model), do: "google:#{model}"
  defp model_spec(:anthropic, model), do: "anthropic:#{model}"

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
