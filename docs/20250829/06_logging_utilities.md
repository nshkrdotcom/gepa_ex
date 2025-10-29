# GEPA Logging and Utilities Documentation

## Overview

The GEPA Python library includes a comprehensive logging and utilities system designed to track experiments, log progress, and control optimization execution. The system is modular and supports multiple backends (wandb, MLflow), flexible logging mechanisms, and various stop conditions for graceful termination.

## Directory Structure

```
gepa/
├── logging/
│   ├── __init__.py
│   ├── experiment_tracker.py    # Unified experiment tracking (wandb/MLflow)
│   ├── logger.py                # Logger implementation with file capture
│   └── utils.py                 # Detailed metrics logging utility
└── utils/
    ├── __init__.py
    └── stop_condition.py        # Stop condition implementations
```

## 1. Experiment Tracking System

### 1.1 ExperimentTracker Class

**File**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/logging/experiment_tracker.py`

The `ExperimentTracker` provides unified experiment tracking supporting both wandb and MLflow backends, allowing users to track metrics, parameters, and progress across optimization runs.

#### Key Features

1. **Multi-backend support**: Can use wandb, MLflow, or both simultaneously
2. **Context manager**: Implements `__enter__` and `__exit__` for automatic lifecycle management
3. **Lazy initialization**: Imports backends only when needed
4. **Graceful error handling**: Continues operation even if logging fails

#### Architecture

```python
class ExperimentTracker:
    def __init__(
        self,
        use_wandb: bool = False,
        wandb_api_key: str | None = None,
        wandb_init_kwargs: dict[str, Any] | None = None,
        use_mlflow: bool = False,
        mlflow_tracking_uri: str | None = None,
        mlflow_experiment_name: str | None = None,
    )
```

#### Methods

1. **initialize()**: Initializes configured backends
   - Calls `_initialize_wandb()` if `use_wandb=True`
   - Calls `_initialize_mlflow()` if `use_mlflow=True`
   - Lazy imports to avoid dependency issues

2. **start_run()**: Starts a new tracking run
   - For wandb: Calls `wandb.init(**wandb_init_kwargs)`
   - For MLflow: Calls `mlflow.start_run()` only if no active run exists
   - Tracks whether it created the MLflow run with `_created_mlflow_run` flag

3. **log_metrics(metrics: dict[str, Any], step: int | None)**: Logs metrics to active backends
   - Accepts any dictionary of metric key-value pairs
   - Optional step parameter for time-series tracking
   - Prints warnings but doesn't fail if logging fails

4. **end_run()**: Ends the current tracking run
   - For wandb: Calls `wandb.finish()` if run exists
   - For MLflow: Only ends run if this tracker created it (respects external runs)
   - Graceful cleanup even on errors

5. **is_active()**: Checks if any backend has an active run
   - Returns True if wandb.run or mlflow.active_run() exists
   - Used to verify tracking status

#### Usage Pattern

```python
# Context manager usage (recommended)
with ExperimentTracker(use_wandb=True, wandb_init_kwargs={"project": "my-project"}) as tracker:
    tracker.log_metrics({"loss": 0.5, "accuracy": 0.95}, step=1)

# Manual usage
tracker = create_experiment_tracker(use_mlflow=True, mlflow_tracking_uri="http://localhost:5000")
tracker.initialize()
tracker.start_run()
tracker.log_metrics({"iteration": 1, "score": 0.8})
tracker.end_run()
```

#### Integration with GEPA

The experiment tracker is instantiated in `api.optimize()` and passed to:
- `GEPAEngine`: For logging iteration metrics
- `ReflectiveMutationProposer`: For logging reflection-specific metrics
- Logging utilities: For detailed validation metrics

### 1.2 Factory Function

```python
def create_experiment_tracker(...) -> ExperimentTracker
```

Factory function that simplifies creation of experiment trackers with sensible defaults.

## 2. Logger System

### 2.1 Logger Protocol

**File**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/logging/logger.py`

```python
class LoggerProtocol(Protocol):
    def log(self, message: str): ...
```

A simple protocol defining the logging interface. This allows for pluggable logging implementations.

### 2.2 StdOutLogger

```python
class StdOutLogger(LoggerProtocol):
    def log(self, message: str):
        print(message)
```

A minimal logger that simply prints to stdout. Used as the default logger when no custom logger is provided.

### 2.3 Logger Class

The `Logger` class provides file-based logging with stdout/stderr capture capabilities.

