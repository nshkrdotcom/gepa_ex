# GEPA Elixir Implementation - Technical Design Document

**Version:** 1.0
**Date:** 2025-08-29
**Status:** Approved for Implementation
**Authors:** GEPA Port Team

---

## Executive Summary

This document specifies the technical design for implementing GEPA (Genetic-Pareto optimizer) in Elixir. The implementation will provide functional equivalence with the Python version while leveraging Elixir's strengths in concurrency, fault tolerance, and functional programming.

**Target Metrics:**
- **Code Size:** ~2,500-3,000 LOC (core library)
- **Test Coverage:** >90%
- **Performance:** 1.5-10x speedup over Python (operation-dependent)
- **Timeline:** 10 weeks to production-ready v0.1.0

---

## Design Principles

### 1. Functional Core, Imperative Shell

```elixir
# Pure functional core
defmodule GEPA.Core.Pareto do
  @spec is_dominated?(program_idx(), [program_idx()], pareto_fronts()) :: boolean()
  def is_dominated?(program, others, fronts) do
    # Pure function - no side effects
  end
end

# Imperative shell (GenServers, supervision)
defmodule GEPA.Engine do
  use GenServer
  # Manages side effects, coordinates pure core
end
```

### 2. Explicit State Threading

All state updates return new state:
```elixir
{new_state, result} = State.update_with_program(state, program, opts)
```

Never mutate:
```elixir
# WRONG
state.i = state.i + 1

# RIGHT
state = %{state | i: state.i + 1}
```

### 3. Behaviors Over Protocols

Use compile-time behaviors for type safety:
```elixir
defmodule GEPA.Adapter do
  @callback evaluate(batch, candidate, capture_traces?) ::
    {:ok, EvaluationBatch.t()} | {:error, term()}
end
```

### 4. Tagged Tuples for Control Flow

```elixir
case propose(state) do
  {:ok, proposal} -> accept_or_reject(proposal)
  {:error, reason} -> handle_error(reason)
  :none -> continue()
end
```

### 5. Telemetry for Observability

```elixir
:telemetry.execute([:gepa, :iteration, :complete], %{score: score}, metadata)
```

### 6. Supervision for Fault Tolerance

```elixir
children = [
  {GEPA.Engine, []},
  {Task.Supervisor, name: GEPA.TaskSupervisor}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

---

## Module Architecture

### Module Dependency Graph

```
GEPA (Public API)
  └─> GEPA.Engine (GenServer)
      ├─> GEPA.State (struct + pure functions)
      │   ├─> GEPA.State.Persistence
      │   └─> GEPA.State.Pareto
      ├─> GEPA.Proposer.Reflective
      │   ├─> GEPA.Strategies.CandidateSelector
      │   ├─> GEPA.Strategies.ComponentSelector
      │   ├─> GEPA.Strategies.BatchSampler
      │   └─> GEPA.Strategies.InstructionProposal
      ├─> GEPA.Proposer.Merge (optional)
      ├─> GEPA.Adapter (behavior - user implements)
      ├─> GEPA.DataLoader (behavior)
      ├─> GEPA.Utils.Pareto (pure functions)
      └─> GEPA.StopCondition (behavior)
```

### Directory Structure

```
lib/
├── gepa.ex                          # Public API module
├── gepa/
│   ├── application.ex               # OTP application
│   ├── types.ex                     # Shared type specs
│   │
│   ├── core/
│   │   ├── state.ex                 # State struct + basic ops
│   │   ├── state/
│   │   │   ├── persistence.ex       # Save/load ETF
│   │   │   └── pareto.ex            # Pareto front updates
│   │   ├── engine.ex                # Optimization loop GenServer
│   │   ├── result.ex                # Result struct
│   │   ├── adapter.ex               # Adapter behavior
│   │   └── data_loader.ex           # DataLoader behavior + List impl
│   │
│   ├── proposer/
│   │   ├── proposer.ex              # Proposer behavior
│   │   ├── reflective.ex            # Reflective mutation
│   │   └── merge.ex                 # Merge proposer
│   │
│   ├── strategies/
│   │   ├── batch_sampler.ex         # Behavior + implementations
│   │   ├── candidate_selector.ex    # Behavior + implementations
│   │   ├── component_selector.ex    # Behavior + implementations
│   │   ├── evaluation_policy.ex     # Behavior + implementations
│   │   └── instruction_proposal.ex  # LLM-based proposal
│   │
│   ├── adapters/
│   │   └── basic.ex                 # Simple Q&A adapter
│   │
│   ├── utils/
│   │   ├── pareto.ex                # Pareto utilities
│   │   ├── helpers.ex               # General helpers
│   │   └── markdown.ex              # Markdown formatting
│   │
│   └── stop_condition/
│       ├── stop_condition.ex        # Behavior
│       ├── timeout.ex               # Timeout stopper
│       ├── max_calls.ex             # Budget stopper
│       ├── file.ex                  # File-based stopper
│       ├── threshold.ex             # Score threshold
│       ├── no_improvement.ex        # Early stopping
│       └── composite.ex             # Composite stopper

