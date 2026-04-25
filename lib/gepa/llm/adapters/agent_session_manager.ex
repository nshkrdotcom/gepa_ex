defmodule GEPA.LLM.Adapters.AgentSessionManager do
  @moduledoc """
  GEPA LLM adapter backed by Agent Session Manager.

  This is the local/CLI adapter for the temporary GEPA facade. It uses ASM's
  public query/stream APIs and normalizes results into `GEPA.LLM.Response`.
  """

  alias GEPA.LLM.{Client, Request, Response}

  defstruct [
    :provider,
    :lane,
    :session,
    :asm_module,
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
          asm_module: module()
        }

  @providers [:claude, :codex, :codex_exec, :gemini, :amp]
  @lanes [:auto, :core, :sdk]
  @default_models %{codex: "gpt-5.4-mini"}

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
         metadata: %{temporary_facade?: true}
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
      provider_opts =
        opts
        |> Keyword.get(:provider_opts, [])
        |> put_default_model(provider)

      {:ok,
       %__MODULE__{
         provider: provider,
         lane: lane,
         session: Keyword.get(opts, :session),
         session_opts: Keyword.get(opts, :session_opts, []),
         query_opts: Keyword.get(opts, :query_opts, []),
         stream_opts: Keyword.get(opts, :stream_opts, []),
         provider_opts: provider_opts,
         asm_module: Keyword.get(opts, :asm_module, ASM)
       }}
    end
  end

  @spec complete(Client.t(), Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def complete(%Client{} = client, %Request{schema: schema}) when not is_nil(schema) do
    {:error,
     {:unsupported_capability, :structured_output,
      %{adapter: __MODULE__, provider: client.provider, schema: schema}}}
  end

  def complete(%Client{adapter_state: %__MODULE__{} = state}, %Request{} = request) do
    prompt = request_prompt!(request)
    opts = build_query_opts(state, request)
    {target, query_opts} = query_target_and_opts(state, request, opts)

    case state.asm_module.query(target, prompt, query_opts) do
      {:ok, result} ->
        {:ok, normalize_result(state, request, result)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  @spec stream(Client.t(), Request.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(%Client{adapter_state: %__MODULE__{} = state}, %Request{} = request) do
    prompt = request_prompt!(request)
    opts = build_stream_opts(state, request)

    with {:ok, session, stream_opts, ownership} <- stream_session(state, request, opts) do
      stream =
        session
        |> state.asm_module.stream(prompt, stream_opts)
        |> maybe_close_after_stream(session, ownership, state.asm_module)
        |> normalize_stream()

      {:ok, stream}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  @spec capabilities(Client.t()) :: MapSet.t(atom())
  def capabilities(%Client{capabilities: capabilities}), do: capabilities

  @spec close(Client.t()) :: :ok | {:error, term()}
  def close(%Client{adapter_state: %__MODULE__{session: nil}}), do: :ok

  def close(%Client{adapter_state: %__MODULE__{session: session, asm_module: asm_module}}) do
    asm_module.stop_session(session)
  end

  defp normalize_result(%__MODULE__{} = state, %Request{} = request, result) do
    data = result_to_map(result)
    metadata = value(data, :metadata) || %{}

    %Response{
      text: value(data, :text) || "",
      messages: value(data, :messages),
      cost: value(data, :cost),
      stop_reason: value(data, :stop_reason),
      adapter: __MODULE__,
      provider: state.provider,
      model: request.model || Keyword.get(state.provider_opts, :model),
      session_ref: request.session || state.session,
      raw: result,
      metadata: Map.merge(metadata, result_metadata(data, state))
    }
  end

  defp result_metadata(data, %__MODULE__{} = state) do
    %{
      run_id: value(data, :run_id),
      session_id: value(data, :session_id),
      session_id_from_cli: value(data, :session_id_from_cli),
      duration_ms: value(data, :duration_ms),
      lane: state.lane
    }
  end

  defp build_query_opts(%__MODULE__{} = state, %Request{} = request) do
    state.query_opts
    |> Keyword.merge(common_opts(state, request))
  end

  defp build_stream_opts(%__MODULE__{} = state, %Request{} = request) do
    state.stream_opts
    |> Keyword.merge(common_opts(state, request))
  end

  defp query_target_and_opts(%__MODULE__{} = state, %Request{} = request, opts) do
    case request.session || state.session do
      session when is_pid(session) ->
        {session, opts}

      session_id when is_binary(session_id) and session_id != "" ->
        {state.provider, Keyword.put(opts, :session_id, session_id)}

      _session ->
        {state.provider, opts}
    end
  end

  defp stream_session(%__MODULE__{} = state, %Request{} = request, opts) do
    case request.session || state.session do
      session when is_pid(session) ->
        {:ok, session, opts, :external}

      session_id when is_binary(session_id) and session_id != "" ->
        start_managed_stream_session(state, Keyword.put(opts, :session_id, session_id))

      _session ->
        start_managed_stream_session(state, opts)
    end
  end

  defp start_managed_stream_session(%__MODULE__{} = state, opts) do
    start_opts = Keyword.put(opts, :provider, state.provider)
    stream_opts = Keyword.drop(opts, [:session_id, :provider, :name, :options])

    with {:ok, session} <- state.asm_module.start_session(start_opts) do
      {:ok, session, stream_opts, :managed}
    end
  end

  defp maybe_close_after_stream(stream, session, :managed, asm_module) do
    Elixir.Stream.transform(
      stream,
      fn -> :ok end,
      fn event, acc -> {[event], acc} end,
      fn _acc -> asm_module.stop_session(session) end
    )
  end

  defp maybe_close_after_stream(stream, _session, :external, _asm_module), do: stream

  defp normalize_stream(stream) do
    Elixir.Stream.flat_map(stream, &stream_text_chunks/1)
  end

  defp stream_text_chunks(chunk) when is_binary(chunk), do: text_chunk(chunk)

  defp stream_text_chunks(%ASM.Event{} = event) do
    event
    |> ASM.Event.assistant_text()
    |> text_chunk()
  end

  defp stream_text_chunks(%ASM.Message.Partial{content_type: :text, delta: delta}) do
    text_chunk(delta)
  end

  defp stream_text_chunks(%ASM.Message.Assistant{content: blocks}) do
    Enum.flat_map(blocks, &content_text_chunk/1)
  end

  defp stream_text_chunks(_chunk), do: []

  defp content_text_chunk(%ASM.Content.Text{text: text}), do: text_chunk(text)
  defp content_text_chunk(_block), do: []

  defp text_chunk(text) when is_binary(text) and text != "", do: [text]
  defp text_chunk(_text), do: []

  defp common_opts(%__MODULE__{} = state, %Request{} = request) do
    state.session_opts
    |> Keyword.merge(state.provider_opts)
    |> Keyword.merge(
      [
        lane: state.lane,
        model: request.model,
        temperature: request.temperature,
        max_tokens: request.max_tokens,
        top_p: request.top_p,
        stream_timeout_ms: request.timeout
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    )
    |> Keyword.merge(request.provider_opts)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp put_default_model(provider_opts, provider) do
    case {Keyword.get(provider_opts, :model), Map.get(@default_models, provider)} do
      {model, _default} when is_binary(model) and model != "" -> provider_opts
      {_model, nil} -> provider_opts
      {_model, default} -> Keyword.put(provider_opts, :model, default)
    end
  end

  defp request_prompt!(%Request{} = request) do
    case Request.prompt(request) do
      prompt when is_binary(prompt) -> prompt
      other -> raise ArgumentError, "ASM adapter requires a string prompt, got: #{inspect(other)}"
    end
  end

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

  defp result_to_map(%{__struct__: _} = result), do: Map.from_struct(result)
  defp result_to_map(result) when is_map(result), do: result

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