#### Key Features

1. **Dual file output**: Separate files for stdout and stderr
2. **Context manager**: Automatic sys.stdout/stderr redirection
3. **Tee functionality**: Logs to both console and file simultaneously
4. **Flush control**: Explicit flushing after each log call

#### Architecture

```python
class Logger(LoggerProtocol):
    def __init__(self, filename, mode="a"):
        # Creates two files:
        # 1. {filename} for stdout
        # 2. {filename with run_log. replaced by run_log_stderr.} for stderr
```

#### Tee Class

A utility class that writes to multiple file-like objects simultaneously:

```python
class Tee:
    def __init__(self, *files):
        self.files = files

    def write(self, obj):
        for f in self.files:
            f.write(obj)

    def flush(self):
        for f in self.files:
            if hasattr(f, "flush"):
                f.flush()
```

Implements the file protocol including:
- `write()`: Write to all files
- `flush()`: Flush all files
- `isatty()`: Returns True if any file is a terminal
- `close()`: Close all files
- `fileno()`: Returns first available file descriptor

#### Usage Modes

1. **Context Manager Mode** (recommended):
```python
with Logger("run_log.txt") as logger:
    logger.log("This goes to both file and stdout")
    print("This also gets captured")
```

2. **Manual Mode**:
```python
logger = Logger("run_log.txt")
logger.log("This goes to both files")  # Writes to both stdout and stderr files
```

#### Behavior Details

- When used as context manager (`modified_sys=True`):
  - `sys.stdout` is redirected to `Tee(original_stdout, file_handle)`
  - `sys.stderr` is redirected to `Tee(original_stderr, file_handle_stderr)`
  - `logger.log()` uses `print()`, which goes through the Tee

- When not used as context manager:
  - `logger.log()` prints to both stdout and stderr file handles
  - Regular `print()` statements are not captured

### 2.4 Logging Utilities

**File**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/logging/utils.py`

#### log_detailed_metrics_after_discovering_new_program()

A comprehensive function that logs detailed metrics after each new program discovery.

**Parameters:**
- `logger`: Logger instance for console/file output
- `gepa_state`: Current GEPA optimization state
- `new_program_idx`: Index of newly discovered program
- `valset_subscores`: Scores on validation set for the new program
- `experiment_tracker`: Experiment tracker for metrics logging
- `linear_pareto_front_program_idx`: Best program by aggregate score
- `valset_size`: Total validation set size
- `val_evaluation_policy`: Policy for evaluation strategy

**Logged Information:**

1. **Console Logs** (via logger):
   - Validation set score and coverage
   - Aggregate validation score
   - Individual validation scores
   - Pareto front scores and programs
   - Best aggregate score and program
   - Linear pareto front program

2. **Experiment Tracker Metrics**:
```python
{
    "iteration": int,
    "new_program_idx": int,
    "valset_pareto_front_scores": dict,
    "individual_valset_score_new_program": dict,
    "valset_pareto_front_agg": float,
    "valset_pareto_front_programs": dict,
    "best_valset_agg_score": float,
    "linear_pareto_front_program_idx": int,
    "best_program_as_per_agg_score_valset": int,
    "best_score_on_valset": float,
    "val_evaluated_count_new_program": int,
    "val_total_count": int,
    "val_program_average": float,
}
```

#### Integration in Engine

Called from `GEPAEngine._run_full_eval_and_add()` after:
1. Evaluating new program on validation set
2. Updating state with new program
3. Determining best program

## 3. Stop Conditions System

**File**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/utils/stop_condition.py`

The stop conditions system provides flexible, composable mechanisms for gracefully terminating optimization runs.

### 3.1 StopperProtocol

```python
@runtime_checkable
class StopperProtocol(Protocol):
    def __call__(self, gepa_state: GEPAState) -> bool:
        """Returns True when optimization should stop."""
        ...
```

A runtime-checkable protocol that defines the stop condition interface. All stoppers are callables that receive the current state and return a boolean.

### 3.2 Built-in Stoppers

#### TimeoutStopCondition

Stops after a specified time duration.

```python
class TimeoutStopCondition(StopperProtocol):
    def __init__(self, timeout_seconds: float):
        self.timeout_seconds = timeout_seconds
        self.start_time = time.time()

    def __call__(self, gepa_state: GEPAState) -> bool:
        return time.time() - self.start_time > self.timeout_seconds
```

**Use Case**: Time-bounded optimization, cloud resource management