test/
├── test_helper.exs
├── support/
│   ├── test_helpers.ex              # Test utilities
│   └── generators.ex                # StreamData generators
├── gepa_test.exs                    # Public API tests
├── core/
│   ├── state_test.exs
│   ├── state/
│   │   ├── persistence_test.exs
│   │   └── pareto_test.exs
│   ├── engine_test.exs
│   └── result_test.exs
├── proposer/
│   ├── reflective_test.exs
│   └── merge_test.exs
├── strategies/
│   ├── batch_sampler_test.exs
│   ├── candidate_selector_test.exs
│   ├── component_selector_test.exs
│   └── evaluation_policy_test.exs
├── utils/
│   ├── pareto_test.exs              # With property tests
│   └── pareto_properties_test.exs
└── integration/
    └── full_optimization_test.exs   # E2E tests
```

---

## Core Data Structures

### 1. GEPA.State

**Purpose:** Tracks all optimization history, candidates, scores, and Pareto fronts.

**Design:**
```elixir
defmodule GEPA.State do
  @moduledoc """
  Persistent state tracking the complete optimization history.

  This is the heart of GEPA - all candidates, scores, Pareto fronts,
  and lineage are stored here.
  """

  @type program_idx :: non_neg_integer()
  @type data_id :: term()
  @type candidate :: %{String.t() => String.t()}
  @type sparse_scores :: %{data_id() => float()}

  @type t :: %__MODULE__{
    # All discovered program candidates
    program_candidates: [candidate()],

    # Parent relationships (genealogy) - list per program
    parent_program_for_candidate: [[program_idx() | nil]],

    # Sparse validation scores (only evaluated examples)
    prog_candidate_val_subscores: [sparse_scores()],

    # Pareto front tracking
    pareto_front_valset: %{data_id() => float()},
    program_at_pareto_front_valset: %{data_id() => MapSet.t(program_idx())},

    # Component metadata
    list_of_named_predictors: [String.t()],
    named_predictor_id_to_update_next_for_program_candidate: [non_neg_integer()],

    # Iteration tracking
    i: non_neg_integer(),
    num_full_ds_evals: non_neg_integer(),
    total_num_evals: non_neg_integer(),
    num_metric_calls_by_discovery: [non_neg_integer()],

    # Trace and metadata
    full_program_trace: [map()],
    best_outputs_valset: %{data_id() => [{program_idx(), term()}]} | nil,
    validation_schema_version: pos_integer()
  }

  @enforce_keys [
    :program_candidates,
    :parent_program_for_candidate,
    :prog_candidate_val_subscores,
    :pareto_front_valset,
    :program_at_pareto_front_valset,
    :list_of_named_predictors
  ]

  defstruct [
    :program_candidates,
    :parent_program_for_candidate,
    :prog_candidate_val_subscores,
    :pareto_front_valset,
    :program_at_pareto_front_valset,
    :list_of_named_predictors,
    named_predictor_id_to_update_next_for_program_candidate: [],
    i: 0,
    num_full_ds_evals: 0,
    total_num_evals: 0,
    num_metric_calls_by_discovery: [],
    full_program_trace: [],
    best_outputs_valset: nil,
    validation_schema_version: 2
  ]
end
```

**Key Operations:**
- `new/2` - Initialize from seed candidate
- `add_program/4` - Add new program with scores
- `update_pareto_front/4` - Update Pareto frontier
- `get_program_score/2` - Get average score for program
- `is_consistent?/1` - Validate state invariants

### 2. GEPA.EvaluationBatch

**Purpose:** Container for evaluation results.

```elixir
defmodule GEPA.EvaluationBatch do
  @moduledoc """
  Results from evaluating a candidate program on a batch of examples.
  """

  @type t :: %__MODULE__{
    outputs: [term()],
    scores: [float()],
    trajectories: [term()] | nil
  }

  @enforce_keys [:outputs, :scores]
  defstruct [:outputs, :scores, trajectories: nil]

  @doc "Validates batch invariants"
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{outputs: outputs, scores: scores, trajectories: nil}) do
    length(outputs) == length(scores)
  end

  def valid?(%__MODULE__{outputs: outputs, scores: scores, trajectories: trajs}) do
    length(outputs) == length(scores) and length(outputs) == length(trajs)
  end
