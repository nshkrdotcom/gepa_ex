defmodule GEPA.Tracking.ExperimentTracker do
  @moduledoc """
  Dependency-free experiment tracker compatible with the upstream tracker API.

  The tracker stores metrics, tables, config, summary, and HTML artifacts in an
  Agent.  It can be used directly as `tracker:` in `GEPA.optimize/1` because it
  implements the callbacks expected by `GEPA.Tracking`.
  """

  defstruct [
    :agent,
    key_prefix: "",
    attach_existing: false,
    use_wandb: false,
    wandb_api_key: nil,
    wandb_init_kwargs: nil,
    wandb_attach_existing: false,
    wandb_step_metric: nil,
    use_mlflow: false,
    mlflow_tracking_uri: nil,
    mlflow_experiment_name: nil,
    mlflow_attach_existing: false
  ]

  @type t :: %__MODULE__{
          agent: pid(),
          key_prefix: String.t(),
          attach_existing: boolean(),
          use_wandb: boolean(),
          wandb_api_key: String.t() | nil,
          wandb_init_kwargs: map() | nil,
          wandb_attach_existing: boolean(),
          wandb_step_metric: String.t() | nil,
          use_mlflow: boolean(),
          mlflow_tracking_uri: String.t() | nil,
          mlflow_experiment_name: String.t() | nil,
          mlflow_attach_existing: boolean()
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          started?: false,
          finished?: false,
          start_count: 0,
          finish_count: 0,
          attached?: false,
          metrics: [],
          tables: %{},
          config: %{},
          summary: %{},
          html: %{},
          defined_metrics: []
        }
      end)

    %__MODULE__{
      agent: agent,
      key_prefix: Map.get(opts, :key_prefix, "") || "",
      attach_existing: Map.get(opts, :attach_existing, false),
      use_wandb: Map.get(opts, :use_wandb, false),
      wandb_api_key: Map.get(opts, :wandb_api_key),
      wandb_init_kwargs: Map.get(opts, :wandb_init_kwargs),
      wandb_attach_existing: Map.get(opts, :wandb_attach_existing, false),
      wandb_step_metric: Map.get(opts, :wandb_step_metric),
      use_mlflow: Map.get(opts, :use_mlflow, false),
      mlflow_tracking_uri: Map.get(opts, :mlflow_tracking_uri),
      mlflow_experiment_name: Map.get(opts, :mlflow_experiment_name),
      mlflow_attach_existing: Map.get(opts, :mlflow_attach_existing, false)
    }
  end

  def start(%__MODULE__{} = tracker) do
    Agent.update(tracker.agent, fn state ->
      if attach_existing?(tracker) do
        %{state | attached?: true}
      else
        %{state | started?: true, start_count: state.start_count + 1}
      end
    end)

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
      state = maybe_define_step_metric(state, tracker.wandb_step_metric)

      {metrics, stored_step} =
        metrics
        |> then(&prefix_map(tracker, &1))
        |> maybe_put_step_metric(tracker.wandb_step_metric, step)

      Map.update!(
        state,
        :metrics,
        &(&1 ++ [%{step: stored_step, metrics: metrics}])
      )
    end)

    :ok
  end

  def log_table(%__MODULE__{} = tracker, name, rows, opts \\ []) do
    columns = Keyword.get(opts, :columns)
    key = prefix(tracker, name)

    Agent.update(tracker.agent, &update_table_state(&1, key, columns, List.wrap(rows)))

    :ok
  end

  defp update_table_state(state, key, columns, new_rows) do
    Map.update!(state, :tables, fn tables ->
      Map.update(tables, key, %{columns: columns, rows: new_rows}, fn existing ->
        %{existing | rows: existing.rows ++ new_rows}
      end)
    end)
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

  def finish(%__MODULE__{} = tracker) do
    Agent.update(tracker.agent, fn state ->
      if attach_existing?(tracker) do
        state
      else
        %{state | finished?: true, finish_count: state.finish_count + 1}
      end
    end)

    :ok
  end

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1)

  defp attach_existing?(%__MODULE__{} = tracker) do
    tracker.attach_existing ||
      (tracker.use_wandb && tracker.wandb_attach_existing) ||
      (tracker.use_mlflow && tracker.mlflow_attach_existing)
  end

  defp prefix_map(%__MODULE__{} = tracker, map) do
    Map.new(map, fn {key, value} -> {prefix(tracker, key), value} end)
  end

  defp maybe_define_step_metric(state, nil), do: state

  defp maybe_define_step_metric(state, step_metric) do
    if step_metric in state.defined_metrics do
      state
    else
      %{state | defined_metrics: state.defined_metrics ++ [step_metric, "*"]}
    end
  end

  defp maybe_put_step_metric(metrics, nil, step), do: {metrics, step}
  defp maybe_put_step_metric(metrics, _step_metric, nil), do: {metrics, nil}

  defp maybe_put_step_metric(metrics, step_metric, step) do
    {Map.put(metrics, step_metric, step), nil}
  end

  defp prefix(%__MODULE__{key_prefix: ""}, key), do: to_string(key)
  defp prefix(%__MODULE__{key_prefix: prefix}, key), do: prefix <> to_string(key)
end