#### FileStopper

Stops when a specified file exists.

```python
class FileStopper(StopperProtocol):
    def __init__(self, stop_file_path: str):
        self.stop_file_path = stop_file_path

    def __call__(self, gepa_state: GEPAState) -> bool:
        return os.path.exists(self.stop_file_path)

    def remove_stop_file(self):
        if os.path.exists(self.stop_file_path):
            os.remove(self.stop_file_path)
```

**Use Case**: Manual intervention, external process coordination

**Special Integration**: Automatically created in `api.optimize()` when `run_dir` is provided, checking for `{run_dir}/gepa.stop`

#### ScoreThresholdStopper

Stops when a score threshold is reached.

```python
class ScoreThresholdStopper(StopperProtocol):
    def __init__(self, threshold: float):
        self.threshold = threshold

    def __call__(self, gepa_state: GEPAState) -> bool:
        current_best_score = max(gepa_state.program_full_scores_val_set)
            if gepa_state.program_full_scores_val_set else 0.0
        return current_best_score >= self.threshold
```

**Use Case**: Goal-oriented optimization, quality thresholds

#### NoImprovementStopper

Stops after N iterations without improvement (early stopping).

```python
class NoImprovementStopper(StopperProtocol):
    def __init__(self, max_iterations_without_improvement: int):
        self.max_iterations_without_improvement = max_iterations_without_improvement
        self.best_score = float("-inf")
        self.iterations_without_improvement = 0

    def __call__(self, gepa_state: GEPAState) -> bool:
        current_score = max(gepa_state.program_full_scores_val_set)
            if gepa_state.program_full_scores_val_set else 0.0

        if current_score > self.best_score:
            self.best_score = current_score
            self.iterations_without_improvement = 0
        else:
            self.iterations_without_improvement += 1

        return self.iterations_without_improvement >= self.max_iterations_without_improvement

    def reset(self):
        """Reset the counter (useful when manually improving the score)."""
        self.iterations_without_improvement = 0
```

**Use Case**: Early stopping, preventing overfitting, resource conservation

#### SignalStopper

Stops when OS signals are received (SIGINT, SIGTERM).

```python
class SignalStopper(StopperProtocol):
    def __init__(self, signals=None):
        self.signals = signals or [signal.SIGINT, signal.SIGTERM]
        self._stop_requested = False
        self._original_handlers = {}
        self._setup_signal_handlers()

    def _setup_signal_handlers(self):
        def signal_handler(signum, frame):
            self._stop_requested = True

        for sig in self.signals:
            try:
                self._original_handlers[sig] = signal.signal(sig, signal_handler)
            except (OSError, ValueError):
                pass  # Signal not available on platform

    def cleanup(self):
        """Restore original signal handlers."""
        for sig, handler in self._original_handlers.items():
            try:
                signal.signal(sig, handler)
            except (OSError, ValueError):
                pass
```

**Use Case**: Graceful shutdown, Ctrl+C handling, container orchestration

#### MaxTrackedCandidatesStopper

Stops after tracking a maximum number of candidates.

```python
class MaxTrackedCandidatesStopper(StopperProtocol):
    def __init__(self, max_tracked_candidates: int):
        self.max_tracked_candidates = max_tracked_candidates

    def __call__(self, gepa_state: GEPAState) -> bool:
        return len(gepa_state.program_candidates) >= self.max_tracked_candidates
```

**Use Case**: Memory management, limiting search space

#### MaxMetricCallsStopper

Stops after a maximum number of metric evaluations.

```python
class MaxMetricCallsStopper(StopperProtocol):
    def __init__(self, max_metric_calls: int):
        self.max_metric_calls = max_metric_calls

    def __call__(self, gepa_state: GEPAState) -> bool:
        return gepa_state.total_num_evals >= self.max_metric_calls
```

**Use Case**: Budget control, API rate limiting, reproducible experiments

**Special Integration**: Automatically created in `api.optimize()` when `max_metric_calls` parameter is provided

### 3.3 CompositeStopper

Combines multiple stopping conditions with AND/OR logic.

```python
class CompositeStopper(StopperProtocol):
    def __init__(
        self,
        *stoppers: StopperProtocol,
        mode: Literal["any", "all"] = "any"
    ):
        self.stoppers = stoppers
        self.mode = mode

    def __call__(self, gepa_state: GEPAState) -> bool:
        if self.mode == "any":
            return any(stopper(gepa_state) for stopper in self.stoppers)
        elif self.mode == "all":
            return all(stopper(gepa_state) for stopper in self.stoppers)
```