end
```

### 3. GEPA.CandidateProposal

**Purpose:** Proposal for a new candidate program.

```elixir
defmodule GEPA.CandidateProposal do
  @moduledoc """
  A proposed new candidate program with metadata for acceptance testing.
  """

  @type t :: %__MODULE__{
    candidate: GEPA.Types.candidate(),
    parent_program_ids: [non_neg_integer()],
    subsample_indices: [term()] | nil,
    subsample_scores_before: [float()] | nil,
    subsample_scores_after: [float()] | nil,
    tag: String.t(),
    metadata: map()
  }

  @enforce_keys [:candidate, :parent_program_ids, :tag]
  defstruct [
    :candidate,
    :parent_program_ids,
    :tag,
    subsample_indices: nil,
    subsample_scores_before: nil,
    subsample_scores_after: nil,
    metadata: %{}
  ]

  @doc "Check if proposal should be accepted based on score improvement"
  @spec should_accept?(t()) :: boolean()
  def should_accept?(%__MODULE__{
    subsample_scores_before: before,
    subsample_scores_after: after_scores
  }) when is_list(before) and is_list(after_scores) do
    Enum.sum(after_scores) > Enum.sum(before)
  end

  def should_accept?(_), do: false
end
```

---

## Behavior Specifications

### 1. GEPA.Adapter

**Purpose:** Integration contract between GEPA and user systems.

```elixir
defmodule GEPA.Adapter do
  @moduledoc """
  Defines the contract for integrating GEPA with external systems.

  Adapters must implement evaluation, reflective dataset construction,
  and optionally custom proposal logic.
  """

  @type data_inst :: term()
  @type candidate :: %{String.t() => String.t()}
  @type eval_batch :: GEPA.EvaluationBatch.t()
  @type reflective_dataset :: %{String.t() => [map()]}

  @doc """
  Evaluate a candidate program on a batch of data.

  ## Parameters
  - `batch`: List of data instances
  - `candidate`: Program as map of component name -> text
  - `capture_traces`: Whether to capture execution trajectories

  ## Returns
  - `{:ok, eval_batch}`: Successful evaluation
  - `{:error, reason}`: Systemic failure

  ## Contract
  - Never raise on individual example failures
  - Return failure scores (e.g., 0.0) for failed examples
  - If capture_traces=true, must populate trajectories
  - len(outputs) == len(scores) == len(batch)
  """
  @callback evaluate(
    batch :: [data_inst()],
    candidate :: candidate(),
    capture_traces :: boolean()
  ) :: {:ok, eval_batch()} | {:error, term()}

  @doc """
  Build reflective dataset from execution traces.

  ## Parameters
  - `candidate`: The evaluated candidate
  - `eval_batch`: Evaluation results with trajectories
  - `components_to_update`: Which components to generate feedback for

  ## Returns
  Map from component name to list of feedback records.

  ## Recommended Record Schema
      %{
        "Inputs" => %{...},
        "Generated Outputs" => "...",
        "Feedback" => "..."
      }
  """
  @callback make_reflective_dataset(
    candidate :: candidate(),
    eval_batch :: eval_batch(),
    components_to_update :: [String.t()]
  ) :: {:ok, reflective_dataset()} | {:error, term()}

  @doc """
  Optional: Custom instruction proposal logic.

  If not implemented, GEPA uses default LLM-based proposal.
  """
  @callback propose_new_texts(
    candidate :: candidate(),
    reflective_dataset :: reflective_dataset(),
    components_to_update :: [String.t()]
  ) :: {:ok, %{String.t() => String.t()}} | {:error, term()}

  @optional_callbacks propose_new_texts: 3
end
```

### 2. GEPA.DataLoader

**Purpose:** Abstract data access.

```elixir
defmodule GEPA.DataLoader do
  @moduledoc """
  Protocol for data access with flexible ID types.
  """

  @type data_id :: term()
  @type data_inst :: term()

  @callback all_ids(t()) :: [data_id()]
  @callback fetch(t(), [data_id()]) :: [data_inst()]
  @callback size(t()) :: non_neg_integer()
end
```

### 3. GEPA.Proposer

**Purpose:** Strategy for proposing new candidates.

```elixir
defmodule GEPA.Proposer do
  @moduledoc """
  Behavior for candidate proposal strategies.
  """

  @callback propose(GEPA.State.t()) ::
    {:ok, GEPA.CandidateProposal.t()} | :none | {:error, term()}
