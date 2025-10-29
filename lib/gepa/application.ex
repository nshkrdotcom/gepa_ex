defmodule GEPA.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Task supervisor for parallel evaluation
      {Task.Supervisor, name: GEPA.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: GEPA.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