**Modes:**
- `"any"`: Stops when ANY stopper triggers (OR logic)
- `"all"`: Stops when ALL stoppers trigger (AND logic)

**Use Cases:**
- Multiple budget constraints
- Combined time and iteration limits
- Quality threshold OR timeout

**Automatic Creation**: In `api.optimize()`, if multiple stop conditions are provided, they are automatically combined into a `CompositeStopper` with mode="any"

## 4. Integration with Optimization Loop

### 4.1 Engine Integration

**File**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/core/engine.py`

The `GEPAEngine` integrates logging and stop conditions throughout the optimization loop:

```python
class GEPAEngine:
    def __init__(
        self,
        logger: Any,
        experiment_tracker: Any,
        stop_callback: Callable[[Any], bool] | None = None,
        display_progress_bar: bool = False,
        ...
    )
```

#### Stop Condition Checking

```python
def _should_stop(self, state: GEPAState) -> bool:
    """Check if the optimization should stop."""
    if self._stop_requested:  # Manual stop request
        return True
    if self.stop_callback and self.stop_callback(state):
        return True
    return False

def request_stop(self):
    """Manually request the optimization to stop gracefully."""
    self.logger.log("Stop requested manually. Initiating graceful shutdown...")
    self._stop_requested = True
```

#### Main Loop Structure

```python
def run(self) -> GEPAState:
    # Initialize progress bar if requested
    progress_bar = None
    if self.display_progress_bar:
        # Detect MaxMetricCallsStopper for total count
        ...
        progress_bar = tqdm(total=total_calls, desc="GEPA Optimization", unit="rollouts")

    # Initialize state
    state = initialize_gepa_state(...)

    # Log base program score
    self.experiment_tracker.log_metrics({...}, step=state.i + 1)

    # Main optimization loop
    while not self._should_stop(state):
        # Update progress bar
        if self.display_progress_bar:
            delta = state.total_num_evals - last_pbar_val
            progress_bar.update(delta)
            last_pbar_val = state.total_num_evals

        try:
            state.save(self.run_dir, use_cloudpickle=self.use_cloudpickle)
            state.i += 1

            # Propose and evaluate new candidates
            ...

            # Log detailed metrics after discovering new program
            log_detailed_metrics_after_discovering_new_program(...)

        except Exception as e:
            self.logger.log(f"Iteration {state.i + 1}: Exception: {e}")
            if self.raise_on_exception:
                raise e

    # Cleanup
    if self.display_progress_bar:
        progress_bar.close()

    state.save(self.run_dir)
    return state
```

### 4.2 API Integration

**File**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/api.py`

The `optimize()` function sets up the complete logging and stopping infrastructure:

```python
def optimize(
    # Logging parameters
    logger: LoggerProtocol | None = None,
    run_dir: str | None = None,
    use_wandb: bool = False,
    wandb_api_key: str | None = None,
    wandb_init_kwargs: dict[str, Any] | None = None,
    use_mlflow: bool = False,
    mlflow_tracking_uri: str | None = None,
    mlflow_experiment_name: str | None = None,
    display_progress_bar: bool = False,

    # Stop condition parameters
    max_metric_calls=None,
    stop_callbacks: StopperProtocol | list[StopperProtocol] | None = None,
    ...
):
    # 1. Setup logger
    if logger is None:
        logger = StdOutLogger()

    # 2. Setup stop conditions
    stop_callbacks_list = []

    # Add user-provided stoppers
    if stop_callbacks is not None:
        if isinstance(stop_callbacks, list):
            stop_callbacks_list.extend(stop_callbacks)
        else:
            stop_callbacks_list.append(stop_callbacks)

    # Add file stopper if run_dir provided
    if run_dir is not None:
        stop_file_path = os.path.join(run_dir, "gepa.stop")
        file_stopper = FileStopper(stop_file_path)
        stop_callbacks_list.append(file_stopper)

    # Add max metric calls stopper if provided
    if max_metric_calls is not None:
        max_calls_stopper = MaxMetricCallsStopper(max_metric_calls)
        stop_callbacks_list.append(max_calls_stopper)

    # Require at least one stopping condition
    if len(stop_callbacks_list) == 0:
        raise ValueError("Must provide at least one of stop_callbacks or max_metric_calls")

    # Create composite stopper if multiple conditions
    if len(stop_callbacks_list) == 1:
        stop_callback = stop_callbacks_list[0]
    else:
        stop_callback = CompositeStopper(*stop_callbacks_list)

    # 3. Setup experiment tracker
    experiment_tracker = create_experiment_tracker(
        use_wandb=use_wandb,
        wandb_api_key=wandb_api_key,
        wandb_init_kwargs=wandb_init_kwargs,
        use_mlflow=use_mlflow,
        mlflow_tracking_uri=mlflow_tracking_uri,
        mlflow_experiment_name=mlflow_experiment_name,
    )

    # 4. Create engine with logging/stopping infrastructure
    engine = GEPAEngine(
        logger=logger,
        experiment_tracker=experiment_tracker,
        stop_callback=stop_callback,
        display_progress_bar=display_progress_bar,
        ...
    )

    # 5. Run with context manager for proper cleanup
    with experiment_tracker:
        state = engine.run()

    return GEPAResult.from_state(state)
```