end
```

### 4. GEPA.StopCondition

**Purpose:** Defines when to stop optimization.

```elixir
defmodule GEPA.StopCondition do
  @moduledoc """
  Behavior for stop conditions.
  """

  @callback should_stop?(t(), GEPA.State.t()) :: boolean()
end
```

---

## Core Algorithms

### 1. Pareto Domination Check

**Algorithm:** `is_dominated?(y, programs, fronts)`

```elixir
@spec is_dominated?(
  program_idx(),
  [program_idx()],
  pareto_fronts()
) :: boolean()
def is_dominated?(y, programs, program_at_pareto_front_valset) do
  # Find all fronts containing y
  fronts_with_y = for {_id, front} <- program_at_pareto_front_valset,
                      MapSet.member?(front, y),
                      do: front

  # For each front, check if another program from candidates is present
  Enum.all?(fronts_with_y, fn front ->
    Enum.any?(programs, fn other ->
      other != y and MapSet.member?(front, other)
    end)
  end)
end
```

**Tests:**
```elixir
test "is_dominated? returns true when fully dominated" do
  fronts = %{
    "val1" => MapSet.new([0, 1]),
    "val2" => MapSet.new([0, 1])
  }
  assert Pareto.is_dominated?(1, [0], fronts)
end

test "is_dominated? returns false when not dominated" do
  fronts = %{
    "val1" => MapSet.new([0, 1]),
    "val2" => MapSet.new([1])  # Only 1 here
  }
  refute Pareto.is_dominated?(1, [0], fronts)
end
```

### 2. Remove Dominated Programs

**Algorithm:** Iterative elimination

```elixir
@spec remove_dominated_programs(pareto_fronts(), %{program_idx() => float()})
  :: pareto_fronts()
def remove_dominated_programs(fronts, scores) do
  programs = get_all_programs(fronts)
  sorted = Enum.sort_by(programs, &Map.get(scores, &1, 0.0))

  dominated = do_eliminate(fronts, sorted, MapSet.new())

  # Build new fronts without dominated programs
  for {id, front} <- fronts, into: %{} do
    {id, MapSet.difference(front, dominated)}
  end
end

defp do_eliminate(fronts, programs, dominated) do
  case find_next_dominated(fronts, programs, dominated) do
    {:ok, prog} ->
      do_eliminate(fronts, programs, MapSet.put(dominated, prog))

    :none ->
      dominated
  end
end

defp find_next_dominated(fronts, programs, dominated) do
  active_programs = programs -- MapSet.to_list(dominated)

  Enum.find_value(active_programs, :none, fn prog ->
    others = active_programs -- [prog]
    if is_dominated?(prog, others, fronts) do
      {:ok, prog}
    end
  end)
end
```

### 3. Frequency-Weighted Pareto Selection

**Algorithm:** Build weighted list, random sample

```elixir
@spec select_from_pareto_front(
  pareto_fronts(),
  %{program_idx() => float()},
  :rand.state()
) :: {program_idx(), :rand.state()}
def select_from_pareto_front(fronts, scores, rand_state) do
  # Remove dominated
  cleaned_fronts = remove_dominated_programs(fronts, scores)

  # Count frequencies
  freq = Enum.reduce(cleaned_fronts, %{}, fn {_id, front}, acc ->
    Enum.reduce(front, acc, fn prog, acc2 ->
      Map.update(acc2, prog, 1, &(&1 + 1))
    end)
  end)

  # Build weighted sampling list
  sampling_list =
    for {prog, count} <- freq,
        _ <- 1..count,
        do: prog

  # Random selection
  {idx, new_rand} = :rand.uniform_s(length(sampling_list), rand_state)
  {Enum.at(sampling_list, idx - 1), new_rand}
end
```

### 4. Main Optimization Loop

**Pseudocode:**
```
WHILE not should_stop?(state):
  1. Save state to disk
  2. Increment iteration: state.i += 1

  3. ATTEMPT MERGE (if conditions met):
     - Find dominator programs
     - Find common ancestor pair
     - Merge components
     - Evaluate on subsample
     - IF improvement: Accept, skip reflection, CONTINUE

  4. REFLECTIVE MUTATION:
     - Select candidate from Pareto front
     - Sample training minibatch
     - Evaluate with trace capture
     - Build reflective dataset
     - Propose new instructions via LLM
     - Evaluate new candidate
     - IF improvement: Accept, run full validation, update state

  5. Log metrics, emit telemetry

RETURN final state
```

---

## Concurrency Model

### Task Parallelism

```elixir
# Parallel batch evaluation
defmodule GEPA.Evaluation do
  def evaluate_parallel(batch, candidate, eval_fn, opts \\ []) do
    batch
    |> Task.async_stream(
      fn example -> eval_fn.(example, candidate) end,
      max_concurrency: opts[:max_concurrency] || System.schedulers_online() * 2,
      timeout: opts[:timeout] || 60_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end)
  end
