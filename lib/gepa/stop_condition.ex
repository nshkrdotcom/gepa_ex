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
  def should_stop?(%__MODULE__{conditions: conditions, mode: :any}, state) do
    Enum.any?(conditions, fn condition ->
      module = condition.__struct__
      module.should_stop?(condition, state)
    end)
  end

  def should_stop?(%__MODULE__{conditions: conditions, mode: :all}, state) do
    Enum.all?(conditions, fn condition ->
      module = condition.__struct__
      module.should_stop?(condition, state)
    end)
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
  def should_stop?(%__MODULE__{max_calls: max_calls}, %GEPA.State{total_num_evals: total}) do
    total >= max_calls
  end
end