## 5. Design Patterns and Principles

### 5.1 Protocol-Based Design

All major components use protocols for flexibility:
- `LoggerProtocol`: Allows custom logger implementations
- `StopperProtocol`: Enables custom stop conditions
- Runtime-checkable protocols for type safety

### 5.2 Context Manager Pattern

Both `Logger` and `ExperimentTracker` implement context managers:
- Automatic resource cleanup
- Exception safety
- Clear lifecycle management

### 5.3 Composite Pattern

`CompositeStopper` allows building complex stopping logic from simple conditions:
- Composable and testable
- Supports both AND and OR logic
- No special handling needed in engine

### 5.4 Fail-Safe Design

- Experiment tracker prints warnings instead of failing
- Stop conditions have exception handling
- Logger flushes after each write
- Signal handlers restore original handlers

### 5.5 Lazy Initialization

- Backends imported only when needed
- Prevents dependency issues
- Allows optional features

## 6. Elixir Port Considerations

### 6.1 Logger System

**Recommendation**: Use Elixir's built-in Logger

```elixir
# Instead of custom Logger class
require Logger

Logger.info("Iteration #{state.i + 1}: New program discovered")
Logger.metadata(iteration: state.i + 1, score: score)
```

**File Logging**: Configure Logger backends:
```elixir
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:iteration, :score]

# Add file backend
config :logger,
  backends: [:console, {LoggerFileBackend, :file_log}]

config :logger, :file_log,
  path: "/path/to/run_log.log",
  level: :info
```

**Tee Functionality**: Use Logger's multiple backends feature instead of custom Tee class

### 6.2 Experiment Tracking

**Recommendation**: Use Telemetry for metrics emission

```elixir
# Define telemetry events
:telemetry.execute(
  [:gepa, :iteration, :complete],
  %{score: score, iteration: iteration},
  %{program_idx: program_idx}
)

# Attach handlers for different backends
defmodule GEPA.Telemetry.WandbHandler do
  def handle_event([:gepa, :iteration, :complete], measurements, metadata, _config) do
    Wandb.log(measurements, step: metadata.iteration)
  end
end

:telemetry.attach(
  "wandb-handler",
  [:gepa, :iteration, :complete],
  &GEPA.Telemetry.WandbHandler.handle_event/4,
  nil
)
```

**Benefits**:
- Decoupled metrics emission from collection
- Multiple handlers (wandb, MLflow, custom) can subscribe
- Built-in span tracking for timing
- No lazy imports needed (supervision tree handles it)

### 6.3 Stop Conditions

**Recommendation**: Use behaviors and agent-based state

```elixir
defmodule GEPA.StopCondition do
  @callback should_stop?(state :: GEPA.State.t()) :: boolean()
end

defmodule GEPA.StopCondition.Timeout do
  @behaviour GEPA.StopCondition

  defstruct [:timeout_ms, :start_time]

  def new(timeout_ms) do
    %__MODULE__{
      timeout_ms: timeout_ms,
      start_time: System.monotonic_time(:millisecond)
    }
  end

  def should_stop?(%__MODULE__{} = condition, _state) do
    elapsed = System.monotonic_time(:millisecond) - condition.start_time
    elapsed > condition.timeout_ms
  end
end

defmodule GEPA.StopCondition.Composite do
  @behaviour GEPA.StopCondition

  defstruct [:conditions, :mode]  # mode: :any | :all

  def should_stop?(%__MODULE__{conditions: conditions, mode: :any}, state) do
    Enum.any?(conditions, fn condition ->
      condition.__struct__.should_stop?(condition, state)
    end)
  end

  def should_stop?(%__MODULE__{conditions: conditions, mode: :all}, state) do
    Enum.all?(conditions, fn condition ->
      condition.__struct__.should_stop?(condition, state)
    end)
  end
end
```