end
```

### Process Architecture

```
Application Supervisor
├─> GEPA.StateStore (Agent) - Optional centralized state
├─> Task.Supervisor - For parallel evaluation
├─> GEPA.Telemetry - Telemetry setup and handlers
└─> [Dynamic] GEPA.Engine instances (one per optimize() call)
    ├─> GEPA.Proposer.Reflective (inline, no process)
    └─> GEPA.Proposer.Merge (inline, no process)
```

**Rationale:**
- Engine is transient (one per optimization run)
- Proposers are pure functional modules (no processes needed)
- Task.Supervisor manages parallel evaluation
- State stored in memory, persisted to disk

---

## Error Handling Strategy

### Tagged Tuple Convention

```elixir
# Success
{:ok, result}

# Error
{:error, reason}

# No result (not an error)
:none

# Multiple results (pattern matching)
{:ok, result, metadata}
```

### Error Handling Patterns

**1. Adapter Errors (graceful degradation):**
```elixir
case Adapter.evaluate(adapter, batch, candidate, false) do
  {:ok, eval_batch} ->
    process(eval_batch)

  {:error, reason} ->
    Logger.warning("Adapter evaluation failed: #{inspect(reason)}")
    # Return fallback with failure scores
    fallback_evaluation_batch(batch, 0.0)
end
```

**2. Proposer Errors (continue optimization):**
```elixir
case Proposer.propose(proposer, state) do
  {:ok, proposal} ->
    maybe_accept(proposal, state)

  {:error, reason} ->
    Logger.warning("Proposal failed: #{inspect(reason)}")
    :continue  # Skip to next iteration

  :none ->
    :continue  # No proposal available
end
```

**3. Pipeline Errors (with syntax):**
```elixir
with {:ok, eval} <- Adapter.evaluate(adapter, batch, candidate, true),
     {:ok, dataset} <- Adapter.make_reflective_dataset(adapter, candidate, eval, components),
     {:ok, new_texts} <- propose_new_texts(dataset),
     {:ok, new_eval} <- Adapter.evaluate(adapter, batch, new_candidate, false) do
  {:ok, build_proposal(new_candidate, new_eval)}
else
  {:error, reason} ->
    Logger.error("Proposal pipeline failed: #{inspect(reason)}")
    :none
end
```

### Supervision Strategy

```elixir
# one_for_one: If Task.Supervisor crashes, restart it independently
Supervisor.start_link(children, strategy: :one_for_one)

# Transient: Don't restart on normal shutdown
{Task.Supervisor, name: GEPA.TaskSupervisor, restart: :transient}
```

---

## Testing Approach

### Test-Driven Development Workflow

**For Each Module:**

1. **Red:** Write failing test
```elixir
test "pareto front updates when score improves" do
  state = create_test_state()
  # This will fail - function not implemented yet
  new_state = State.update_pareto_front(state, "val1", 0.95, 1)
  assert new_state.pareto_front_valset["val1"] == 0.95
end
```

2. **Green:** Implement minimum to pass
```elixir
def update_pareto_front(state, val_id, score, program_idx) do
  # Simplest implementation that makes test pass
  put_in(state.pareto_front_valset[val_id], score)
end
```

3. **Refactor:** Improve implementation
```elixir
def update_pareto_front(state, val_id, score, program_idx) do
  state
  |> update_pareto_score(val_id, score, program_idx)
  |> update_pareto_programs(val_id, score, program_idx)
end
```

4. **Repeat:** Add more test cases

### Property-Based Testing for Core Logic

```elixir
defmodule GEPA.Utils.ParetoPropertiesTest do
  use ExUnit.Case
  use ExUnitProperties

  property "removing dominated programs preserves at least one program per front" do
    check all(fronts <- pareto_fronts_generator(), scores <- scores_generator()) do
      result = Pareto.remove_dominated_programs(fronts, scores)

      for {id, original_front} <- fronts do
        # At least one program must remain
        assert map_size(result[id]) >= 1
      end
    end
  end

  property "pareto selection always picks from a front" do
    check all(state <- state_generator()) do
      {selected, _rand} = Pareto.select_from_pareto_front(
        state.program_at_pareto_front_valset,
        scores_map(state),
        :rand.seed(:exsss, {1, 2, 3})
      )

      # Selected program must be in at least one front
      assert Enum.any?(state.program_at_pareto_front_valset, fn {_id, front} ->
        MapSet.member?(front, selected)
      end)
    end
  end
