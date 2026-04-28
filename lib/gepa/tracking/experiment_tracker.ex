defmodule GEPA.Tracking.ExperimentTracker do
  @moduledoc """
  Dependency-free experiment tracker compatible with the upstream tracker API.

  The tracker stores metrics, tables, config, summary, and HTML artifacts in an
  Agent.  It can be used directly as `tracker:` in `GEPA.optimize/1` because it
  implements the callbacks expected by `GEPA.Tracking`.
  """

  defstruct [:agent, key_prefix: "", attach_existing: false]

  @type t :: %__MODULE__{agent: pid(), key_prefix: String.t(), attach_existing: boolean()}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{started?: false, metrics: [], tables: %{}, config: %{}, summary: %{}, html: %{}}
      end)

    %__MODULE__{
      agent: agent,
      key_prefix: Map.get(opts, :key_prefix, "") || "",
      attach_existing: Map.get(opts, :attach_existing, false)
    }
  end

  def start(%__MODULE__{} = tracker) do
    Agent.update(tracker.agent, &Map.put(&1, :started?, true))
    :ok
  end

  def log_config(%__MODULE__{} = tracker, config) when is_map(config) do
    Agent.update(tracker.agent, fn state ->
      Map.update!(state, :config, &Map.merge(&1, prefix_map(tracker, config)))
    end)

    :ok
  end

  def log_metrics(%__MODULE__{} = tracker, metrics, opts \\ []) when is_map(metrics) do
    step = Keyword.get(opts, :step)

    Agent.update(tracker.agent, fn state ->
      Map.update!(
        state,
        :metrics,
        &(&1 ++ [%{step: step, metrics: prefix_map(tracker, metrics)}])
      )
    end)

    :ok
  end

  def log_table(%__MODULE__{} = tracker, name, rows, opts \\ []) do
    columns = Keyword.get(opts, :columns)
    key = prefix(tracker, name)

    Agent.update(tracker.agent, fn state ->
      Map.update!(state, :tables, fn tables ->
        Map.update(tables, key, %{columns: columns, rows: List.wrap(rows)}, fn existing ->
          %{existing | rows: existing.rows ++ List.wrap(rows)}
        end)
      end)
    end)

    :ok
  end

  def log_html(%__MODULE__{} = tracker, html, key \\ "candidate_tree") do
    Agent.update(tracker.agent, fn state ->
      Map.update!(state, :html, &Map.put(&1, prefix(tracker, key), html))
    end)

    :ok
  end

  def log_summary(%__MODULE__{} = tracker, summary) when is_map(summary) do
    Agent.update(tracker.agent, fn state ->
      Map.update!(state, :summary, &Map.merge(&1, prefix_map(tracker, summary)))
    end)

    :ok
  end

  def finish(%__MODULE__{}), do: :ok

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1)

  defp prefix_map(%__MODULE__{} = tracker, map) do
    Map.new(map, fn {key, value} -> {prefix(tracker, key), value} end)
  end

  defp prefix(%__MODULE__{key_prefix: ""}, key), do: to_string(key)
  defp prefix(%__MODULE__{key_prefix: prefix}, key), do: prefix <> to_string(key)
end
