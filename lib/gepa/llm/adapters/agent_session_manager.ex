defmodule GEPA.LLM.Adapters.AgentSessionManager do
  @moduledoc """
  GEPA compatibility adapter backed by the shared `:inference` ASM adapter.

  This module keeps the `GEPA.LLM.agent/2` API stable while delegating
  Agent Session Manager query and stream behavior to `Inference.Adapters.ASM`.
  """

  alias GEPA.LLM.{Client, Request, Response}

  defstruct [
    :provider,
    :lane,
    :session,
    :asm_module,
    :inference_client,
    session_opts: [],
    query_opts: [],
    stream_opts: [],
    provider_opts: []
  ]

  @type provider :: :claude | :codex | :codex_exec | :gemini | :amp
  @type lane :: :auto | :core | :sdk

  @type t :: %__MODULE__{
          provider: provider(),
          lane: lane(),
          session: term(),
          session_opts: keyword(),
          query_opts: keyword(),
          stream_opts: keyword(),
          provider_opts: keyword(),
          asm_module: module(),
          inference_client: Inference.Client.t()
        }

  @providers [:claude, :codex, :codex_exec, :gemini, :amp]
  @lanes [:auto, :core, :sdk]
  @default_models %{codex: "gpt-5.4-mini", gemini: "gemini-3.1-flash-lite-preview"}

  @spec new(keyword()) :: {:ok, Client.t()} | {:error, term()}
  def new(opts \\ []) do
    with {:ok, state} <- build_state(opts) do
      {:ok,
       %Client{
         adapter: __MODULE__,
         adapter_state: state,
         provider: state.provider,
         model: Keyword.get(state.provider_opts, :model),
         defaults: [lane: state.lane],
         capabilities: MapSet.new([:text, :stream, :session, :session_resume, :cost]),
         metadata: %{inference_adapter: Inference.Adapters.ASM}
       }}
    end
  end

  @spec new!(keyword()) :: Client.t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, client} -> client
      {:error, reason} -> raise ArgumentError, "invalid ASM adapter options: #{inspect(reason)}"
    end
  end

  @spec build_state(keyword()) :: {:ok, t()} | {:error, term()}
  def build_state(opts) do
    with {:ok, provider} <- fetch_provider(opts),
         {:ok, lane} <- fetch_lane(opts) do
      state = %__MODULE__{
        provider: provider,
        lane: lane,
        session: Keyword.get(opts, :session),
        session_opts: Keyword.get(opts, :session_opts, []),
        query_opts: Keyword.get(opts, :query_opts, []),
        stream_opts: Keyword.get(opts, :stream_opts, []),
        provider_opts:
          opts
          |> Keyword.get(:provider_opts, [])
          |> normalize_provider_opts()
          |> put_default_model(provider)
          |> maybe_put_external_model_payload(provider),
        asm_module: Keyword.get(opts, :asm_module, ASM)
      }

      {:ok, %{state | inference_client: inference_client(state)}}
    end
  end

  @spec complete(Client.t(), Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Client{} = client, %Request{schema: schema}) when not is_nil(schema) do
    {:error,
     {:unsupported_capability, :structured_output,
      %{adapter: __MODULE__, provider: client.provider, schema: schema}}}
  end

  def complete(%Client{adapter_state: %__MODULE__{} = state}, %Request{} = request) do
    state
    |> run_complete(request)
    |> map_result(__MODULE__, state, request)
  end

  @spec stream(Client.t(), Request.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(%Client{adapter_state: %__MODULE__{} = state}, %Request{} = request) do
    opts = inference_request_opts(state, request)

    case Inference.stream(state.inference_client, request_text(request), opts) do
      {:ok, stream} ->
        {:ok, Stream.flat_map(stream, &stream_text_chunks/1)}

      {:error, error} ->
        {:error, error}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @spec capabilities(Client.t()) :: MapSet.t(atom())
  def capabilities(%Client{capabilities: capabilities}), do: capabilities

  @spec close(Client.t()) :: :ok | {:error, term()}
  def close(%Client{adapter_state: %__MODULE__{session: nil}}), do: :ok

  def close(%Client{adapter_state: %__MODULE__{session: session, asm_module: asm_module}}) do
    asm_module.stop_session(session)
  end

  defp run_complete(%__MODULE__{} = state, %Request{} = request) do
    Inference.complete(
      state.inference_client,
      request_text(request),
      inference_request_opts(state, request)
    )
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp map_result(
         {:ok, %Inference.Response{} = response},
         adapter,
         %__MODULE__{} = state,
         %Request{} = request
       ) do
    {:ok,
     %Response{
       text: Inference.Response.text(response),
       messages: response.raw |> value(:messages),
       cost: response.metadata[:cost] || value(response.raw, :cost),
       stop_reason: response.finish_reason,
       adapter: adapter,
       provider: state.provider,
       model: request.model || Keyword.get(state.provider_opts, :model),
       session_ref: request.session || state.session,
       raw: response.raw,
       metadata: response.metadata
     }}
  end

  defp map_result({:error, error}, _adapter, _state, _request), do: {:error, error}

  defp inference_client(%__MODULE__{} = state) do
    Inference.Client.new!(
      adapter: Inference.Adapters.ASM,
      provider: state.provider,
      model: Keyword.get(state.provider_opts, :model),
      defaults: [lane: state.lane] ++ state.provider_opts,
      adapter_opts: [
        asm_module: state.asm_module,
        session: state.session,
        session_opts: state.session_opts,
        query_opts: state.query_opts,
        stream_opts: state.stream_opts
      ]
    )
  end

  defp inference_request_opts(%__MODULE__{} = state, %Request{} = request) do
    provider_opts =
      state.provider_opts
      |> Keyword.merge(request.provider_opts)
      |> normalize_provider_opts()
      |> maybe_put(:model, request.model)
      |> rename_timeout(request.timeout)
      |> maybe_put(:prompt, request_text(request))

    [
      model: request.model,
      session: request.session,
      options: provider_opts
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
  end

  defp request_text(%Request{} = request), do: Request.to_text(Request.prompt(request))

  defp normalize_provider_opts(provider_opts) do
    provider_opts
    |> Keyword.delete(:temperature)
    |> Keyword.delete(:max_tokens)
    |> Keyword.delete(:top_p)
    |> rename_timeout()
  end

  defp rename_timeout(provider_opts) do
    case Keyword.pop(provider_opts, :timeout) do
      {nil, opts} -> opts
      {timeout, opts} -> Keyword.put_new(opts, :transport_timeout_ms, timeout)
    end
  end

  defp rename_timeout(provider_opts, nil), do: provider_opts

  defp rename_timeout(provider_opts, timeout),
    do: Keyword.put(provider_opts, :transport_timeout_ms, timeout)

  defp put_default_model(provider_opts, provider) do
    case {Keyword.get(provider_opts, :model), Map.get(@default_models, provider)} do
      {model, _default} when is_binary(model) and model != "" -> provider_opts
      {_model, nil} -> provider_opts
      {_model, default} -> Keyword.put(provider_opts, :model, default)
    end
  end

  defp maybe_put_external_model_payload(provider_opts, :gemini) do
    case {Keyword.get(provider_opts, :model_payload), Keyword.get(provider_opts, :model)} do
      {payload, _model} when is_map(payload) ->
        provider_opts

      {_payload, model} when is_binary(model) and model != "" ->
        Keyword.put(provider_opts, :model_payload, %{
          provider: :gemini,
          requested_model: model,
          resolved_model: model,
          resolution_source: :explicit,
          model_source: :external
        })

      _other ->
        provider_opts
    end
  end

  defp maybe_put_external_model_payload(provider_opts, _provider), do: provider_opts

  defp fetch_provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} when provider in @providers -> {:ok, provider}
      {:ok, provider} -> {:error, {:invalid_provider, provider, @providers}}
      :error -> {:error, :missing_provider}
    end
  end

  defp fetch_lane(opts) do
    case Keyword.get(opts, :lane, :auto) do
      lane when lane in @lanes -> {:ok, lane}
      lane -> {:error, {:invalid_lane, lane, @lanes}}
    end
  end

  defp stream_text_chunks(%Inference.StreamEvent{data: text}) when is_binary(text) and text != "",
    do: [text]

  defp stream_text_chunks(text) when is_binary(text) and text != "", do: [text]
  defp stream_text_chunks(_chunk), do: []

  defp value(%{__struct__: _} = map, key), do: Map.get(map, key)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_other, _key), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