end
```

### Integration Test Pattern

```elixir
defmodule GEPA.Integration.BasicOptimizationTest do
  use ExUnit.Case

  test "complete optimization improves over seed" do
    # Arrange
    trainset = [
      %{input: "What is 2+2?", answer: "4"},
      %{input: "What is 3+3?", answer: "6"}
    ]

    valset = [
      %{input: "What is 5+5?", answer: "10"}
    ]

    seed = %{"instruction" => "Answer the question."}

    adapter = GEPA.Adapters.Mock.new(fn example, candidate ->
      # Mock scoring logic
      if String.contains?(candidate["instruction"], "math") do
        {:ok, "Correct", 1.0}
      else
        {:ok, "Wrong", 0.0}
      end
    end)

    # Act
    {:ok, result} = GEPA.optimize(
      seed_candidate: seed,
      trainset: trainset,
      valset: valset,
      adapter: adapter,
      max_metric_calls: 20
    )

    # Assert
    assert length(result.candidates) > 1
    best_score = Enum.max(result.val_aggregate_scores)
    seed_score = hd(result.val_aggregate_scores)
    assert best_score > seed_score
  end
end
```

---

## API Design

### Public API

```elixir
defmodule GEPA do
  @moduledoc """
  GEPA: Genetic-Pareto optimizer for text-based system components.

  ## Example

      trainset = [%{input: "Q1", answer: "A1"}, ...]
      valset = [%{input: "Q2", answer: "A2"}, ...]

      {:ok, result} = GEPA.optimize(
        seed_candidate: %{"instruction" => "You are helpful..."},
        trainset: trainset,
        valset: valset,
        adapter: MyAdapter,
        max_metric_calls: 100
      )

      IO.puts("Best candidate: \#{inspect(result.best_candidate)}")
      IO.puts("Best score: \#{Enum.max(result.val_aggregate_scores)}")
  """

  @type optimize_opts :: [
    seed_candidate: %{String.t() => String.t()},
    trainset: [term()] | GEPA.DataLoader.t(),
    valset: [term()] | GEPA.DataLoader.t() | nil,
    adapter: module(),

    # Optimization config
    reflection_minibatch_size: pos_integer(),
    perfect_score: float(),
    skip_perfect_score: boolean(),

    # Strategies
    candidate_selector: module() | atom(),
    component_selector: module() | atom(),
    batch_sampler: module() | atom(),
    evaluation_policy: module() | atom(),

    # Merge config
    use_merge: boolean(),
    max_merge_invocations: pos_integer(),
    merge_val_overlap_floor: pos_integer(),

    # Stop conditions
    max_metric_calls: pos_integer() | nil,
    stop_conditions: [module()] | module() | nil,

    # Storage
    run_dir: Path.t() | nil,

    # Misc
    seed: integer(),
    display_progress: boolean()
  ]

  @doc """
  Run GEPA optimization.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec optimize(optimize_opts()) :: {:ok, GEPA.Result.t()} | {:error, term()}
  def optimize(opts)
end
```

### Configuration Struct

```elixir
defmodule GEPA.Config do
  @moduledoc """
  Configuration for GEPA optimization.
  """

  @type t :: %__MODULE__{
    # Required
    seed_candidate: GEPA.Types.candidate(),
    adapter: module(),

    # Data
    trainset: GEPA.DataLoader.t(),
    valset: GEPA.DataLoader.t() | nil,

    # Optimization
    reflection_minibatch_size: pos_integer(),
    perfect_score: float(),
    skip_perfect_score: boolean(),

    # Strategies
    candidate_selector: module(),
    component_selector: module(),
    batch_sampler: module(),
    evaluation_policy: module(),

    # Merge
    use_merge: boolean(),
    max_merge_invocations: pos_integer(),
    merge_val_overlap_floor: pos_integer(),

    # Stopping
    stop_conditions: [term()],

    # Storage
    run_dir: Path.t() | nil,

    # Misc
    seed: integer(),
    display_progress: boolean()
  }

  defstruct [
    # Defaults
    reflection_minibatch_size: 5,
    perfect_score: 1.0,
    skip_perfect_score: true,
    candidate_selector: GEPA.Strategies.CandidateSelector.Pareto,
    component_selector: GEPA.Strategies.ComponentSelector.RoundRobin,
    batch_sampler: GEPA.Strategies.BatchSampler.EpochShuffled,
    evaluation_policy: GEPA.Strategies.EvaluationPolicy.Full,
    use_merge: false,
    max_merge_invocations: 5,
    merge_val_overlap_floor: 5,
    stop_conditions: [],
    run_dir: nil,
    seed: 0,
    display_progress: false,
    # Required (no defaults)
    seed_candidate: nil,
    adapter: nil,
    trainset: nil,
    valset: nil
  ]

  @doc "Validate configuration"
  @spec validate!(t()) :: :ok | no_return()
  def validate!(config) do
    unless config.seed_candidate, do: raise ArgumentError, "seed_candidate required"
    unless config.adapter, do: raise ArgumentError, "adapter required"
    unless config.trainset, do: raise ArgumentError, "trainset required"
    unless length(config.stop_conditions) > 0, do: raise ArgumentError, "at least one stop condition required"
    :ok
  end
end
```

---

## State Persistence

### ETF-Based Serialization

```elixir
defmodule GEPA.State.Persistence do
  @moduledoc """
  Handles state serialization using Erlang Term Format (ETF).
  """

  @current_version 2
  @state_filename "gepa_state.etf"

  @spec save(GEPA.State.t(), Path.t()) :: :ok | {:error, term()}
  def save(state, run_dir) do
    with :ok <- File.mkdir_p(run_dir) do
      path = Path.join(run_dir, @state_filename)

      data = %{
        version: @current_version,
        state: state,
        saved_at: DateTime.utc_now()
      }

      binary = :erlang.term_to_binary(data, [:compressed])
      File.write(path, binary)
    end
  end

  @spec load(Path.t()) :: {:ok, GEPA.State.t()} | {:error, term()}
  def load(run_dir) do
    path = Path.join(run_dir, @state_filename)

    with {:ok, binary} <- File.read(path),
         data = :erlang.binary_to_term(binary),
         {:ok, state} <- migrate(data) do
      {:ok, state}
    end
  end

  defp migrate(%{version: 2, state: state}), do: {:ok, state}
  defp migrate(%{version: 1, state: state}), do: {:ok, migrate_v1_to_v2(state)}
  defp migrate(%{version: v}), do: {:error, {:unknown_version, v}}

  defp migrate_v1_to_v2(state) do
    # Handle schema migration if needed
    state
  end
end
```

---

## Telemetry Events

### Event Specifications

```elixir
defmodule GEPA.Telemetry do
  @moduledoc """
  Telemetry event definitions for GEPA.
  """

  @doc """
  Emitted when an optimization iteration completes.

  Measurements: %{duration: native_time, score: float}
  Metadata: %{iteration: int, program_idx: int, accepted: bool}
  """
  def iteration_complete(measurements, metadata) do
    :telemetry.execute([:gepa, :iteration, :complete], measurements, metadata)
  end

  @doc """
  Emitted when a batch evaluation completes.

  Measurements: %{duration: native_time, count: int}
  Metadata: %{batch_size: int, capture_traces: bool}
  """
  def evaluation_complete(measurements, metadata) do
    :telemetry.execute([:gepa, :evaluation, :complete], measurements, metadata)
  end

  @doc """
  Emitted when a proposal is generated.

  Measurements: %{duration: native_time}
  Metadata: %{proposer: atom, accepted: bool}
  """
  def proposal_complete(measurements, metadata) do
    :telemetry.execute([:gepa, :proposal, :complete], measurements, metadata)
  end

  @doc """
  Emitted when Pareto front is updated.

  Measurements: %{programs_added: int, programs_removed: int}
  Metadata: %{val_id: term}
  """
  def pareto_updated(measurements, metadata) do
    :telemetry.execute([:gepa, :pareto, :updated], measurements, metadata)
  end
end
```

---

## Implementation Checklist

### Phase 1: Foundation

- [ ] Create Mix project: `mix new gepa --sup`
- [ ] Configure dependencies (Jason, Telemetry, StreamData)
- [ ] Set up test infrastructure
- [ ] Define GEPA.Types module
- [ ] Implement GEPA.EvaluationBatch struct + tests
- [ ] Implement GEPA.CandidateProposal struct + tests
- [ ] Implement GEPA.State struct (basic) + tests
- [ ] Implement GEPA.Utils.Helpers (idxmax, etc.) + tests

### Phase 2: Pareto Utilities

- [ ] Test: is_dominated? basic cases
- [ ] Implement: is_dominated?
- [ ] Test: is_dominated? edge cases (property tests)
- [ ] Test: remove_dominated_programs
- [ ] Implement: remove_dominated_programs
- [ ] Property test: removed programs are dominated
- [ ] Test: select_from_pareto_front
- [ ] Implement: select_from_pareto_front
- [ ] Property test: selection distribution matches frequency

### Phase 3: Behaviors

- [ ] Define GEPA.Adapter behavior
- [ ] Define GEPA.DataLoader behavior
- [ ] Implement GEPA.DataLoader.List + tests
- [ ] Define GEPA.Proposer behavior
- [ ] Define GEPA.StopCondition behavior

### Phase 4: State Management

- [ ] Test: State.new/2 creates valid state
- [ ] Implement: State.new/2
- [ ] Test: State.add_program/4 updates all fields
- [ ] Implement: State.add_program/4
- [ ] Test: State.Pareto.update_pareto_front/4
- [ ] Implement: State.Pareto.update_pareto_front/4
- [ ] Test: State.Persistence save/load roundtrip
- [ ] Implement: State.Persistence
- [ ] Property test: State invariants hold after operations

### Phase 5: Strategies

- [ ] Test: ParetoCandidateSelector.select/2
- [ ] Implement: ParetoCandidateSelector
- [ ] Test: EpochShuffledBatchSampler.next_batch/3
- [ ] Implement: EpochShuffledBatchSampler
- [ ] Test: RoundRobinComponentSelector.select/5
- [ ] Implement: RoundRobinComponentSelector
- [ ] Test: FullEvaluationPolicy methods
- [ ] Implement: FullEvaluationPolicy
- [ ] Test: InstructionProposal.format_markdown/1
- [ ] Implement: InstructionProposal

### Phase 6: Proposers

- [ ] Test: ReflectiveProposer.propose/2 with mock adapter
- [ ] Implement: ReflectiveProposer step-by-step
- [ ] Test: Each step of reflective proposal
- [ ] Test: MergeProposer.propose/2
- [ ] Implement: MergeProposer
- [ ] Test: Merge component logic

### Phase 7: Engine

- [ ] Test: Engine initialization
- [ ] Implement: Engine.init/1
- [ ] Test: Engine single iteration
- [ ] Implement: Engine.run_iteration/1
- [ ] Test: Engine stop conditions
- [ ] Implement: Engine.should_stop?/1
- [ ] Test: Engine state persistence
- [ ] Integration test: Full optimization run

### Phase 8: Public API & Adapters

- [ ] Test: GEPA.optimize/1 with mock adapter
- [ ] Implement: GEPA.optimize/1
- [ ] Test: BasicAdapter.evaluate/3
- [ ] Implement: BasicAdapter
- [ ] Test: BasicAdapter.make_reflective_dataset/3
- [ ] Integration test: Real optimization on toy problem

---

## Risk Analysis

### Technical Risks

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Pareto logic bugs | Medium | High | Property-based tests, cross-validation with Python |
| Performance below target | Low | Medium | Benchmark early, profile, optimize hot paths |
| LLM integration issues | Medium | Medium | Start with simple HTTP client, add retries |
| State corruption | Low | High | Comprehensive persistence tests, versioning |
| Memory leaks | Low | Medium | Profile with :observer, use ETS for large state |

### Project Risks

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Timeline slippage | Medium | Medium | Buffer in estimates, weekly reviews, MVP focus |
| Scope creep | High | High | Strict phase boundaries, defer advanced features |
| Dependency issues | Low | Low | Minimal deps, version locking |
| Testing gaps | Medium | High | TDD from start, coverage tracking |

---

## Success Metrics

### Code Quality

- **Test Coverage:** >90%
- **Dialyzer:** Zero warnings
- **Credo:** Zero issues
- **Documentation:** All public functions documented

### Performance

- **Parallel Evaluation:** 5-10x speedup vs Python
- **State Updates:** <5ms per update
- **Persistence:** <100ms save/load
- **Full Iteration:** <15s (LLM-bound)

### Functional

- **All Core Features:** Reflective mutation, merge, Pareto selection
- **Adapters:** At least Basic adapter working
- **Stop Conditions:** All 7 types implemented
- **Compatibility:** Produces equivalent results to Python

---

## Conclusion

This technical design provides:
1. ✅ Clear module architecture
2. ✅ Detailed behavior specifications
3. ✅ Comprehensive testing strategy
4. ✅ Performance targets
5. ✅ Risk mitigation plans
6. ✅ Success criteria

**Ready to proceed with TDD implementation.**

---

**Appendix: Related Documents**
- `docs/20250829/00_complete_integration_guide.md` - Full integration guide
- `docs/20250829/01_core_architecture.md` - Python core architecture analysis
- `docs/20250829/02_proposer_system.md` - Proposer system analysis
- `docs/20250829/03_strategies.md` - Strategies analysis
- `docs/20250829/04_adapters.md` - Adapters analysis
- `docs/20250829/05_rag_adapter.md` - RAG adapter analysis
- `docs/20250829/06_logging_utilities.md` - Logging and utilities analysis