**File Stopper**: Use File.exists?/1
**Signal Stopper**: Use :os.set_signal/2 or trap exits in the supervisor

### 6.4 State Management for Stateful Stoppers

For stoppers with state (NoImprovementStopper, SignalStopper), consider:

1. **GenServer**: For complex state management
```elixir
defmodule GEPA.StopCondition.NoImprovementServer do
  use GenServer

  def start_link(max_iterations) do
    GenServer.start_link(__MODULE__, max_iterations, name: __MODULE__)
  end

  def should_stop?(state) do
    GenServer.call(__MODULE__, {:should_stop, state})
  end

  def handle_call({:should_stop, state}, _from, server_state) do
    # Update internal state and determine if should stop
    {should_stop, new_server_state} = check_improvement(state, server_state)
    {:reply, should_stop, new_server_state}
  end
end
```

2. **Agent**: For simpler state
```elixir
defmodule GEPA.StopCondition.NoImprovement do
  def new(max_iterations) do
    {:ok, agent} = Agent.start_link(fn ->
      %{best_score: :neg_infinity, iterations_without_improvement: 0, max: max_iterations}
    end)
    agent
  end

  def should_stop?(agent, state) do
    Agent.get_and_update(agent, fn server_state ->
      current_score = get_best_score(state)

      if current_score > server_state.best_score do
        {false, %{server_state | best_score: current_score, iterations_without_improvement: 0}}
      else
        new_count = server_state.iterations_without_improvement + 1
        should_stop = new_count >= server_state.max
        {should_stop, %{server_state | iterations_without_improvement: new_count}}
      end
    end)
  end
end
```

3. **ETS**: For high-performance shared state
```elixir
defmodule GEPA.StopCondition.NoImprovementETS do
  def new(max_iterations) do
    table = :ets.new(:stop_condition, [:set, :public])
    :ets.insert(table, {:best_score, :neg_infinity})
    :ets.insert(table, {:iterations_without_improvement, 0})
    :ets.insert(table, {:max_iterations, max_iterations})
    table
  end

  def should_stop?(table, state) do
    current_score = get_best_score(state)
    [{_, best_score}] = :ets.lookup(table, :best_score)
    [{_, count}] = :ets.lookup(table, :iterations_without_improvement)
    [{_, max}] = :ets.lookup(table, :max_iterations)

    if current_score > best_score do
      :ets.insert(table, {:best_score, current_score})
      :ets.insert(table, {:iterations_without_improvement, 0})
      false
    else
      new_count = count + 1
      :ets.insert(table, {:iterations_without_improvement, new_count})
      new_count >= max
    end
  end
end
```

### 6.5 Progress Bar

**Recommendation**: Use existing libraries like ProgressBar or Owl

```elixir
defmodule GEPA.Engine do
  def run(engine, state) do
    total_calls = get_max_metric_calls(engine.stop_callback)

    ProgressBar.render_spinner([
      text: "GEPA Optimization",
      done: "Optimization complete"
    ], fn ->
      run_loop(engine, state, fn progress ->
        ProgressBar.render(progress, total_calls, suffix: :count)
      end)
    end)
  end
end
```

### 6.6 Context Manager Pattern

Elixir doesn't have context managers, but similar functionality can be achieved with:

1. **Resource management blocks**:
```elixir
def with_experiment_tracker(config, fun) do
  tracker = ExperimentTracker.initialize(config)
  ExperimentTracker.start_run(tracker)

  try do
    fun.(tracker)
  after
    ExperimentTracker.end_run(tracker)
  end
end

# Usage
with_experiment_tracker(config, fn tracker ->
  ExperimentTracker.log_metrics(tracker, %{loss: 0.5})
end)
```

2. **Supervised processes**:
```elixir
defmodule GEPA.ExperimentTrackerServer do
  use GenServer

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  def init(config) do
    # Initialize backends
    state = initialize_backends(config)
    # Start run
    state = start_run(state)
    {:ok, state}
  end

  def terminate(_reason, state) do
    # Cleanup - end run
    end_run(state)
    :ok
  end
end
```

