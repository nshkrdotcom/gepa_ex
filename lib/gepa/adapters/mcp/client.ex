defmodule GEPA.Adapters.MCP.Client do
  @moduledoc """
  Minimal MCP client behaviour for GEPA's Elixir adapter layer.

  The actual Model Context Protocol transport can be supplied by a caller.  For
  unit tests and local optimization, `GEPA.Adapters.MCP.Client.Static` provides a
  deterministic in-memory implementation.
  """

  @type tool :: %{required(String.t()) => term()} | %{required(atom()) => term()}

  @callback list_tools(term()) :: {:ok, [tool()]} | {:error, term()}
  @callback call_tool(term(), String.t(), map()) :: {:ok, term()} | {:error, term()}

  @spec list_tools(term()) :: {:ok, [tool()]} | {:error, term()}
  def list_tools(client), do: module_for(client).list_tools(client)

  @spec call_tool(term(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(client, name, arguments),
    do: module_for(client).call_tool(client, name, arguments)

  @doc "Create a dependency-free MCP client transport config."
  @spec create(keyword() | map()) :: term()
  def create(opts \\ []) do
    opts = Map.new(opts)
    server_params = Map.get(opts, :server_params)
    remote_url = Map.get(opts, :remote_url)

    cond do
      server_params && remote_url ->
        raise ArgumentError, "provide local server_params or remote_url, not both"

      server_params ->
        stdio_client(server_params, opts)

      remote_url ->
        remote_client(remote_url, opts)

      true ->
        raise ArgumentError, "must provide either server_params or remote_url"
    end
  end

  defp stdio_client(server_params, opts) do
    struct(GEPA.Adapters.MCP.Client.Stdio,
      command: Map.get(server_params, :command) || Map.get(server_params, "command"),
      args: Map.get(server_params, :args) || Map.get(server_params, "args") || [],
      env: Map.get(server_params, :env) || Map.get(server_params, "env") || %{},
      timeout: Map.get(opts, :timeout, 30_000)
    )
  end

  defp remote_client(remote_url, opts) do
    remote_transport = Map.get(opts, :remote_transport, "sse")
    headers = Map.get(opts, :remote_headers, %{})
    timeout = Map.get(opts, :timeout, 30_000)

    case remote_transport do
      transport when transport in [:sse, "sse"] ->
        struct(GEPA.Adapters.MCP.Client.SSE, url: remote_url, headers: headers, timeout: timeout)

      transport when transport in [:streamable_http, "streamable_http"] ->
        struct(GEPA.Adapters.MCP.Client.StreamableHTTP,
          url: remote_url,
          headers: headers,
          timeout: timeout
        )

      other ->
        raise ArgumentError, "unknown remote transport: #{inspect(other)}"
    end
  end

  defp module_for(%module{}), do: module
  defp module_for(module) when is_atom(module), do: module
end

defmodule GEPA.Adapters.MCP.Client.Static do
  @moduledoc """
  In-memory MCP client for tests.  Tools are supplied as a map of name to
  `%{description:, input_schema:, run:}` or as `{name, fun}` pairs.
  """

  @behaviour GEPA.Adapters.MCP.Client

  defstruct tools: %{}

  @spec new(keyword() | map()) :: %__MODULE__{}
  def new(opts \\ []) do
    opts = Map.new(opts)
    %__MODULE__{tools: Map.get(opts, :tools, %{})}
  end

  @impl true
  def list_tools(%__MODULE__{tools: tools}) do
    {:ok,
     Enum.map(tools, fn {name, spec} ->
       metadata = if is_map(spec), do: spec, else: %{}

       %{
         "name" => to_string(name),
         "description" => Map.get(metadata, :description, Map.get(metadata, "description", "")),
         "input_schema" =>
           Map.get(metadata, :input_schema, Map.get(metadata, "input_schema", %{}))
       }
     end)}
  end

  @impl true
  def call_tool(%__MODULE__{tools: tools}, name, arguments) do
    case Map.get(tools, name) || Map.get(tools, String.to_atom(name)) do
      nil ->
        {:error, {:unknown_tool, name}}

      fun when is_function(fun, 1) ->
        {:ok, fun.(arguments)}

      %{run: fun} when is_function(fun, 1) ->
        {:ok, fun.(arguments)}

      %{"run" => fun} when is_function(fun, 1) ->
        {:ok, fun.(arguments)}

      spec ->
        {:ok, Map.get(spec, :result, Map.get(spec, "result"))}
    end
  end
end

defmodule GEPA.Adapters.MCP.Client.Stdio do
  @moduledoc "Placeholder stdio MCP transport config.

  Supply a concrete module implementing `GEPA.Adapters.MCP.Client` when you want
  to run a real MCP process.  This struct is intentionally dependency-free so
  the core library does not force an MCP SDK install.
  "
  defstruct command: nil, args: [], env: %{}, timeout: 30_000
end

defmodule GEPA.Adapters.MCP.Client.SSE do
  @moduledoc "Placeholder SSE MCP transport config."
  defstruct url: nil, headers: %{}, timeout: 30_000
end

defmodule GEPA.Adapters.MCP.Client.StreamableHTTP do
  @moduledoc "Placeholder Streamable HTTP MCP transport config."
  defstruct url: nil, headers: %{}, timeout: 30_000
end
