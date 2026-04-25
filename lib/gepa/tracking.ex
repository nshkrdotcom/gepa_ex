defmodule GEPA.Tracking do
  @moduledoc """
  Experiment tracking behavior and built-in trackers.

  HTML/artifact visualization is intentionally excluded. Trackers receive
  scalar metrics, tables, and summary maps from the engine and can forward
  them to external systems or keep them in memory for tests and local tooling.
  """

  @type tracker :: module() | struct() | nil

  @callback start(term()) :: :ok | {:ok, term()}
  @callback log_metrics(term(), map(), keyword()) :: :ok
  @callback log_table(term(), String.t(), [map()], keyword()) :: :ok
  @callback log_summary(term(), map()) :: :ok
  @callback finish(term()) :: :ok

  @optional_callbacks start: 1, log_table: 4, finish: 1

  @spec start(tracker()) :: :ok
  def start(nil), do: :ok
  def start(tracker), do: dispatch(tracker, :start, [tracker])

  @spec log_metrics(tracker(), map(), keyword()) :: :ok
  def log_metrics(tracker, metrics, opts \\ [])
  def log_metrics(nil, _metrics, _opts), do: :ok

  def log_metrics(tracker, metrics, opts),
    do: dispatch(tracker, :log_metrics, [tracker, metrics, opts])

  @spec log_table(tracker(), String.t(), [map()], keyword()) :: :ok
  def log_table(tracker, name, rows, opts \\ [])
  def log_table(nil, _name, _rows, _opts), do: :ok

  def log_table(tracker, name, rows, opts),
    do: dispatch(tracker, :log_table, [tracker, name, rows, opts])

  @spec log_summary(tracker(), map()) :: :ok
  def log_summary(nil, _summary), do: :ok
  def log_summary(tracker, summary), do: dispatch(tracker, :log_summary, [tracker, summary])

  @spec finish(tracker()) :: :ok
  def finish(nil), do: :ok
  def finish(tracker), do: dispatch(tracker, :finish, [tracker])

  defp dispatch(%module{}, function, args), do: dispatch_module(module, function, args)

  defp dispatch(module, function, args) when is_atom(module),
    do: dispatch_module(module, function, args)

  defp dispatch(_tracker, _function, _args), do: :ok

  defp dispatch_module(module, function, args) do
    if function_exported?(module, function, length(args)) do
      apply(module, function, args)
      :ok
    else
      :ok
    end
  rescue
    exception ->
      require Logger

      Logger.warning(
        "GEPA tracker #{inspect(module)} #{function} failed: #{Exception.message(exception)}"
      )

      :ok
  end
end

defmodule GEPA.Tracking.NoOp do
  @moduledoc "Tracker that discards all metrics."

  @behaviour GEPA.Tracking

  defstruct []

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def log_metrics(_tracker, _metrics, _opts), do: :ok

  @impl true
  def log_summary(_tracker, _summary), do: :ok
end

defmodule GEPA.Tracking.InMemory do
  @moduledoc """
  In-memory tracker backed by an Agent.
  """

  @behaviour GEPA.Tracking

  defstruct [:agent, key_prefix: nil]

  @type t :: %__MODULE__{agent: pid(), key_prefix: String.t() | nil}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{metrics: [], tables: [], summaries: []}
      end)

    %__MODULE__{agent: agent, key_prefix: Keyword.get(opts, :key_prefix)}
  end

  @impl true
  def log_metrics(%__MODULE__{} = tracker, metrics, opts) do
    Agent.update(tracker.agent, fn state ->
      entry = %{metrics: prefix_keys(metrics, tracker.key_prefix), opts: opts}
      Map.update!(state, :metrics, &(&1 ++ [entry]))
    end)
  end

  @impl true
  def log_table(%__MODULE__{} = tracker, name, rows, opts) do
    Agent.update(tracker.agent, fn state ->
      entry = %{name: prefixed_name(name, tracker.key_prefix), rows: rows, opts: opts}
      Map.update!(state, :tables, &(&1 ++ [entry]))
    end)
  end

  @impl true
  def log_summary(%__MODULE__{} = tracker, summary) do
    Agent.update(tracker.agent, fn state ->
      Map.update!(state, :summaries, &(&1 ++ [prefix_keys(summary, tracker.key_prefix)]))
    end)
  end

  @impl true
  def finish(%__MODULE__{}), do: :ok

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1)

  defp prefix_keys(metrics, nil), do: metrics

  defp prefix_keys(metrics, prefix) do
    Map.new(metrics, fn {key, value} -> {"#{prefix}.#{key}", value} end)
  end

  defp prefixed_name(name, nil), do: name
  defp prefixed_name(name, prefix), do: "#{prefix}.#{name}"
end