### 6.7 Error Handling

Replace try-except with try-rescue and pattern matching:

```elixir
def log_metrics(tracker, metrics, step) do
  if tracker.use_wandb do
    try do
      Wandb.log(metrics, step: step)
    rescue
      e -> Logger.warning("Failed to log to wandb: #{inspect(e)}")
    end
  end

  if tracker.use_mlflow do
    try do
      MLflow.log_metrics(metrics, step: step)
    rescue
      e -> Logger.warning("Failed to log to mlflow: #{inspect(e)}")
    end
  end
end
```

Or use result tuples:
```elixir
def log_metrics(tracker, metrics, step) do
  results = []

  results = if tracker.use_wandb do
    case Wandb.log(metrics, step: step) do
      :ok -> [:wandb | results]
      {:error, reason} ->
        Logger.warning("Failed to log to wandb: #{inspect(reason)}")
        results
    end
  else
    results
  end

  # Similar for mlflow...
  {:ok, results}
end
```

## 7. Key Metrics Logged

### 7.1 Base Program Metrics

Logged once at start of optimization:
- `base_program_full_valset_score`: Initial program score
- `base_program_val_coverage`: Number of examples evaluated
- `iteration`: Always 1 for base metrics

### 7.2 Per-Iteration Metrics

Logged after each new program discovery:
- `iteration`: Current iteration number
- `new_program_idx`: Index of new program
- `valset_pareto_front_scores`: Dict of DataId -> score for Pareto frontier
- `individual_valset_score_new_program`: Dict of DataId -> score for new program
- `valset_pareto_front_agg`: Aggregate score across Pareto frontier
- `valset_pareto_front_programs`: Dict of DataId -> list of program indices
- `best_valset_agg_score`: Best aggregate score achieved so far
- `linear_pareto_front_program_idx`: Index of best program by aggregate
- `best_program_as_per_agg_score_valset`: Duplicate of linear_pareto_front_program_idx
- `best_score_on_valset`: Best score on validation set
- `val_evaluated_count_new_program`: Number of validation examples evaluated
- `val_total_count`: Total validation set size
- `val_program_average`: Average score for new program

## 8. Extension Points

### 8.1 Custom Logger

Implement `LoggerProtocol`:
```python
class DatabaseLogger(LoggerProtocol):
    def __init__(self, db_connection):
        self.db = db_connection

    def log(self, message: str):
        self.db.execute("INSERT INTO logs (timestamp, message) VALUES (?, ?)",
                       (datetime.now(), message))
```

For Elixir:
```elixir
defmodule GEPA.Logger.Database do
  @behaviour GEPA.Logger

  def log(db_conn, message) do
    Ecto.Repo.insert!(db_conn, %Log{
      timestamp: DateTime.utc_now(),
      message: message
    })
  end
end
```

### 8.2 Custom Experiment Tracker Backend

Extend `ExperimentTracker`:
```python
class CustomExperimentTracker(ExperimentTracker):
    def __init__(self, custom_backend_config, **kwargs):
        super().__init__(**kwargs)
        self.use_custom = True
        self.custom_config = custom_backend_config

    def _initialize_custom(self):
        # Initialize custom backend
        pass

    def log_metrics(self, metrics, step=None):
        super().log_metrics(metrics, step)
        if self.use_custom:
            # Log to custom backend
            pass
```

For Elixir with Telemetry:
```elixir
defmodule GEPA.Telemetry.CustomBackend do
  def attach do
    :telemetry.attach_many(
      "custom-backend",
      [
        [:gepa, :iteration, :complete],
        [:gepa, :program, :discovered]
      ],
      &handle_event/4,
      %{backend: init_custom_backend()}
    )
  end

  def handle_event(event, measurements, metadata, config) do
    # Send to custom backend
    CustomBackend.log(config.backend, event, measurements, metadata)
  end
end
```

### 8.3 Custom Stop Condition

Implement `StopperProtocol`:
```python
class MemoryThresholdStopper(StopperProtocol):
    def __init__(self, max_memory_mb: int):
        self.max_memory_mb = max_memory_mb

    def __call__(self, gepa_state: GEPAState) -> bool:
        import psutil
        process = psutil.Process()
        memory_mb = process.memory_info().rss / 1024 / 1024
        return memory_mb > self.max_memory_mb
```

