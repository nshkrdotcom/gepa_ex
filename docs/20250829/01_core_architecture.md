# GEPA Core Engine & Architecture Documentation

**Purpose**: This document provides a comprehensive analysis of the GEPA Python library's core architecture for the purpose of porting it to Elixir.

**Date**: 2025-08-29
**Version**: Based on GEPA Python library analysis
**Focus**: Core engine, state management, adapter protocol, and data flow

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Core Components](#core-components)
3. [Module Breakdown](#module-breakdown)
4. [Data Structures](#data-structures)
5. [Key Algorithms](#key-algorithms)
6. [Data Flow](#data-flow)
7. [Elixir Port Considerations](#elixir-port-considerations)

---

## Architecture Overview

### High-Level System Design

GEPA (Generalized Evolutionary Program Augmentation) is an evolutionary optimizer that iteratively improves text-based system components (e.g., prompts, code snippets) by:

1. **Evaluation**: Testing candidate programs on datasets
2. **Reflection**: Analyzing execution traces to identify improvements
3. **Mutation**: Proposing new candidates via reflective mutation or merging
4. **Selection**: Maintaining a Pareto frontier of best-performing candidates

### Core Subsystems

```
┌─────────────────────────────────────────────────────────────┐
│                        GEPAEngine                            │
│  (Orchestrates optimization loop)                            │
└──────────────┬──────────────────────────────────────────────┘
               │
               ├─► GEPAState (Persistent optimizer state)
               │
               ├─► GEPAAdapter (User-defined evaluation protocol)
               │
               ├─► DataLoader (Data access abstraction)
               │
               ├─► Proposers:
               │   ├─► ReflectiveMutationProposer
               │   └─► MergeProposer
               │
               ├─► Strategies:
               │   ├─► CandidateSelector
               │   ├─► ComponentSelector
               │   ├─► BatchSampler
               │   └─► EvaluationPolicy
               │
               └─► GEPAResult (Immutable result snapshot)
```

---

## Core Components

### 1. GEPAEngine (`engine.py`)

**Responsibility**: Orchestrates the main optimization loop.

**Key Characteristics**:
- Generic over: `DataId`, `DataInst`, `Trajectory`, `RolloutOutput`
- Manages proposer coordination (reflective mutation + merge)
- Handles graceful stopping
- Provides progress tracking via tqdm
- Exception handling with configurable behavior

**State Management**:
- Maintains iteration counter
- Tracks evaluation budgets
- Persists state to disk periodically
- Supports resumption from saved state

### 2. GEPAState (`state.py`)

**Responsibility**: Persistent optimizer state tracking candidates, validation coverage, and metadata.

**Key Characteristics**:
- Immutable snapshot-based design (save/load via pickle)
- Schema versioning for backward compatibility
- Sparse validation score tracking (per-candidate, per-example)
- Pareto frontier maintenance per validation example
- Program lineage tracking (parent relationships)

### 3. GEPAAdapter (`adapter.py`)

**Responsibility**: Protocol defining the integration contract between GEPA and user systems.

**Key Characteristics**:
- Protocol-based (structural typing)
- Generic over: `DataInst`, `Trajectory`, `RolloutOutput`
- Three main responsibilities:
  1. `evaluate()`: Execute program on batch and return scores/trajectories
  2. `make_reflective_dataset()`: Extract feedback from trajectories
  3. `propose_new_texts()`: Optional custom proposal logic

### 4. DataLoader (`data_loader.py`)

**Responsibility**: Abstract data access layer for training/validation sets.

**Key Characteristics**:
- Protocol-based with minimal interface
- Supports opaque `DataId` for flexible indexing
- Reference implementation: `ListDataLoader` (in-memory)
- Extensible for lazy loading, databases, etc.

### 5. GEPAResult (`result.py`)

**Responsibility**: Immutable snapshot of optimization results with convenience accessors.

**Key Characteristics**:
- Frozen dataclass
- Schema versioning
- Convenience methods for analysis (Pareto front, lineage, etc.)
- JSON serialization support

### 6. Public API (`api.py`)

**Responsibility**: Main entry point providing `optimize()` function.

**Key Characteristics**:
- High-level interface with sensible defaults
- Configuration for proposers, selectors, stopping conditions
- Logging integration (wandb, mlflow)
- Automatic stopper composition

---

## Module Breakdown

### `engine.py` - GEPAEngine

**Class: GEPAEngine**

**Constructor Parameters**:
```python
run_dir: str | None                    # Where to persist state
evaluator: Callable[...]               # Function to score candidates
valset: DataLoader | list              # Validation data
seed_candidate: dict[str, str]         # Initial program components
perfect_score: float                   # Target score
seed: int                              # RNG seed
reflective_proposer: ReflectiveMutationProposer
merge_proposer: MergeProposer | None
logger: Any
experiment_tracker: Any
track_best_outputs: bool = False
display_progress_bar: bool = False
raise_on_exception: bool = True
use_cloudpickle: bool = False
stop_callback: Callable | None = None
val_evaluation_policy: EvaluationPolicy | None = None
```

**Key Methods**:

1. **`run() -> GEPAState`**
   - Main optimization loop
   - Initializes/loads state
   - Iterates until stopping condition
   - Returns final state

2. **`_evaluate_on_valset(program, state) -> tuple[dict, dict]`**
   - Evaluates program on validation set
   - Returns outputs and scores by validation ID
   - Respects evaluation policy for selective scoring

3. **`_run_full_eval_and_add(new_program, state, parent_idx) -> tuple[int, int]`**
   - Runs full validation evaluation
   - Updates state with new candidate
   - Logs metrics
   - Returns new program index and best program index

4. **`_should_stop(state) -> bool`**
   - Checks stopping conditions
   - Manual stop flag
   - Callback-based stopping

5. **`request_stop()`**
   - Graceful shutdown mechanism

**Optimization Loop Structure**:

```python
while not _should_stop(state):
    state.i += 1

    # 1. Attempt merge (if scheduled and last iter found new program)
    if merge_proposer and conditions_met:
        proposal = merge_proposer.propose(state)
        if accepted:
            _run_full_eval_and_add(...)
            continue  # Skip reflective this iteration

    # 2. Reflective mutation
    proposal = reflective_proposer.propose(state)
    if proposal and improvement:
        _run_full_eval_and_add(...)
        schedule_merge_attempts()
```

**Error Handling**:
- Catches exceptions per iteration
- Logs traceback
- Either raises or continues based on `raise_on_exception`

---

### `state.py` - GEPAState

**Class: GEPAState**

**Data Structures**:

```python
program_candidates: list[dict[str, str]]
    # List of all proposed candidates
    # Each candidate: component_name -> component_text

parent_program_for_candidate: list[list[ProgramIdx | None]]
    # Parent lineage for each candidate
    # Index 0 (seed) has [None]

prog_candidate_val_subscores: list[dict[DataId, float]]
    # Sparse validation scores
    # prog_idx -> {val_id -> score}

pareto_front_valset: dict[DataId, float]
    # Best score achieved per validation example
    # val_id -> best_score

program_at_pareto_front_valset: dict[DataId, set[ProgramIdx]]
    # Which programs achieve best score per validation example
    # val_id -> {prog_idx1, prog_idx2, ...}

list_of_named_predictors: list[str]
    # Component names from seed candidate

named_predictor_id_to_update_next_for_program_candidate: list[int]
    # Tracks which component to update next per candidate

i: int                          # Current iteration
num_full_ds_evals: int         # Full validation evaluations
total_num_evals: int           # Total individual evaluations
num_metric_calls_by_discovery: list[int]  # Budget at discovery time
full_program_trace: list       # Detailed execution trace
best_outputs_valset: dict | None  # Optional best outputs tracking
validation_schema_version: int # For migration
```

**Key Methods**:

1. **`__init__(seed_candidate, base_valset_eval_output, track_best_outputs)`**
   - Initializes with seed candidate
   - Sets up initial Pareto frontier
   - Optionally tracks best outputs

2. **`is_consistent() -> bool`**
   - Validates internal invariants
   - Checks length consistency
   - Validates Pareto frontier integrity

3. **`save(run_dir, use_cloudpickle=False)`**
   - Serializes state to disk
   - Uses pickle or cloudpickle
   - Includes schema version

4. **`load(run_dir) -> GEPAState`** (static)
   - Deserializes from disk
   - Handles schema migration
   - Validates loaded state

5. **`update_state_with_new_program(...) -> ProgramIdx`**
   - Adds new candidate
   - Updates Pareto frontiers
   - Saves best outputs if tracked
   - Returns new program index

6. **`_update_pareto_front_for_val_id(...)`**
   - Updates per-example Pareto frontier
   - Handles ties (multiple programs at same score)
   - Saves outputs to disk if tracking

7. **`get_program_average_val_subset(program_idx) -> tuple[float, int]`**
   - Computes average score over evaluated examples
   - Returns (average, count)

**Properties**:

- `valset_evaluations`: Which programs evaluated which validation examples
- `program_full_scores_val_set`: Average scores for all programs

**Schema Migration**:

- `_VALIDATION_SCHEMA_VERSION = 2`
- `_migrate_from_legacy_state_v0()`: Converts from list-based to dict-based sparse scores

---

### `adapter.py` - GEPAAdapter Protocol

**Type Aliases**:

```python
RolloutOutput = TypeVar("RolloutOutput")  # User-defined output type
Trajectory = TypeVar("Trajectory")        # User-defined trace type
DataInst = TypeVar("DataInst")            # User-defined input type
```

**Class: EvaluationBatch**

```python
@dataclass
class EvaluationBatch(Generic[Trajectory, RolloutOutput]):
    outputs: list[RolloutOutput]        # Raw outputs (opaque to GEPA)
    scores: list[float]                 # Per-example scores (higher = better)
    trajectories: list[Trajectory] | None  # Optional execution traces
```

**Protocol: ProposalFn**

```python
def __call__(
    candidate: dict[str, str],
    reflective_dataset: dict[str, list[dict[str, Any]]],
    components_to_update: list[str],
) -> dict[str, str]:
    """Custom proposal logic"""
```

**Protocol: GEPAAdapter**

**Method: `evaluate()`**

```python
def evaluate(
    batch: list[DataInst],
    candidate: dict[str, str],
    capture_traces: bool = False,
) -> EvaluationBatch[Trajectory, RolloutOutput]
```

**Contract**:
- Execute program on batch
- Return scores (higher = better)
- If `capture_traces=True`, populate trajectories
- Never raise on individual failures (return fallback score like 0.0)
- Lengths must match: `len(outputs) == len(scores) == len(batch)`

**Scoring Semantics**:
- Minibatch acceptance: uses `sum(scores)`
- Validation tracking: uses `mean(scores)`

**Method: `make_reflective_dataset()`**

```python
def make_reflective_dataset(
    candidate: dict[str, str],
    eval_batch: EvaluationBatch[Trajectory, RolloutOutput],
    components_to_update: list[str],
) -> dict[str, list[dict[str, Any]]]
```

**Contract**:
- Extract feedback from trajectories
- Return JSON-serializable dataset per component
- Recommended schema:
  ```python
  {
      "Inputs": dict,           # Component inputs
      "Generated Outputs": dict | str,  # Model outputs
      "Feedback": str           # Error messages, correct answers, etc.
  }
  ```

**Method: `propose_new_texts()` (optional)**

```python
propose_new_texts: ProposalFn | None = None
```

- If provided, overrides default instruction proposal
- Allows custom LLM integration, DSPy signatures, etc.

---

### `data_loader.py` - DataLoader Protocol

**Type Aliases**:

```python
DataId = TypeVar("DataId", bound=Hashable)  # Generic ID type
```

**Protocol: DataLoader**

```python
class DataLoader(Protocol[DataId, DataInst]):
    def all_ids(self) -> Sequence[DataId]:
        """Return ordered universe of available IDs"""

    def fetch(self, ids: Sequence[DataId]) -> list[DataInst]:
        """Materialize data for given IDs, preserving order"""

    def __len__(self) -> int:
        """Return total number of items"""
```

**Protocol: MutableDataLoader**

```python
class MutableDataLoader(DataLoader[DataId, DataInst], Protocol):
    def add_items(self, items: list[DataInst]) -> None:
        """Add items dynamically"""
```

**Class: ListDataLoader**

Reference implementation backed by in-memory list.

```python
class ListDataLoader(MutableDataLoader[int, DataInst]):
    def __init__(self, items: Sequence[DataInst]):
        self.items = list(items)

    def all_ids(self) -> Sequence[int]:
        return list(range(len(self.items)))

    def fetch(self, ids: Sequence[int]) -> list[DataInst]:
        return [self.items[data_id] for data_id in ids]

    def __len__(self) -> int:
        return len(self.items)

    def add_items(self, items: Sequence[DataInst]) -> None:
        self.items.extend(items)
```

**Function: `ensure_loader()`**

```python
def ensure_loader(
    data_or_loader: Sequence[DataInst] | DataLoader[DataId, DataInst]
) -> DataLoader[DataId, DataInst]:
    """Convert list to ListDataLoader or pass through existing loader"""
```

---

### `result.py` - GEPAResult

**Class: GEPAResult**

Frozen dataclass providing immutable result snapshot.

**Core Fields**:

```python
candidates: list[dict[str, str]]              # All proposed candidates
parents: list[list[ProgramIdx | None]]        # Lineage
val_aggregate_scores: list[float]             # Mean scores on valset
val_subscores: list[dict[DataId, float]]      # Sparse scores
per_val_instance_best_candidates: dict[DataId, set[ProgramIdx]]
discovery_eval_counts: list[int]              # Budget at discovery
```

**Optional Fields**:

```python
best_outputs_valset: dict[DataId, list[tuple[ProgramIdx, RolloutOutput]]] | None
total_metric_calls: int | None
num_full_val_evals: int | None
run_dir: str | None
seed: int | None
```

**Properties**:

```python
@property
def num_candidates(self) -> int:
    return len(self.candidates)

@property
def num_val_instances(self) -> int:
    return len(self.per_val_instance_best_candidates)

@property
def best_idx(self) -> int:
    """Index of candidate with highest aggregate score"""
    return max(range(len(scores)), key=lambda i: scores[i])

@property
def best_candidate(self) -> dict[str, str]:
    """Best-performing candidate"""
    return self.candidates[self.best_idx]
```

**Methods**:

1. **`to_dict() -> dict`**
   - Serializes to dictionary
   - Converts sets to lists for JSON compatibility

2. **`from_dict(d: dict) -> GEPAResult`** (static)
   - Deserializes from dictionary
   - Handles schema migration

3. **`from_state(state, run_dir, seed) -> GEPAResult`** (static)
   - Creates result from GEPAState

**Schema Versioning**:

```python
_VALIDATION_SCHEMA_VERSION: ClassVar[int] = 2
```

- Version 0/1: List-based sparse scores
- Version 2: Dict-based sparse scores (current)

---

### `api.py` - Public API

**Function: `optimize()`**

Main entry point for GEPA optimization.

**Core Parameters**:

```python
seed_candidate: dict[str, str]           # Initial program
trainset: list[DataInst] | DataLoader    # Training data
valset: list[DataInst] | DataLoader | None  # Validation data
adapter: GEPAAdapter | None              # User-defined adapter
task_lm: str | Callable | None           # For default adapter
```

**Reflection Configuration**:

```python
reflection_lm: LanguageModel | str | None
candidate_selection_strategy: CandidateSelector | Literal["pareto", "current_best", "epsilon_greedy"]
skip_perfect_score: bool = True
batch_sampler: BatchSampler | Literal["epoch_shuffled"]
reflection_minibatch_size: int | None
perfect_score: float = 1
reflection_prompt_template: str | None
```

**Component Selection**:

```python
module_selector: ReflectionComponentSelector | str = "round_robin"
    # "round_robin": Cycle through components
    # "all": Update all components each iteration
```

**Merge Configuration**:

```python
use_merge: bool = False
max_merge_invocations: int = 5
merge_val_overlap_floor: int = 5  # Min shared validation examples
```

**Budget and Stopping**:

```python
max_metric_calls: int | None
stop_callbacks: StopperProtocol | list[StopperProtocol] | None
```

**Logging**:

```python
logger: LoggerProtocol | None
run_dir: str | None
use_wandb: bool = False
wandb_api_key: str | None
wandb_init_kwargs: dict | None
use_mlflow: bool = False
mlflow_tracking_uri: str | None
mlflow_experiment_name: str | None
track_best_outputs: bool = False
display_progress_bar: bool = False
use_cloudpickle: bool = False
```

**Reproducibility**:

```python
seed: int = 0
raise_on_exception: bool = True
val_evaluation_policy: EvaluationPolicy | Literal["full_eval"] | None
```

**Return Type**: `GEPAResult`

**Key Logic**:

1. **Adapter Setup**:
   - If no adapter provided, create `DefaultAdapter` with `task_lm`
   - Validate mutual exclusivity of `adapter` and `task_lm`

2. **Data Loader Conversion**:
   - Convert lists to `ListDataLoader` via `ensure_loader()`

3. **Stopper Composition**:
   - Combine `stop_callbacks`, `max_metric_calls`, `FileStopper` (if `run_dir`)
   - Require at least one stopping condition

4. **Strategy Resolution**:
   - Convert string strategy names to instances
   - Initialize with appropriate RNGs for reproducibility

5. **Engine Construction**:
   - Build `ReflectiveMutationProposer` and optional `MergeProposer`
   - Create `GEPAEngine` with all components

6. **Execution**:
   ```python
   with experiment_tracker:
       state = engine.run()
   result = GEPAResult.from_state(state)
   return result
   ```

---

### `gepa_utils.py` - Utility Functions

**Function: `json_default(x)`**

```python
def json_default(x):
    """Default JSON encoder for non-serializable objects"""
    try:
        return {**x}  # Try dict unpacking
    except Exception:
        return repr(x)  # Fallback to repr
```

**Function: `idxmax(lst: list[float]) -> int`**

```python
def idxmax(lst: list[float]) -> int:
    """Return index of maximum value"""
    max_val = max(lst)
    return lst.index(max_val)
```

**Function: `is_dominated(y, programs, program_at_pareto_front_valset)`**

Checks if program `y` is dominated by others in `programs`.

**Logic**:
- Get all Pareto fronts containing `y`
- For each front, check if any other program in `programs` is also present
- If all fronts have another program, `y` is dominated

**Function: `remove_dominated_programs(program_at_pareto_front_valset, scores=None)`**

Removes dominated programs from Pareto frontiers.

**Algorithm**:
1. Count frequency of programs across frontiers
2. Sort programs by score (ascending)
3. Iteratively remove dominated programs
4. Return cleaned Pareto frontiers

**Function: `find_dominator_programs(pareto_front_programs, scores)`**

```python
def find_dominator_programs(
    pareto_front_programs,
    train_val_weighted_agg_scores_for_all_programs
) -> list[int]:
    """Return list of non-dominated program indices"""
```

**Function: `select_program_candidate_from_pareto_front(pareto_front_programs, scores, rng)`**

Selects a program from Pareto frontier using frequency-based sampling.

**Algorithm**:
1. Remove dominated programs
2. Count program frequency in validation Pareto fronts
3. Create sampling list (programs repeated by frequency)
4. Randomly select from sampling list

**Purpose**: Programs on more Pareto fronts have higher probability of selection.

---

## Data Structures

### 1. Candidate Programs

**Type**: `dict[str, str]`

**Structure**:
- Key: Component name (e.g., "prompt", "code_snippet")
- Value: Component text

**Example**:
```python
{
    "instruction": "You are a helpful AI assistant...",
    "code": "def solve(x): return x + 1"
}
```

### 2. Sparse Validation Scores

**Type**: `list[dict[DataId, float]]`

**Structure**:
- Outer list: Indexed by program index
- Inner dict: Maps validation ID to score (only evaluated examples)

**Example**:
```python
[
    {0: 0.8, 1: 0.9, 2: 0.7},  # Program 0 evaluated on examples 0, 1, 2
    {0: 0.85, 1: 0.95},         # Program 1 evaluated on examples 0, 1
]
```

**Rationale**: Supports selective evaluation policies (not all programs evaluated on all examples).

### 3. Pareto Frontier

**Per-Example Best Score**:
```python
pareto_front_valset: dict[DataId, float]
```

Maps each validation example to the best score achieved by any program.

**Programs at Frontier**:
```python
program_at_pareto_front_valset: dict[DataId, set[ProgramIdx]]
```

Maps each validation example to set of programs achieving best score (handles ties).

**Example**:
```python
pareto_front_valset = {0: 0.9, 1: 0.95, 2: 0.8}
program_at_pareto_front_valset = {
    0: {0, 1},    # Programs 0 and 1 both achieve 0.9 on example 0
    1: {1},       # Program 1 achieves 0.95 on example 1
    2: {0, 2},    # Programs 0 and 2 both achieve 0.8 on example 2
}
```

### 4. Program Lineage

**Type**: `list[list[ProgramIdx | None]]`

**Structure**:
- Outer list: Indexed by program index
- Inner list: Parent program indices (can be multiple for merges)

**Example**:
```python
[
    [None],        # Program 0 (seed) has no parents
    [0],           # Program 1 evolved from program 0
    [0],           # Program 2 evolved from program 0
    [1, 2],        # Program 3 is merge of programs 1 and 2
]
```

### 5. Evaluation Batch

**Type**: `EvaluationBatch[Trajectory, RolloutOutput]`

**Fields**:
```python
outputs: list[RolloutOutput]        # Opaque to GEPA
scores: list[float]                 # Higher = better
trajectories: list[Trajectory] | None  # Optional traces
```

**Invariant**: `len(outputs) == len(scores) == len(batch)`

### 6. Reflective Dataset

**Type**: `dict[str, list[dict[str, Any]]]`

**Structure**:
- Outer dict: Component name -> examples
- Inner list: Examples for that component
- Example dict: JSON-serializable feedback

**Recommended Schema**:
```python
{
    "component_name": [
        {
            "Inputs": {"query": "What is 2+2?"},
            "Generated Outputs": "The answer is 5.",
            "Feedback": "Incorrect. The correct answer is 4."
        },
        # More examples...
    ]
}
```

### 7. Program Trace

**Type**: `list[dict[str, Any]]`

Detailed execution trace with metadata for each iteration.

**Example Entry**:
```python
{
    "i": 5,                           # Iteration number
    "new_program_idx": 5,             # New candidate index
    "evaluated_val_indices": [0, 1, 2, 5, 8],  # Which validation examples
    # Additional metadata...
}
```

---

## Key Algorithms

### 1. Main Optimization Loop

**Location**: `GEPAEngine.run()`

**Pseudocode**:

```python
def run():
    # Initialize or load state
    state = initialize_or_load_state()

    # Main loop
    while not should_stop(state):
        state.i += 1

        # Phase 1: Attempt merge (if conditions met)
        if merge_proposer and merge_scheduled and last_iter_found_new_program:
            merge_proposal = merge_proposer.propose(state)

            if merge_proposal and accepted(merge_proposal):
                run_full_eval_and_add(merge_proposal)
                merge_proposer.merges_due -= 1
                continue  # Skip reflective mutation this iteration

        # Phase 2: Reflective mutation
        reflective_proposal = reflective_proposer.propose(state)

        if reflective_proposal is None:
            continue  # No proposal generated

        # Acceptance test: require improvement on subsample
        old_sum = sum(reflective_proposal.subsample_scores_before)
        new_sum = sum(reflective_proposal.subsample_scores_after)

        if new_sum <= old_sum:
            continue  # Reject proposal

        # Accept: run full evaluation and add to pool
        new_prog_idx, best_prog_idx = run_full_eval_and_add(
            reflective_proposal.candidate,
            state,
            reflective_proposal.parent_program_ids
        )

        # Schedule future merge attempts
        if merge_proposer:
            merge_proposer.last_iter_found_new_program = True
            if merge_proposer.total_merges_tested < max_merge_invocations:
                merge_proposer.merges_due += 1

    return state
```

**Key Decisions**:

1. **Merge takes precedence**: If scheduled, merge happens before reflective mutation
2. **Continue on merge acceptance**: Skip reflective mutation when merge succeeds
3. **Continue on merge rejection**: Also skip reflective mutation (old behavior)
4. **Subsample acceptance**: Only test on small batch, not full valset
5. **Full evaluation on acceptance**: Run complete validation after acceptance
6. **Merge scheduling**: Increment `merges_due` after successful reflective mutation

### 2. Full Evaluation and State Update

**Location**: `GEPAEngine._run_full_eval_and_add()`

**Pseudocode**:

```python
def _run_full_eval_and_add(new_program, state, parent_program_idx):
    # Record current budget for discovery tracking
    num_metric_calls_by_discovery = state.total_num_evals

    # Evaluate on validation set
    valset_outputs, valset_subscores = _evaluate_on_valset(new_program, state)

    # Update counters
    state.num_full_ds_evals += 1
    state.total_num_evals += len(valset_subscores)

    # Add to state (updates Pareto frontiers)
    new_program_idx = state.update_state_with_new_program(
        parent_program_idx=parent_program_idx,
        new_program=new_program,
        valset_outputs=valset_outputs,
        valset_subscores=valset_subscores,
        run_dir=run_dir,
        num_metric_calls_by_discovery_of_new_program=num_metric_calls_by_discovery,
    )

    # Update trace
    state.full_program_trace[-1]["new_program_idx"] = new_program_idx
    state.full_program_trace[-1]["evaluated_val_indices"] = sorted(valset_subscores.keys())

    # Compute aggregate score
    valset_score = val_evaluation_policy.get_valset_score(new_program_idx, state)

    # Check if new best
    linear_pareto_front_program_idx = val_evaluation_policy.get_best_program(state)
    if new_program_idx == linear_pareto_front_program_idx:
        logger.log(f"Found better program with score {valset_score}")

    # Log detailed metrics
    log_detailed_metrics_after_discovering_new_program(...)

    return new_program_idx, linear_pareto_front_program_idx
```

### 3. Pareto Frontier Update

**Location**: `GEPAState._update_pareto_front_for_val_id()`

**Pseudocode**:

```python
def _update_pareto_front_for_val_id(val_id, score, program_idx, output, run_dir, iteration):
    prev_score = pareto_front_valset.get(val_id, -inf)

    if score > prev_score:
        # Strictly better: replace frontier
        pareto_front_valset[val_id] = score
        program_at_pareto_front_valset[val_id] = {program_idx}

        if track_best_outputs and output is not None:
            best_outputs_valset[val_id] = [(program_idx, output)]
            save_output_to_disk(val_id, program_idx, output, run_dir, iteration)

    elif score == prev_score:
        # Tie: add to frontier
        program_at_pareto_front_valset[val_id].add(program_idx)

        if track_best_outputs and output is not None:
            best_outputs_valset[val_id].append((program_idx, output))
```

**Properties**:
- Maintains strict Pareto frontier per validation example
- Handles ties (multiple programs at same score)
- Optionally persists best outputs to disk

### 4. Dominated Program Removal

**Location**: `gepa_utils.remove_dominated_programs()`

**Algorithm**:

```python
def remove_dominated_programs(program_at_pareto_front_valset, scores):
    # 1. Count frequency of each program in Pareto fronts
    freq = {}
    for front in program_at_pareto_front_valset.values():
        for p in front:
            freq[p] = freq.get(p, 0) + 1

    # 2. Sort programs by score (ascending, so lower-scoring checked first)
    programs = sorted(freq.keys(), key=lambda x: scores[x])

    # 3. Iteratively find and mark dominated programs
    dominated = set()
    found_to_remove = True

    while found_to_remove:
        found_to_remove = False
        for y in programs:
            if y in dominated:
                continue

            # Check if y is dominated by remaining programs
            other_programs = set(programs) - {y} - dominated
            if is_dominated(y, other_programs, program_at_pareto_front_valset):
                dominated.add(y)
                found_to_remove = True
                break

    # 4. Build cleaned Pareto frontiers
    dominators = [p for p in programs if p not in dominated]
    new_program_at_pareto_front_valset = {
        val_id: {prog_idx for prog_idx in front if prog_idx in dominators}
        for val_id, front in program_at_pareto_front_valset.items()
    }

    return new_program_at_pareto_front_valset
```

**Purpose**: Remove programs that are strictly dominated across all validation examples.

**Definition of Dominated**: Program Y is dominated if for every validation example where Y is on the Pareto front, at least one other program is also on that front.

### 5. Candidate Selection from Pareto Front

**Location**: `gepa_utils.select_program_candidate_from_pareto_front()`

**Algorithm**:

```python
def select_program_candidate_from_pareto_front(pareto_front_programs, scores, rng):
    # 1. Remove dominated programs
    cleaned_fronts = remove_dominated_programs(pareto_front_programs, scores)

    # 2. Count frequency of each program in cleaned fronts
    program_frequency = {}
    for testcase_pareto_front in cleaned_fronts.values():
        for prog_idx in testcase_pareto_front:
            program_frequency[prog_idx] = program_frequency.get(prog_idx, 0) + 1

    # 3. Build sampling list (programs repeated by frequency)
    sampling_list = [
        prog_idx
        for prog_idx, freq in program_frequency.items()
        for _ in range(freq)
    ]

    # 4. Random selection weighted by frequency
    curr_prog_id = rng.choice(sampling_list)
    return curr_prog_id
```

**Properties**:
- Programs on more Pareto fronts have higher selection probability
- Ensures diversity (can select specialist programs)
- Weighted by validation coverage

---

## Data Flow

### High-Level Flow

```
User Code
    │
    ├─► Define Adapter (evaluate, make_reflective_dataset)
    │
    └─► Call optimize(seed_candidate, trainset, valset, adapter, ...)
            │
            ├─► Create DataLoaders (trainset, valset)
            │
            ├─► Initialize Proposers:
            │   ├─► ReflectiveMutationProposer
            │   └─► MergeProposer (optional)
            │
            ├─► Create GEPAEngine
            │
            └─► engine.run()
                    │
                    ├─► Initialize/Load GEPAState
                    │
                    ├─► Evaluate seed_candidate on full valset
                    │       │
                    │       └─► adapter.evaluate(valset, seed_candidate, capture_traces=False)
                    │
                    └─► Optimization Loop
                            │
                            ├─► [Optional] MergeProposer.propose(state)
                            │       │
                            │       ├─► Select 2 Pareto programs
                            │       ├─► Sample shared validation IDs
                            │       ├─► Evaluate both on subsample
                            │       ├─► Merge components
                            │       └─► Evaluate merged candidate on subsample
                            │
                            ├─► ReflectiveMutationProposer.propose(state)
                            │       │
                            │       ├─► candidate_selector.select_candidate(state)
                            │       │       └─► (Pareto selection / current best / ε-greedy)
                            │       │
                            │       ├─► module_selector.select_components_to_update(state, candidate_idx)
                            │       │       └─► (Round-robin / all)
                            │       │
                            │       ├─► batch_sampler.sample_batch(trainset)
                            │       │
                            │       ├─► adapter.evaluate(batch, candidate, capture_traces=True)
                            │       │       └─► Returns EvaluationBatch with trajectories
                            │       │
                            │       ├─► adapter.make_reflective_dataset(candidate, eval_batch, components)
                            │       │       └─► Extracts feedback from trajectories
                            │       │
                            │       ├─► adapter.propose_new_texts(...) OR default_proposal(...)
                            │       │       └─► reflection_lm(reflective_dataset) -> new_texts
                            │       │
                            │       ├─► Build new_candidate (merge old + new components)
                            │       │
                            │       └─► adapter.evaluate(batch, new_candidate, capture_traces=False)
                            │               └─► Returns scores for acceptance test
                            │
                            ├─► Acceptance Test (sum(new_scores) > sum(old_scores))
                            │
                            └─► [If Accepted] _run_full_eval_and_add()
                                    │
                                    ├─► val_evaluation_policy.get_eval_batch(valset, state)
                                    │       └─► (Full eval / selective eval)
                                    │
                                    ├─► adapter.evaluate(val_batch, candidate, capture_traces=False)
                                    │
                                    ├─► state.update_state_with_new_program(...)
                                    │       │
                                    │       ├─► Append to program_candidates
                                    │       ├─► Update parent_program_for_candidate
                                    │       ├─► Update prog_candidate_val_subscores
                                    │       └─► Update Pareto frontiers (_update_pareto_front_for_val_id)
                                    │
                                    └─► Log metrics
```

### Detailed Proposer Flow

**ReflectiveMutationProposer**:

```
1. Select Candidate
   ├─► Pareto: select_program_candidate_from_pareto_front()
   ├─► Current Best: argmax(val_scores)
   └─► ε-greedy: Pareto with ε probability of random

2. Select Components to Update
   ├─► Round-robin: Next component for this candidate
   └─► All: All components

3. Sample Training Batch
   └─► batch_sampler.sample_batch(trainset)

4. Evaluate Current Candidate (with traces)
   └─► adapter.evaluate(batch, candidate, capture_traces=True)

5. Check Perfect Score (optional)
   └─► If sum(scores) == perfect_score * len(batch), skip update

6. Build Reflective Dataset
   └─► adapter.make_reflective_dataset(candidate, eval_batch, components)

7. Propose New Component Texts
   ├─► If adapter.propose_new_texts exists:
   │   └─► adapter.propose_new_texts(candidate, reflective_dataset, components)
   └─► Else:
       └─► default_instruction_proposal(reflection_lm, reflective_dataset, ...)

8. Build New Candidate
   └─► new_candidate = {**old_components, **new_components}

9. Evaluate New Candidate (subsample)
   └─► adapter.evaluate(batch, new_candidate, capture_traces=False)

10. Return Proposal
    └─► Includes:
        ├─► candidate: new_candidate
        ├─► parent_program_ids: [selected_candidate_idx]
        ├─► subsample_scores_before: old scores
        └─► subsample_scores_after: new scores
```

**MergeProposer**:

```
1. Select 2 Pareto Programs
   └─► From program_at_pareto_front_valset

2. Find Shared Validation IDs
   └─► Intersection of val_ids where both evaluated
   └─► Require >= merge_val_overlap_floor shared IDs

3. Sample Subsample from Shared IDs
   └─► Random subset for merge testing

4. Evaluate Both Parents on Subsample
   └─► evaluator(subsample, parent1)
   └─► evaluator(subsample, parent2)

5. Merge Components
   └─► For each component:
       ├─► If identical: keep
       └─► If different: concatenate with separator

6. Evaluate Merged Candidate on Subsample
   └─► evaluator(subsample, merged_candidate)

7. Return Proposal
   └─► Includes:
       ├─► candidate: merged_candidate
       ├─► parent_program_ids: [parent1_idx, parent2_idx]
       ├─► subsample_scores_before: [sum(parent1_scores), sum(parent2_scores)]
       └─► subsample_scores_after: [sum(merged_scores)]
```

### State Persistence Flow

```
GEPAEngine.run()
    │
    ├─► [Start] initialize_gepa_state()
    │       │
    │       ├─► Check if run_dir/gepa_state.bin exists
    │       │   ├─► Yes: GEPAState.load(run_dir)
    │       │   └─► No: Create new GEPAState
    │       │
    │       └─► Return state
    │
    ├─► [Loop] Every iteration
    │       └─► state.save(run_dir)
    │               └─► Pickle state to gepa_state.bin
    │
    └─► [End] state.save(run_dir)
            └─► Final save

State Structure on Disk:
    run_dir/
    ├─► gepa_state.bin              # Pickled GEPAState
    └─► generated_best_outputs_valset/
        └─► task_{val_id}/
            └─► iter_{i}_prog_{prog_idx}.json
```

---

## Dependencies Between Components

### Dependency Graph

```
optimize() (api.py)
    │
    ├─► GEPAEngine (engine.py)
    │   ├─► GEPAState (state.py)
    │   ├─► DataLoader (data_loader.py)
    │   ├─► GEPAAdapter (adapter.py) [User-provided]
    │   ├─► ReflectiveMutationProposer
    │   │   ├─► CandidateSelector (strategies/)
    │   │   ├─► ReflectionComponentSelector (strategies/)
    │   │   ├─► BatchSampler (strategies/)
    │   │   └─► LanguageModel (proposer/)
    │   ├─► MergeProposer (optional)
    │   ├─► EvaluationPolicy (strategies/)
    │   └─► StopperProtocol (utils.py)
    │
    ├─► GEPAResult (result.py)
    │
    └─► Utilities (gepa_utils.py)
        ├─► select_program_candidate_from_pareto_front()
        └─► remove_dominated_programs()
```

### Protocol vs. Concrete Dependencies

**Protocols (Interface Contracts)**:
- `GEPAAdapter`: User implements
- `DataLoader`: User can provide custom
- `CandidateSelector`: Pluggable strategy
- `ReflectionComponentSelector`: Pluggable strategy
- `BatchSampler`: Pluggable strategy
- `EvaluationPolicy`: Pluggable strategy
- `StopperProtocol`: Pluggable stopping condition
- `LanguageModel`: User provides (string or callable)

**Concrete Dependencies**:
- `GEPAEngine` depends on `GEPAState` (concrete)
- `GEPAState` depends on `adapter.py` type aliases (concrete)
- `GEPAResult` depends on `GEPAState` structure (concrete)
- `optimize()` orchestrates all components

---

## Elixir Port Considerations

### 1. Core Architecture Patterns

#### **Replace Classes with GenServers**

**Python**:
```python
class GEPAEngine:
    def __init__(self, ...):
        self.state = ...

    def run(self):
        while not self._should_stop():
            # iteration
```

**Elixir**:
```elixir
defmodule GEPA.Engine do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    state = initialize_state(opts)
    {:ok, state, {:continue, :run_optimization}}
  end

  def handle_continue(:run_optimization, state) do
    case should_stop?(state) do
      true -> {:noreply, state}
      false ->
        new_state = run_iteration(state)
        {:noreply, new_state, {:continue, :run_optimization}}
    end
  end
end
```

**Benefits**:
- Fault tolerance via supervision
- Graceful stopping via `handle_info` for signals
- State isolation
- Concurrent message handling

#### **State Management**

**Immutable State Updates**:
```elixir
defmodule GEPA.State do
  @type t :: %__MODULE__{
    program_candidates: [map()],
    parent_program_for_candidate: [[integer() | nil]],
    prog_candidate_val_subscores: [%{data_id => float()}],
    pareto_front_valset: %{data_id => float()},
    program_at_pareto_front_valset: %{data_id => MapSet.t(integer())},
    i: integer(),
    total_num_evals: integer(),
    # ...
  }

  defstruct [
    :program_candidates,
    :parent_program_for_candidate,
    # ...
  ]

  @spec update_with_new_program(t(), map(), keyword()) :: {t(), integer()}
  def update_with_new_program(state, new_program, opts) do
    new_program_idx = length(state.program_candidates)

    state
    |> Map.update!(:program_candidates, &(&1 ++ [new_program]))
    |> Map.update!(:total_num_evals, &(&1 + opts[:num_new_evals]))
    |> update_pareto_frontiers(new_program_idx, opts[:subscores])
    |> then(&{&1, new_program_idx})
  end
end
```

**State Persistence**:
```elixir
defmodule GEPA.State.Persistence do
  @spec save(GEPA.State.t(), String.t()) :: :ok | {:error, term()}
  def save(state, run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")

    # Use ETF (Erlang Term Format) instead of pickle
    data = :erlang.term_to_binary(state, [:compressed])

    File.write(path, data)
  end

  @spec load(String.t()) :: {:ok, GEPA.State.t()} | {:error, term()}
  def load(run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")

    with {:ok, data} <- File.read(path),
         term <- :erlang.binary_to_term(data) do
      {:ok, migrate_if_needed(term)}
    end
  end

  defp migrate_if_needed(%{validation_schema_version: 1} = old_state) do
    # Schema migration logic
  end
  defp migrate_if_needed(state), do: state
end
```

### 2. Protocol vs. Behaviour

**Python Protocols** -> **Elixir Behaviours**

**Python**:
```python
class GEPAAdapter(Protocol[DataInst, Trajectory, RolloutOutput]):
    def evaluate(self, batch, candidate, capture_traces=False):
        ...
```

**Elixir**:
```elixir
defmodule GEPA.Adapter do
  @type data_inst :: term()
  @type trajectory :: term()
  @type rollout_output :: term()
  @type candidate :: %{String.t() => String.t()}

  @callback evaluate(
    batch :: [data_inst()],
    candidate :: candidate(),
    capture_traces :: boolean()
  ) :: GEPA.EvaluationBatch.t()

  @callback make_reflective_dataset(
    candidate :: candidate(),
    eval_batch :: GEPA.EvaluationBatch.t(),
    components_to_update :: [String.t()]
  ) :: %{String.t() => [map()]}

  @optional_callbacks [propose_new_texts: 3]

  @callback propose_new_texts(
    candidate :: candidate(),
    reflective_dataset :: map(),
    components_to_update :: [String.t()]
  ) :: map()
end

# User implementation
defmodule MyApp.CustomAdapter do
  @behaviour GEPA.Adapter

  @impl GEPA.Adapter
  def evaluate(batch, candidate, capture_traces) do
    # Implementation
  end

  @impl GEPA.Adapter
  def make_reflective_dataset(candidate, eval_batch, components) do
    # Implementation
  end
end
```

### 3. Supervision Tree

```elixir
defmodule GEPA.Application do
  use Application

  def start(_type, _args) do
    children = [
      # State persistence worker
      {GEPA.State.Persister, []},

      # Main engine
      {GEPA.Engine, []},

      # Proposer workers (can run concurrently)
      {GEPA.Proposer.Reflective, []},
      {GEPA.Proposer.Merge, []},

      # Evaluation pool (for parallel evaluation)
      {Task.Supervisor, name: GEPA.TaskSupervisor},

      # Logging/tracking
      {GEPA.Logger, []},
      {GEPA.ExperimentTracker, []},
    ]

    opts = [strategy: :one_for_one, name: GEPA.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

**Fault Tolerance**:
- If proposer crashes, engine can continue with fallback
- State persister can recover from crashes
- Evaluation tasks supervised independently

### 4. Concurrency Opportunities

#### **Parallel Evaluation**

**Python** (sequential):
```python
outputs, scores = [], []
for data_inst in batch:
    output, score = evaluate_single(data_inst, candidate)
    outputs.append(output)
    scores.append(score)
```

**Elixir** (parallel):
```elixir
def evaluate_batch(batch, candidate) do
  batch
  |> Task.async_stream(
    fn data_inst -> evaluate_single(data_inst, candidate) end,
    max_concurrency: System.schedulers_online(),
    timeout: 60_000
  )
  |> Enum.map(fn {:ok, result} -> result end)
  |> Enum.unzip()  # Separate into {outputs, scores}
end
```

#### **Concurrent Proposal Testing**

Multiple proposals can be tested concurrently on different subsamples:

```elixir
defmodule GEPA.Proposer.Concurrent do
  def propose_multiple(state, num_proposals \\ 3) do
    1..num_proposals
    |> Task.async_stream(fn _ ->
      propose_single_candidate(state)
    end)
    |> Enum.map(fn {:ok, proposal} -> proposal end)
    |> Enum.max_by(& &1.subsample_score)
  end
end
```

### 5. Data Structures

#### **MapSet for Sets**

**Python**:
```python
program_at_pareto_front_valset: dict[DataId, set[ProgramIdx]]
```

**Elixir**:
```elixir
program_at_pareto_front_valset: %{data_id() => MapSet.t(integer())}

# Usage
MapSet.new([0, 1, 2])
MapSet.put(set, 3)
MapSet.member?(set, 1)
```

#### **ETS for Large State**

For very large candidate pools or validation sets:

```elixir
defmodule GEPA.State.Storage do
  def init do
    :ets.new(:candidates, [:set, :named_table, :public])
    :ets.new(:pareto_fronts, [:set, :named_table, :public])
  end

  def add_candidate(idx, candidate) do
    :ets.insert(:candidates, {idx, candidate})
  end

  def get_candidate(idx) do
    case :ets.lookup(:candidates, idx) do
      [{^idx, candidate}] -> {:ok, candidate}
      [] -> {:error, :not_found}
    end
  end
end
```

**Benefits**:
- Constant-time lookups
- Shared across processes
- Automatic garbage collection

### 6. Stream Processing

**Lazy Evaluation for Large Datasets**:

```elixir
defmodule GEPA.DataLoader.Stream do
  def stream_valset(loader) do
    loader
    |> all_ids()
    |> Stream.chunk_every(100)  # Process in chunks
    |> Stream.map(fn chunk_ids ->
      fetch(loader, chunk_ids)
    end)
  end
end
```

### 7. Pattern Matching for Flow Control

**Python**:
```python
if proposal is None:
    continue
if new_sum <= old_sum:
    continue
```

**Elixir**:
```elixir
case propose(state) do
  nil ->
    {:cont, state}

  %Proposal{subsample_scores_after: new_scores, subsample_scores_before: old_scores}
    when sum(new_scores) <= sum(old_scores) ->
    {:cont, state}

  proposal ->
    {:accept, run_full_eval(proposal, state)}
end
```

### 8. Error Handling

**Python**:
```python
try:
    proposal = reflective_proposer.propose(state)
except Exception as e:
    logger.log(f"Error: {e}")
    if raise_on_exception:
        raise
    continue
```

**Elixir**:
```elixir
case propose(state) do
  {:ok, proposal} ->
    process_proposal(proposal, state)

  {:error, reason} ->
    Logger.error("Proposal failed: #{inspect(reason)}")

    if raise_on_exception do
      raise GEPA.ProposalError, reason: reason
    else
      {:cont, state}
    end
end
```

**Supervisor Strategy**:
```elixir
# If proposer crashes, restart it but continue optimization
{:one_for_one, max_restarts: 3, max_seconds: 5}
```

### 9. Graceful Stopping

**Python**:
```python
def request_stop(self):
    self._stop_requested = True

def _should_stop(self, state):
    return self._stop_requested or self.stop_callback(state)
```

**Elixir**:
```elixir
defmodule GEPA.Engine do
  def handle_info(:stop, state) do
    Logger.info("Stop requested, finishing current iteration...")
    {:noreply, %{state | stop_requested: true}}
  end

  def handle_info({:check_stop, callback}, state) do
    should_stop = callback.(state)

    if should_stop do
      send(self(), :stop)
    end

    {:noreply, state}
  end

  # File-based stopping
  def handle_info(:check_stop_file, state) do
    stop_file = Path.join(state.run_dir, "gepa.stop")

    if File.exists?(stop_file) do
      send(self(), :stop)
    else
      Process.send_after(self(), :check_stop_file, 5000)
    end

    {:noreply, state}
  end
end
```

### 10. Type Specifications

**Use Typespecs for Documentation and Dialyzer**:

```elixir
defmodule GEPA.State do
  @typedoc "Program candidate index"
  @type program_idx :: non_neg_integer()

  @typedoc "Validation data identifier"
  @type data_id :: term()

  @type t :: %__MODULE__{
    program_candidates: [candidate()],
    parent_program_for_candidate: [[program_idx() | nil]],
    prog_candidate_val_subscores: [%{data_id() => float()}],
    pareto_front_valset: %{data_id() => float()},
    program_at_pareto_front_valset: %{data_id() => MapSet.t(program_idx())},
    i: non_neg_integer(),
    num_full_ds_evals: non_neg_integer(),
    total_num_evals: non_neg_integer(),
  }

  @type candidate :: %{String.t() => String.t()}

  @spec update_pareto_front(t(), data_id(), float(), program_idx()) :: t()
  def update_pareto_front(state, val_id, score, program_idx) do
    # Implementation
  end
end
```

### 11. Testing Considerations

**Property-Based Testing** for Pareto frontier logic:

```elixir
defmodule GEPA.StateTest do
  use ExUnit.Case
  use ExUnitProperties

  property "pareto frontier always contains at least one program per val_id" do
    check all state <- state_generator() do
      for {val_id, front} <- state.program_at_pareto_front_valset do
        assert MapSet.size(front) >= 1
      end
    end
  end

  property "programs on pareto front have highest scores" do
    check all state <- state_generator() do
      for {val_id, front} <- state.program_at_pareto_front_valset do
        best_score = state.pareto_front_valset[val_id]

        for prog_idx <- front do
          score = get_in(state.prog_candidate_val_subscores, [prog_idx, val_id])
          assert score == best_score
        end
      end
    end
  end
end
```

### 12. Configuration Management

**Use Application Config**:

```elixir
# config/config.exs
config :gepa,
  default_reflection_minibatch_size: 3,
  max_merge_invocations: 5,
  merge_val_overlap_floor: 5,
  default_candidate_selector: GEPA.Selector.Pareto

# Access in code
defmodule GEPA.Config do
  def get(key, default \\ nil) do
    Application.get_env(:gepa, key, default)
  end
end
```

### 13. Suggested Module Structure

```
lib/
├── gepa/
│   ├── application.ex              # OTP application
│   ├── engine.ex                   # Main GenServer
│   ├── state.ex                    # State struct & functions
│   │   ├── persistence.ex          # Save/load logic
│   │   └── pareto.ex               # Pareto frontier updates
│   ├── adapter.ex                  # Behaviour definition
│   ├── data_loader.ex              # DataLoader behaviour & implementations
│   ├── result.ex                   # Result struct
│   ├── evaluation_batch.ex         # EvaluationBatch struct
│   ├── proposer/
│   │   ├── behaviour.ex            # Proposer behaviour
│   │   ├── reflective.ex           # Reflective mutation GenServer
│   │   └── merge.ex                # Merge GenServer
│   ├── strategies/
│   │   ├── candidate_selector.ex   # Behaviour + implementations
│   │   ├── component_selector.ex   # Behaviour + implementations
│   │   ├── batch_sampler.ex        # Behaviour + implementations
│   │   └── evaluation_policy.ex    # Behaviour + implementations
│   ├── utils/
│   │   ├── pareto_utils.ex         # Domination detection
│   │   └── stoppers.ex             # Stopping conditions
│   ├── logger.ex                   # Logging GenServer
│   └── experiment_tracker.ex       # Tracking GenServer
└── gepa.ex                         # Public API (optimize/1)
```

### 14. Key Design Principles for Elixir Port

1. **Embrace Immutability**: All state updates return new state
2. **Use Behaviours**: Define clear contracts with `@callback`
3. **Supervision**: Leverage OTP for fault tolerance
4. **Concurrency**: Use `Task.async_stream` for parallel evaluation
5. **Pattern Matching**: Replace conditionals with pattern matching
6. **Fail Fast**: Let processes crash and restart via supervisors
7. **ETF over Pickle**: Use Erlang Term Format for persistence
8. **GenServer for Stateful**: Engine, proposers as GenServers
9. **Pure Functions**: Utilities as pure functions in modules
10. **Telemetry**: Use `:telemetry` for metrics instead of custom tracking

### 15. Performance Considerations

**Bottleneck**: Evaluation (calling LLMs/executing programs)

**Optimization**:
- Parallel evaluation of batch examples
- Async proposal generation (test multiple mutations)
- ETS for large state access
- Lazy evaluation with streams
- Caching (memoize expensive computations)

**Memory**:
- Use streams for large datasets
- Limit trajectory storage (only keep recent)
- Compress state on disk (`:compressed` in `:erlang.term_to_binary`)

---

## Summary

### Key Architectural Components

1. **GEPAEngine**: Orchestrates optimization loop with proposer coordination
2. **GEPAState**: Persistent state with sparse validation tracking and Pareto frontiers
3. **GEPAAdapter**: Protocol for user integration (evaluate, reflect, propose)
4. **DataLoader**: Abstract data access with lazy loading support
5. **GEPAResult**: Immutable result snapshot with analysis utilities
6. **Public API**: High-level `optimize()` with sensible defaults

### Core Algorithms

1. **Main Loop**: Merge (if scheduled) -> Reflective Mutation -> Acceptance Test -> Full Eval
2. **Pareto Update**: Per-example best scores with tie handling
3. **Dominated Removal**: Iterative elimination based on multi-objective dominance
4. **Candidate Selection**: Frequency-weighted sampling from Pareto front

### Data Flow

1. User provides adapter and seed candidate
2. Engine initializes/loads state
3. Loop: Propose -> Subsample Eval -> Accept/Reject -> Full Eval -> Update Pareto
4. State persisted every iteration
5. Return immutable result

### Elixir Port Strategy

1. **GenServers** for engine and proposers (stateful, supervised)
2. **Behaviours** for adapter, data loader, strategies (extensible)
3. **Immutable structs** for state (functional updates)
4. **Parallel evaluation** via Task.async_stream
5. **ETF persistence** instead of pickle
6. **Supervision trees** for fault tolerance
7. **Pattern matching** for flow control
8. **Telemetry** for metrics

### Next Steps for Implementation

1. Define core data structures (`GEPA.State`, `GEPA.EvaluationBatch`)
2. Implement behaviours (`GEPA.Adapter`, `GEPA.DataLoader`)
3. Build state management (persistence, Pareto updates)
4. Create engine GenServer with optimization loop
5. Implement proposer GenServers (reflective, merge)
6. Build strategy modules (selectors, samplers, policies)
7. Create public API module
8. Add supervision tree
9. Comprehensive testing (unit, property-based, integration)
10. Documentation and examples

---

**End of Document**
