defmodule GEPA.StopCondition do
  @moduledoc """
  Behavior for stop conditions that control when optimization terminates.

  Stop conditions are predicates over the optimization state that return
  true when the optimization should stop.

  ## Example Implementations

      defmodule TimeoutStop do
        @behaviour GEPA.StopCondition

        defstruct [:start_time, :timeout_ms]

        @impl true
        def should_stop?(%__MODULE__{start_time: start, timeout_ms: timeout}, _state) do
          System.monotonic_time(:millisecond) - start > timeout
        end
      end

  ## Composing Stop Conditions

  Use `GEPA.StopCondition.Composite` to combine multiple conditions with AND/OR logic.
  """

  @doc """
  Check if optimization should stop based on current state.

  ## Parameters

  - `condition`: The stop condition struct/state
  - `gepa_state`: Current GEPA optimization state

  ## Returns

  `true` if optimization should stop, `false` otherwise

  ## Contract

  - Should be pure function (no side effects except reading state)
  - Should be monotonic: once true, should stay true
  - Should be fast (<1ms) to check
  """
  @callback should_stop?(t(), GEPA.State.t()) :: boolean()

  @type t :: term()
end

defmodule GEPA.StopCondition.Composite do
  @moduledoc """
  Combines multiple stop conditions with AND/OR logic.

  ## Example

      composite = %GEPA.StopCondition.Composite{
        conditions: [timeout_condition, budget_condition],
        mode: :any
      }

      # Stops when ANY condition triggers
      should_stop?(composite, state)
  """

  @behaviour GEPA.StopCondition

  @type t :: %__MODULE__{
          conditions: [term()],
          mode: :any | :all
        }

  defstruct [:conditions, :mode]

  @doc """
  Create a composite stop condition.

  ## Parameters

  - `conditions`: List of stop condition structs
  - `mode`: `:any` (OR logic) or `:all` (AND logic)
  """
  @spec new([term()], :any | :all) :: t()
  def new(conditions, mode \\ :any) when mode in [:any, :all] do
    %__MODULE__{conditions: conditions, mode: mode}
  end

  @impl true
  @spec should_stop?(t(), GEPA.State.t()) :: boolean()
  def should_stop?(%__MODULE__{conditions: conditions, mode: :any}, state) do
    Enum.any?(conditions, fn condition ->
      module = condition.__struct__
      module.should_stop?(condition, state)
    end)
  end

  @impl true
  def should_stop?(%__MODULE__{conditions: conditions, mode: :all}, state) do
    Enum.all?(conditions, fn condition ->
      module = condition.__struct__
      module.should_stop?(condition, state)
    end)
  end
end

defmodule GEPA.StopCondition.Timeout do
  @moduledoc """
  Time-based stop condition.

  Stops optimization after a specified duration.

  ## Examples

      # Stop after 1 hour
      Timeout.new(hours: 1)

      # Stop after 30 minutes
      Timeout.new(minutes: 30)

      # Stop after 10 seconds
      Timeout.new(seconds: 10)
  """

  @behaviour GEPA.StopCondition

  defstruct [:start_time, :max_seconds]

  @type t :: %__MODULE__{
          start_time: integer(),
          max_seconds: pos_integer()
        }

  @doc """
  Creates a timeout stop condition.

  ## Options
    - `:seconds` - Duration in seconds
    - `:minutes` - Duration in minutes
    - `:hours` - Duration in hours

  Only one unit should be specified.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    max_seconds =
      cond do
        Keyword.has_key?(opts, :seconds) -> Keyword.fetch!(opts, :seconds)
        Keyword.has_key?(opts, :minutes) -> Keyword.fetch!(opts, :minutes) * 60
        Keyword.has_key?(opts, :hours) -> Keyword.fetch!(opts, :hours) * 3600
        true -> raise ArgumentError, "Must specify :seconds, :minutes, or :hours"
      end

    %__MODULE__{
      start_time: System.monotonic_time(:second),
      max_seconds: max_seconds
    }
  end

  @impl true
  @spec should_stop?(t(), GEPA.State.t()) :: boolean()
  def should_stop?(%__MODULE__{} = condition, _state) do
    elapsed = System.monotonic_time(:second) - condition.start_time
    elapsed >= condition.max_seconds
  end
end

defmodule GEPA.StopCondition.NoImprovement do
  @moduledoc """
  Stops when no improvement observed for patience iterations.

  Tracks best score seen and stops if no improvement for N iterations.

  ## Examples

      # Stop if no improvement for 10 iterations
      NoImprovement.new(patience: 10)

      # Require at least 0.01 improvement
      NoImprovement.new(patience: 5, min_improvement: 0.01)
  """

  @behaviour GEPA.StopCondition

  defstruct [
    :patience,
    :min_improvement,
    :best_score,
    :iterations_without_improvement
  ]

  @type t :: %__MODULE__{
          patience: pos_integer(),
          min_improvement: float(),
          best_score: float(),
          iterations_without_improvement: non_neg_integer()
        }

  @doc """
  Creates a no improvement stop condition.

  ## Options
    - `:patience` - Number of iterations to wait (required)
    - `:min_improvement` - Minimum improvement to count (default: 0.001)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      patience: Keyword.fetch!(opts, :patience),
      min_improvement: Keyword.get(opts, :min_improvement, 0.001),
      best_score: 0.0,
      iterations_without_improvement: 0
    }
  end

  @doc """
  Updates condition with new state (call after each iteration).
  """
  @spec update(t(), GEPA.State.t()) :: t()
  def update(%__MODULE__{} = condition, state) do
    {current_score, _} = GEPA.State.get_program_score(state, get_best_program_idx(state))

    improvement = current_score - condition.best_score

    cond do
      improvement >= condition.min_improvement ->
        # Real improvement - reset counter
        %{condition | best_score: current_score, iterations_without_improvement: 0}

      current_score > condition.best_score ->
        # Small improvement - update best but increment counter
        %{
          condition
          | best_score: current_score,
            iterations_without_improvement: condition.iterations_without_improvement + 1
        }

      true ->
        # No improvement
        %{
          condition
          | iterations_without_improvement: condition.iterations_without_improvement + 1
        }
    end
  end

  @impl true
  @spec should_stop?(t(), GEPA.State.t()) :: boolean()
  def should_stop?(%__MODULE__{} = condition, _state) do
    condition.iterations_without_improvement >= condition.patience
  end

  defp get_best_program_idx(state) do
    # Find program with best average score
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.max_by(fn {scores, _idx} ->
      if map_size(scores) > 0 do
        Enum.sum(Map.values(scores)) / map_size(scores)
      else
        0.0
      end
    end)
    |> elem(1)
  rescue
    _ -> 0
  end
end

defmodule GEPA.StopCondition.MaxCalls do
  @moduledoc """
  Stops after a maximum number of metric evaluations.

  This is the most common stop condition for budgeting optimization runs.
  """

  @behaviour GEPA.StopCondition

  defstruct [:max_calls]

  @type t :: %__MODULE__{max_calls: pos_integer()}

  @spec new(pos_integer()) :: t()
  def new(max_calls) when is_integer(max_calls) and max_calls > 0 do
    %__MODULE__{max_calls: max_calls}
  end

  @impl true
  @spec should_stop?(t(), GEPA.State.t()) :: boolean()
  def should_stop?(%__MODULE__{max_calls: max_calls}, %GEPA.State{total_num_evals: total}) do
    total >= max_calls
  end
end