For Elixir:
```elixir
defmodule GEPA.StopCondition.Memory do
  @behaviour GEPA.StopCondition

  defstruct [:max_memory_mb]

  def new(max_memory_mb) do
    %__MODULE__{max_memory_mb: max_memory_mb}
  end

  def should_stop?(%__MODULE__{max_memory_mb: max_mb}, _state) do
    memory_mb = :erlang.memory(:total) / 1024 / 1024
    memory_mb > max_mb
  end
end
```

### 8.4 Custom Metrics

Add to `log_detailed_metrics_after_discovering_new_program` or create similar functions:
```python
def log_custom_metrics(logger, gepa_state, experiment_tracker, custom_data):
    logger.log(f"Custom metric: {custom_data}")

    metrics = {
        "iteration": gepa_state.i + 1,
        "custom_metric_1": compute_custom_1(gepa_state),
        "custom_metric_2": compute_custom_2(gepa_state, custom_data),
    }

    experiment_tracker.log_metrics(metrics, step=gepa_state.i + 1)
```

For Elixir with Telemetry:
```elixir
defmodule GEPA.Metrics.Custom do
  def log_custom_metrics(state, custom_data) do
    Logger.info("Custom metric: #{inspect(custom_data)}")

    :telemetry.execute(
      [:gepa, :custom, :metrics],
      %{
        custom_metric_1: compute_custom_1(state),
        custom_metric_2: compute_custom_2(state, custom_data)
      },
      %{iteration: state.i + 1}
    )
  end
end
```

## 9. Testing Considerations

### 9.1 Python Testing

```python
# Test logger
def test_logger_captures_stdout():
    with tempfile.NamedTemporaryFile() as f:
        with Logger(f.name) as logger:
            logger.log("test message")

        content = open(f.name).read()
        assert "test message" in content

# Test stop condition
def test_timeout_stopper():
    stopper = TimeoutStopCondition(timeout_seconds=0.1)
    state = mock_gepa_state()

    assert not stopper(state)
    time.sleep(0.2)
    assert stopper(state)

# Test experiment tracker
def test_experiment_tracker_context_manager():
    tracker = ExperimentTracker(use_wandb=False, use_mlflow=False)

    with tracker:
        assert not tracker.is_active()  # No backends configured

    # Should not raise
```

### 9.2 Elixir Testing

```elixir
defmodule GEPA.LoggerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  test "logger captures messages" do
    log = capture_log(fn ->
      Logger.info("test message")
    end)

    assert log =~ "test message"
  end
end

defmodule GEPA.StopCondition.TimeoutTest do
  use ExUnit.Case

  test "timeout stopper triggers after timeout" do
    stopper = GEPA.StopCondition.Timeout.new(100)
    state = create_mock_state()

    refute GEPA.StopCondition.Timeout.should_stop?(stopper, state)

    Process.sleep(150)

    assert GEPA.StopCondition.Timeout.should_stop?(stopper, state)
  end
end

defmodule GEPA.ExperimentTrackerTest do
  use ExUnit.Case

  test "experiment tracker with telemetry" do
    # Attach test handler
    :telemetry.attach(
      "test-handler",
      [:gepa, :iteration, :complete],
      fn event, measurements, metadata, acc ->
        send(self(), {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    # Emit event
    :telemetry.execute(
      [:gepa, :iteration, :complete],
      %{score: 0.95},
      %{iteration: 1}
    )

    # Assert received
    assert_receive {:telemetry_event, [:gepa, :iteration, :complete], %{score: 0.95}, %{iteration: 1}}

    :telemetry.detach("test-handler")
  end
end
```

## 10. Summary

The GEPA logging and utilities system provides:

1. **Flexible Experiment Tracking**: Multi-backend support (wandb, MLflow) with graceful degradation
2. **Comprehensive Logging**: File-based logging with stdout/stderr capture and flexible implementations
3. **Rich Metrics**: Detailed per-iteration and aggregate metrics for tracking optimization progress
4. **Graceful Termination**: Multiple composable stop conditions for budget control and early stopping
5. **Clean Architecture**: Protocol-based design enabling easy extension and testing
6. **Fail-Safe Operation**: Error handling that prevents logging failures from stopping optimization

For the Elixir port, leverage built-in features:
- Logger for logging with multiple backends
- Telemetry for metrics emission and collection
- Behaviors for protocols
- GenServer/Agent/ETS for stateful components
- Supervision trees for resource management
- Pattern matching and result tuples for error handling

The modular design makes it straightforward to adapt to Elixir's idioms while maintaining the same functionality and extensibility.
