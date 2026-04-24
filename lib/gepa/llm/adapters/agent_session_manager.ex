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
      {:ok,
       %__MODULE__{
         provider: provider,
         lane: lane,
         session: Keyword.get(opts, :session),
         session_opts: Keyword.get(opts, :session_opts, []),
         query_opts: Keyword.get(opts, :query_opts, []),
         stream_opts: Keyword.get(opts, :stream_opts, []),
         provider_opts: Keyword.get(opts, :provider_opts, []),
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
    target = request.session || state.session || state.provider
    prompt = request_prompt!(request)
    opts = build_query_opts(state, request)

    case state.asm_module.query(target, prompt, opts) do
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
  def stream(%Client{adapter_state: %__MODULE__{session: nil}}, %Request{session: nil}) do
    {:error, {:missing_session, :stream_requires_session}}
  end

  def stream(%Client{adapter_state: %__MODULE__{} = state}, %Request{} = request) do
    session = request.session || state.session
    prompt = request_prompt!(request)

    {:ok, state.asm_module.stream(session, prompt, build_stream_opts(state, request))}
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

  defp common_opts(%__MODULE__{} = state, %Request{} = request) do
    [
      lane: state.lane,
      model: request.model,
      temperature: request.temperature,
      max_tokens: request.max_tokens,
      top_p: request.top_p,
      stream_timeout_ms: request.timeout
    ]
    |> Keyword.merge(state.session_opts)
    |> Keyword.merge(state.provider_opts)
    |> Keyword.merge(request.provider_opts)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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
