defmodule GEPA.Tracking.WandB do
  @moduledoc """
  W&B tracker placeholder behind `GEPA.Tracking`.

  The module is intentionally dependency-free and explicit: it reports
  `{:error, {:not_configured, :wandb}}` until a production backend is wired in.
  """

  @behaviour GEPA.Tracking

  defstruct [:api_key, :project, :entity, :run_name, opts: []]

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          project: String.t() | nil,
          entity: String.t() | nil,
          run_name: String.t() | nil,
          opts: keyword()
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      api_key: Map.get(opts, :api_key, Map.get(opts, "api_key")),
      project: Map.get(opts, :project, Map.get(opts, "project")),
      entity: Map.get(opts, :entity, Map.get(opts, "entity")),
      run_name: Map.get(opts, :run_name, Map.get(opts, "run_name")),
      opts: Map.get(opts, :opts, Map.get(opts, "opts", []))
    }
  end

  @spec configured?(t()) :: boolean()
  def configured?(%__MODULE__{} = tracker),
    do: present?(tracker.api_key) and present?(tracker.project)

  @impl true
  def start(%__MODULE__{} = tracker), do: configured_result(tracker, :wandb)

  @impl true
  def log_metrics(%__MODULE__{} = tracker, _metrics, _opts),
    do: configured_result(tracker, :wandb)

  @impl true
  def log_table(%__MODULE__{} = tracker, _name, _rows, _opts),
    do: configured_result(tracker, :wandb)

  @impl true
  def log_summary(%__MODULE__{} = tracker, _summary), do: configured_result(tracker, :wandb)

  @impl true
  def finish(%__MODULE__{} = tracker), do: configured_result(tracker, :wandb)

  defp configured_result(tracker, backend) do
    if configured?(tracker), do: :ok, else: {:error, {:not_configured, backend}}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end

defmodule GEPA.Tracking.MLflow do
  @moduledoc """
  MLflow tracker placeholder behind `GEPA.Tracking`.

  The module is intentionally dependency-free and explicit: it reports
  `{:error, {:not_configured, :mlflow}}` until a production backend is wired in.
  """

  @behaviour GEPA.Tracking

  defstruct [:tracking_uri, :experiment_name, :run_name, opts: []]

  @type t :: %__MODULE__{
          tracking_uri: String.t() | nil,
          experiment_name: String.t() | nil,
          run_name: String.t() | nil,
          opts: keyword()
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      tracking_uri: Map.get(opts, :tracking_uri, Map.get(opts, "tracking_uri")),
      experiment_name: Map.get(opts, :experiment_name, Map.get(opts, "experiment_name")),
      run_name: Map.get(opts, :run_name, Map.get(opts, "run_name")),
      opts: Map.get(opts, :opts, Map.get(opts, "opts", []))
    }
  end

  @spec configured?(t()) :: boolean()
  def configured?(%__MODULE__{} = tracker) do
    present?(tracker.tracking_uri) and present?(tracker.experiment_name)
  end

  @impl true
  def start(%__MODULE__{} = tracker), do: configured_result(tracker, :mlflow)

  @impl true
  def log_metrics(%__MODULE__{} = tracker, _metrics, _opts),
    do: configured_result(tracker, :mlflow)

  @impl true
  def log_table(%__MODULE__{} = tracker, _name, _rows, _opts),
    do: configured_result(tracker, :mlflow)

  @impl true
  def log_summary(%__MODULE__{} = tracker, _summary), do: configured_result(tracker, :mlflow)

  @impl true
  def finish(%__MODULE__{} = tracker), do: configured_result(tracker, :mlflow)

  defp configured_result(tracker, backend) do
    if configured?(tracker), do: :ok, else: {:error, {:not_configured, backend}}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
