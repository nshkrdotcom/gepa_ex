defmodule GEPA.LLM.Adapters.ReqLLM do
  @moduledoc """
  GEPA LLM adapter backed by ReqLLM.

  This adapter owns all ReqLLM-specific model specs, API-key wiring, response
  normalization, and test injection seams. GEPA optimizer/proposer code should
  only see `GEPA.LLM.Client`, `GEPA.LLM.Request`, and `GEPA.LLM.Response`.
  """

  alias GEPA.LLM.{Client, Request, Response, Tool}

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

  @providers [:openai, :gemini, :anthropic]

  @default_models %{
    openai: "gpt-4o-mini",
    gemini: "gemini-2.0-flash-lite",
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
         metadata: %{temporary_facade?: true}
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
      {:ok,
       %__MODULE__{
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
         response_module: Keyword.get(opts, :response_module, ReqLLM.Response)
       }}
    end
  end

  @spec complete(Client.t(), Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Client{adapter_state: %__MODULE__{} = state}, %Request{} = request) do
    if request.schema do
      generate_object(state, request)
    else
      generate_text(state, request)
    end
  rescue
    error ->
      {:error, Exception.message(error)}
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

    with {:ok, %Response{} = response} <- safe_generate_text(state, request) do
      {:ok, Response.text(response)}
    end
  end

  @spec complete_structured_legacy(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_structured_legacy(%__MODULE__{} = state, prompt, opts \\ [])
      when is_binary(prompt) do
    request = Request.structured(prompt, Keyword.put_new(opts, :schema, @instruction_schema))

    case safe_generate_object(state, request) do
      {:ok, %Response{object: object}} when is_map(object) ->
        {:ok, object}

      {:ok, %Response{} = response} ->
        {:ok, %{"instruction" => Response.text(response)}}

      {:error, _} = error ->
        error
    end
  end

  defp safe_generate_text(%__MODULE__{} = state, %Request{} = request) do
    generate_text(state, request)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp safe_generate_object(%__MODULE__{} = state, %Request{} = request) do
    generate_object(state, request)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp generate_text(%__MODULE__{} = state, %Request{} = request) do
    with {:ok, model} <- required_value(:model, request.model || state.model),
         {:ok, api_key} <- required_value(:api_key, request_api_key(request, state)),
         :ok <- put_provider_key(state, api_key),
         {:ok, response} <-
           state.req_llm_module.generate_text(
             model_spec(state.provider, model),
             Request.prompt(request),
             build_request_opts(state, request, api_key)
           ) do
      {:ok, normalize_response(state, request, response)}
    else
      {:error, _} = error -> error
    end
  end

  defp generate_object(%__MODULE__{} = state, %Request{} = request) do
    with {:ok, model} <- required_value(:model, request.model || state.model),
         {:ok, api_key} <- required_value(:api_key, request_api_key(request, state)),
         :ok <- put_provider_key(state, api_key),
         {:ok, response} <-
           state.req_llm_module.generate_object(
             model_spec(state.provider, model),
             Request.prompt(request),
             request.schema || @instruction_schema,
             build_request_opts(state, request, api_key)
           ),
         {:ok, object} <- state.response_module.unwrap_object(response) do
      {:ok, normalize_response(state, request, response, object)}
    else
      {:error, _} = error -> error
    end
  end

  defp normalize_response(%__MODULE__{} = state, %Request{} = request, response, object \\ nil) do
    text =
      case object do
        %{"instruction" => instruction} when is_binary(instruction) ->
          instruction

        %{instruction: instruction} when is_binary(instruction) ->
          instruction

        _ ->
          state.response_module.text(response) || ""
      end

    %Response{
      text: text,
      object: object,
      usage: response_field(response, :usage),
      stop_reason: response_field(response, :finish_reason),
      adapter: __MODULE__,
      provider: state.provider,
      model: request.model || state.model,
      raw: response,
      metadata: %{
        model_spec: model_spec(state.provider, request.model || state.model)
      }
    }
  end

  defp fetch_provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} when provider in @providers -> {:ok, provider}
      {:ok, provider} -> {:error, {:invalid_provider, provider, @providers}}
      :error -> {:error, :missing_provider}
    end
  end

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

  defp build_request_opts(%__MODULE__{} = state, %Request{} = request, api_key) do
    state
    |> base_request_opts(request, api_key)
    |> maybe_add_opt(:top_p, request.top_p || state.top_p)
    |> Keyword.merge(state.req_options)
    |> Keyword.merge(state.provider_opts)
    |> Keyword.merge(request.provider_opts)
    |> maybe_add_tools(request.tools)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp base_request_opts(%__MODULE__{} = state, %Request{} = request, api_key) do
    [
      api_key: api_key,
      temperature: request.temperature || state.temperature || @default_temperature,
      max_tokens: request.max_tokens || state.max_tokens || @default_max_tokens,
      receive_timeout: request.timeout || state.timeout
    ]
  end

  defp maybe_add_opt(list, _key, nil), do: list
  defp maybe_add_opt(list, key, value), do: Keyword.put(list, key, value)

  defp maybe_add_tools(opts, []), do: opts

  defp maybe_add_tools(opts, tools) when is_list(tools) do
    Keyword.put(opts, :tools, Enum.map(tools, &to_req_llm_tool/1))
  end

  defp to_req_llm_tool(%Tool{} = tool) do
    callback =
      if is_function(tool.run, 2) do
        fn args -> tool.run.(args, %{}) end
      else
        tool.run
      end

    {:ok, req_tool} =
      ReqLLM.Tool.new(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.input_schema,
        callback: callback
      )

    req_tool
  end

  defp to_req_llm_tool(tool), do: tool

  defp request_api_key(%Request{} = request, %__MODULE__{} = state) do
    Keyword.get(request.provider_opts, :api_key) || state.api_key
  end

  defp put_provider_key(%__MODULE__{} = state, api_key) do
    state.req_llm_module.put_key(provider_key(state.provider), api_key)
  end

  defp required_value(_key, value) when value not in [nil, ""], do: {:ok, value}
  defp required_value(key, _value), do: {:error, "missing required option :#{key}"}

  defp model_spec(:openai, model), do: "openai:#{model}"
  defp model_spec(:gemini, model), do: "google:#{model}"
  defp model_spec(:anthropic, model), do: "anthropic:#{model}"

  defp provider_key(:openai), do: :openai_api_key
  defp provider_key(:gemini), do: :gemini_api_key
  defp provider_key(:anthropic), do: :anthropic_api_key

  defp response_field(%field{} = response, key) when is_atom(field), do: Map.get(response, key)

  defp response_field(response, key) when is_map(response),
    do: Map.get(response, key) || Map.get(response, Atom.to_string(key))

  defp response_field(_response, _key), do: nil
end
