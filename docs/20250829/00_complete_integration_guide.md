# GEPA to Elixir: Complete Integration Guide

**Date**: 2025-08-29
**Purpose**: Master documentation for porting GEPA Python library to Elixir
**Status**: Complete Analysis Ready for Implementation

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [System Architecture Overview](#system-architecture-overview)
3. [Complete Data Flow](#complete-data-flow)
4. [Core Components](#core-components)
5. [Integration Patterns](#integration-patterns)
6. [Elixir Port Strategy](#elixir-port-strategy)
7. [Implementation Roadmap](#implementation-roadmap)
8. [Testing Strategy](#testing-strategy)
9. [Performance Considerations](#performance-considerations)
10. [Deployment Strategy](#deployment-strategy)

---

## Executive Summary

### What is GEPA?

GEPA (Genetic-Pareto) is a framework for optimizing arbitrary systems composed of text components—like AI prompts, code snippets, or textual specs—against any evaluation metric. It employs LLMs to reflect on system behavior, using feedback from execution and evaluation traces to drive targeted improvements.

### Core Innovation

Unlike traditional RL-based prompt optimization, GEPA uses:
- **Reflective Mutation**: LLM-based analysis of execution traces to generate targeted improvements
- **Pareto-Aware Selection**: Multi-objective optimization maintaining diverse solutions
- **Sparse Evaluation**: Not all programs evaluated on all examples, enabling efficient scaling
- **Genealogy-Based Merging**: Intelligently combines proven improvements from multiple lineages

### Key Statistics

- **~7,000 lines** of Python code analyzed
- **56 Python files** documented
- **6 major subsystems** identified
- **5 vector stores** supported (RAG adapter)
- **7 stop conditions** implemented
- **5 adapter implementations** provided

### Why Port to Elixir?

**Strengths Alignment:**
1. **Concurrency**: Parallel evaluation, multiple proposals, concurrent LLM calls
2. **Fault Tolerance**: Supervision trees for external service integration
3. **Immutability**: Clean state management without side effects
4. **Pattern Matching**: Natural fit for conditional logic and result handling
5. **Process Isolation**: Independent evaluation tasks
6. **Hot Code Reload**: Update strategies without stopping optimization

**Technical Advantages:**
- BEAM VM's lightweight processes ideal for parallel evaluation
- OTP behaviors match GEPA's protocol-based architecture
- Telemetry provides superior observability
- ETS/persistent_term for efficient large-scale state
- Native supervision for robust external system integration

---

## System Architecture Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          GEPA System                                 │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                     optimize() - Public API                   │  │
│  └────────────────────────────┬─────────────────────────────────┘  │
│                               │                                     │
│  ┌────────────────────────────▼─────────────────────────────────┐  │
│  │                      GEPAEngine                               │  │
│  │  - Orchestrates optimization loop                            │  │
│  │  - Manages state persistence                                 │  │
│  │  - Coordinates proposers                                     │  │
│  │  - Handles graceful stopping                                 │  │
│  └─────┬──────────────────────────────────────────────┬─────────┘  │
│        │                                               │            │
│  ┌─────▼──────────────────┐                ┌──────────▼─────────┐  │
│  │  GEPAState            │                │  Proposers          │  │
│  │  - Candidates         │                │  - Reflective Mut.  │  │
│  │  - Sparse Scores      │                │  - Merge           │  │
│  │  - Pareto Fronts      │                └──────────┬─────────┘  │
│  │  - Lineage Tracking   │                           │            │
│  └───────────────────────┘                           │            │
│                                                       │            │
│  ┌────────────────────────────────────────────────────▼─────────┐  │
│  │                       Strategies                              │  │
│  │  - BatchSampler: Data sampling and batching                  │  │
│  │  - CandidateSelector: Which program to mutate                │  │
│  │  - ComponentSelector: Which components to update             │  │
│  │  - EvaluationPolicy: Validation evaluation strategy          │  │
│  │  - InstructionProposal: LLM-based proposal generation        │  │
│  └────────────────────────────┬──────────────────────────────────┘  │
│                                │                                    │
│  ┌────────────────────────────▼──────────────────────────────────┐  │
│  │                    GEPAAdapter (User-Defined)                  │  │
│  │  - evaluate(): Run programs and compute scores                │  │
│  │  - make_reflective_dataset(): Extract feedback from traces    │  │
│  │  - propose_new_texts(): Optional custom proposal logic        │  │
│  └──────────┬─────────────────────────────────────────────────────┘  │
│             │                                                        │
│  ┌──────────▼────────────────────────────────────────────────────┐  │
│  │              External Systems (via Adapters)                   │  │
│  │  - LLMs (OpenAI, Anthropic, Ollama, etc.)                     │  │
│  │  - DSPy Framework                                              │  │
│  │  - Vector Stores (ChromaDB, Qdrant, Weaviate, etc.)           │  │
│  │  - Terminal-Bench / External Agents                           │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │               Supporting Infrastructure                         │  │
│  │  - ExperimentTracker (wandb, MLflow)                           │  │
│  │  - Logger (file, stdout, custom)                               │  │
│  │  - StopConditions (time, budget, threshold, file, signal)      │  │
│  └────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### Component Relationships

```
GEPAEngine
├── Depends On:
│   ├── GEPAState (concrete) - State management
│   ├── GEPAAdapter (protocol) - User-defined integration
│   ├── DataLoader (protocol) - Data access
│   ├── ReflectiveMutationProposer (concrete)
│   ├── MergeProposer (concrete, optional)
│   ├── EvaluationPolicy (protocol)
│   ├── Logger (protocol)
│   ├── ExperimentTracker (concrete)
│   └── StopperProtocol (protocol)
│
├── Uses:
│   ├── Strategies:
│   │   ├── CandidateSelector (protocol)
│   │   ├── ComponentSelector (protocol)
│   │   ├── BatchSampler (protocol)
│   │   └── InstructionProposal (concrete)
│   │
│   └── Utilities:
│       ├── Pareto utilities (concrete functions)
│       └── State persistence (concrete functions)
│
└── Produces:
    └── GEPAResult (concrete) - Immutable optimization result
```

### Data Structures Hierarchy

```
State Data:
├── GEPAState
│   ├── program_candidates: list[dict[str, str]]
│   ├── parent_program_for_candidate: list[list[int | None]]
│   ├── prog_candidate_val_subscores: list[dict[DataId, float]]  # Sparse
│   ├── pareto_front_valset: dict[DataId, float]
│   ├── program_at_pareto_front_valset: dict[DataId, set[int]]
│   ├── list_of_named_predictors: list[str]
│   ├── i: int (iteration)
│   ├── total_num_evals: int
│   └── ... (metadata)
│
Evaluation Data:
├── EvaluationBatch[Trajectory, RolloutOutput]
│   ├── outputs: list[RolloutOutput]  # Opaque to GEPA
│   ├── scores: list[float]            # Higher is better
│   └── trajectories: list[Trajectory] | None
│
Proposal Data:
├── CandidateProposal
│   ├── candidate: dict[str, str]
│   ├── parent_program_ids: list[int]
│   ├── subsample_indices: list[DataId]
│   ├── subsample_scores_before: list[float]
│   ├── subsample_scores_after: list[float]
│   ├── tag: str
│   └── metadata: dict
│
Result Data:
└── GEPAResult
    ├── candidates: list[dict[str, str]]
    ├── parents: list[list[int | None]]
    ├── val_aggregate_scores: list[float]
    ├── val_subscores: list[dict[DataId, float]]
    ├── per_val_instance_best_candidates: dict[DataId, set[int]]
    └── ... (metrics and metadata)
```

---

## Complete Data Flow

### End-to-End Optimization Flow

```
1. User Invokes optimize()
   │
   ├─ Input:
   │  ├─ seed_candidate: dict[str, str]  # Initial program
   │  ├─ trainset: list[DataInst]
   │  ├─ valset: list[DataInst]
   │  ├─ adapter: GEPAAdapter
   │  ├─ strategies: {selectors, sampler, policy}
   │  ├─ stoppers: list[StopperProtocol]
   │  └─ logging_config: {wandb, mlflow, logger}
   │
   ├─ Setup Phase:
   │  ├─ Convert lists to DataLoaders
   │  ├─ Initialize ExperimentTracker
   │  ├─ Compose StopConditions → CompositeStopper
   │  ├─ Initialize Proposers:
   │  │  ├─ ReflectiveMutationProposer
   │  │  └─ MergeProposer (if use_merge=True)
   │  └─ Create GEPAEngine
   │
   ├─ Initialization Phase:
   │  ├─ Check for saved state in run_dir
   │  ├─ If exists: Load GEPAState from disk
   │  ├─ If not: Initialize new GEPAState:
   │  │  ├─ Evaluate seed_candidate on full valset
   │  │  ├─ Set initial Pareto fronts
   │  │  └─ Initialize counters
   │  └─ Log base program metrics
   │
   └─ Main Optimization Loop:
      │
      ├─ Iteration i:
      │  │
      │  ├─ Check Stop Conditions
      │  │  ├─ If _should_stop(state): Break loop
      │  │  └─ If not: Continue
      │  │
      │  ├─ Save State to Disk
      │  │  └─ state.save(run_dir)
      │  │
      │  ├─ Increment Iteration: state.i += 1
      │  │
      │  ├─ [Phase 1] Attempt Merge (if conditions met):
      │  │  │
      │  │  ├─ Conditions:
      │  │  │  ├─ use_merge=True
      │  │  │  ├─ merges_due > 0
      │  │  │  └─ last_iter_found_new_program=True
      │  │  │
      │  │  ├─ MergeProposer.propose(state):
      │  │  │  │
      │  │  │  ├─ Find Pareto front dominators
      │  │  │  ├─ Find common ancestor pair
      │  │  │  ├─ Merge components:
      │  │  │  │  ├─ If ancestor == one descendant: Use changed version
      │  │  │  │  ├─ If both changed: Use higher-scoring version
      │  │  │  │  └─ If both same: Use either
      │  │  │  ├─ Select evaluation subsample (stratified)
      │  │  │  ├─ Evaluate merged candidate on subsample
      │  │  │  └─ Return CandidateProposal
      │  │  │
      │  │  ├─ Acceptance Test:
      │  │  │  └─ sum(new_scores) >= max(sum(parent1_scores), sum(parent2_scores))
      │  │  │
      │  │  ├─ If Accepted:
      │  │  │  ├─ Run full validation evaluation
      │  │  │  ├─ Update state with new program
      │  │  │  ├─ Log detailed metrics
      │  │  │  ├─ Decrement merges_due
      │  │  │  └─ Continue (skip reflective mutation this iteration)
      │  │  │
      │  │  └─ If Rejected or None returned:
      │  │     └─ Continue to reflective mutation
      │  │
      │  └─ [Phase 2] Reflective Mutation:
      │     │
      │     ├─ ReflectiveMutationProposer.propose(state):
      │     │  │
      │     │  ├─ [Step 1] Select Candidate:
      │     │  │  └─ candidate_selector.select_candidate_idx(state)
      │     │  │     ├─ Pareto: Frequency-weighted from Pareto fronts
      │     │  │     ├─ CurrentBest: Max aggregate score
      │     │  │     └─ EpsilonGreedy: Random with probability ε
      │     │  │
      │     │  ├─ [Step 2] Sample Minibatch:
      │     │  │  └─ batch_sampler.next_minibatch_ids(trainset, state)
      │     │  │     └─ EpochShuffled: Deterministic shuffled batches
      │     │  │
      │     │  ├─ [Step 3] Evaluate with Trace Capture:
      │     │  │  ├─ minibatch = trainset.fetch(subsample_ids)
      │     │  │  ├─ eval_curr = adapter.evaluate(minibatch, candidate, capture_traces=True)
      │     │  │  └─ state.total_num_evals += len(subsample_ids)
      │     │  │
      │     │  ├─ [Step 4] Check Perfect Score (optional):
      │     │  │  └─ If all scores == perfect_score: Return None
      │     │  │
      │     │  ├─ [Step 5] Select Components to Update:
      │     │  │  └─ module_selector(state, trajectories, scores, candidate_idx, candidate)
      │     │  │     ├─ RoundRobin: One component per iteration (cyclic)
      │     │  │     └─ All: All components simultaneously
      │     │  │
      │     │  ├─ [Step 6] Build Reflective Dataset:
      │     │  │  └─ reflective_dataset = adapter.make_reflective_dataset(
      │     │  │        candidate, eval_curr, components_to_update
      │     │  │     )
      │     │  │     └─ Returns: dict[component_name → list[feedback_examples]]
      │     │  │        Example:
      │     │  │        {
      │     │  │          "instruction": [
      │     │  │            {
      │     │  │              "Inputs": {...},
      │     │  │              "Generated Outputs": {...},
      │     │  │              "Feedback": "..."
      │     │  │            },
      │     │  │            ...
      │     │  │          ]
      │     │  │        }
      │     │  │
      │     │  ├─ [Step 7] Propose New Component Texts:
      │     │  │  ├─ If adapter.propose_new_texts exists:
      │     │  │  │  └─ new_texts = adapter.propose_new_texts(
      │     │  │  │        candidate, reflective_dataset, components_to_update
      │     │  │  │     )
      │     │  │  └─ Else (default):
      │     │  │     └─ For each component:
      │     │  │        ├─ Format reflective dataset as markdown
      │     │  │        ├─ Build prompt:
      │     │  │        │  "I provided an assistant with the following instructions:
      │     │  │        │   ```<curr_instructions>```
      │     │  │        │   The following are examples with feedback:
      │     │  │        │   <formatted_examples>
      │     │  │        │   Your task is to write a new instruction..."
      │     │  │        ├─ Call reflection_lm(prompt)
      │     │  │        └─ Extract new instruction from ```...``` blocks
      │     │  │
      │     │  ├─ [Step 8] Build New Candidate:
      │     │  │  └─ new_candidate = {**candidate, **new_texts}
      │     │  │
      │     │  ├─ [Step 9] Evaluate New Candidate:
      │     │  │  ├─ eval_new = adapter.evaluate(minibatch, new_candidate, capture_traces=False)
      │     │  │  └─ state.total_num_evals += len(subsample_ids)
      │     │  │
      │     │  └─ [Step 10] Return Proposal:
      │     │     └─ CandidateProposal(
      │     │          candidate=new_candidate,
      │     │          parent_program_ids=[candidate_idx],
      │     │          subsample_indices=subsample_ids,
      │     │          subsample_scores_before=eval_curr.scores,
      │     │          subsample_scores_after=eval_new.scores,
      │     │          tag="reflective_mutation"
      │     │        )
      │     │
      │     ├─ Acceptance Test:
      │     │  └─ sum(eval_new.scores) > sum(eval_curr.scores)
      │     │
      │     ├─ If Rejected or None returned:
      │     │  └─ Continue to next iteration
      │     │
      │     └─ If Accepted:
      │        │
      │        ├─ Run Full Validation Evaluation:
      │        │  │
      │        │  ├─ val_batch_ids = val_evaluation_policy.get_eval_batch(valset, state, new_program_idx)
      │        │  │  └─ FullEvaluationPolicy: All validation IDs
      │        │  │
      │        │  ├─ val_batch = valset.fetch(val_batch_ids)
      │        │  │
      │        │  ├─ eval_val = adapter.evaluate(val_batch, new_candidate, capture_traces=False)
      │        │  │
      │        │  ├─ valset_subscores = dict(zip(val_batch_ids, eval_val.scores))
      │        │  │
      │        │  └─ state.num_full_ds_evals += 1
      │        │     state.total_num_evals += len(val_batch_ids)
      │        │
      │        ├─ Update State with New Program:
      │        │  │
      │        │  └─ new_program_idx = state.update_state_with_new_program(
      │        │       parent_program_idx=parent_program_ids,
      │        │       new_program=new_candidate,
      │        │       valset_subscores=valset_subscores,
      │        │       valset_outputs=valset_outputs,
      │        │       num_metric_calls_by_discovery=state.total_num_evals
      │        │     )
      │        │     │
      │        │     ├─ Append to program_candidates
      │        │     ├─ Record parent relationships
      │        │     ├─ Add validation subscores
      │        │     │
      │        │     └─ Update Pareto Fronts:
      │        │        └─ For each (val_id, score) in valset_subscores:
      │        │           ├─ prev_score = pareto_front_valset.get(val_id, -inf)
      │        │           ├─ If score > prev_score:
      │        │           │  ├─ pareto_front_valset[val_id] = score
      │        │           │  └─ program_at_pareto_front_valset[val_id] = {new_program_idx}
      │        │           └─ Elif score == prev_score:
      │        │              └─ program_at_pareto_front_valset[val_id].add(new_program_idx)
      │        │
      │        ├─ Determine Best Program:
      │        │  └─ best_program_idx = val_evaluation_policy.get_best_program(state)
      │        │     └─ Highest avg score with coverage tie-breaking
      │        │
      │        ├─ Log Detailed Metrics:
      │        │  ├─ Console logs (via logger)
      │        │  └─ Experiment tracker metrics:
      │        │     ├─ iteration, new_program_idx
      │        │     ├─ valset_pareto_front_scores
      │        │     ├─ individual_valset_score_new_program
      │        │     ├─ best_valset_agg_score
      │        │     └─ ... (comprehensive metrics)
      │        │
      │        └─ Schedule Future Merge (if merge enabled):
      │           ├─ merge_proposer.last_iter_found_new_program = True
      │           └─ If total_merges_tested < max_merge_invocations:
      │              └─ merge_proposer.merges_due += 1
      │
      └─ Loop continues until stop condition met
         │
         ├─ Final State Save
         │  └─ state.save(run_dir)
         │
         └─ Return GEPAResult.from_state(state)

2. User Receives GEPAResult:
   │
   ├─ result.best_candidate: Best program found
   ├─ result.best_idx: Index of best program
   ├─ result.candidates: All programs discovered
   ├─ result.val_aggregate_scores: Mean scores
   ├─ result.val_subscores: Sparse per-example scores
   └─ result.discovery_eval_counts: Budget tracking
```

### Adapter Integration Pattern

```
User System ←→ GEPAAdapter ←→ GEPA Engine

Adapter Methods Called by Engine:

1. Initial Evaluation:
   └─ adapter.evaluate(valset, seed_candidate, capture_traces=False)
      └─ Returns: EvaluationBatch with outputs and scores

2. Reflective Mutation Cycle:
   │
   ├─ adapter.evaluate(trainset_batch, current_candidate, capture_traces=True)
   │  └─ Returns: EvaluationBatch with outputs, scores, and trajectories
   │
   ├─ adapter.make_reflective_dataset(candidate, eval_batch, components_to_update)
   │  └─ Returns: dict[component_name → list[feedback_records]]
   │
   ├─ [Optional] adapter.propose_new_texts(candidate, reflective_dataset, components)
   │  └─ Returns: dict[component_name → new_text]
   │
   └─ adapter.evaluate(trainset_batch, new_candidate, capture_traces=False)
      └─ Returns: EvaluationBatch with outputs and scores

3. Validation Evaluation:
   └─ adapter.evaluate(valset, accepted_candidate, capture_traces=False)
      └─ Returns: EvaluationBatch with outputs and scores

Adapter Implementations:
├─ DefaultAdapter: Simple Q&A with substring matching
├─ DspyAdapter: DSPy program instruction optimization
├─ DspyFullProgramAdapter: DSPy program code evolution
├─ AnyMathsAdapter: Math problems with structured output
├─ TerminalBenchAdapter: Terminal task agent optimization
└─ GenericRAGAdapter: Multi-stage RAG pipeline optimization
```

---

## Core Components

### Component Inventory

| Component | Lines of Code | Complexity | Port Priority | Dependencies |
|-----------|--------------|------------|---------------|--------------|
| **Core** |
| GEPAState | ~270 | High | 1 - Critical | pickle, dataclasses |
| GEPAEngine | ~400 | Very High | 1 - Critical | All core + strategies |
| GEPAAdapter | ~180 (protocol) | Medium | 1 - Critical | Generic types |
| DataLoader | ~100 | Low | 2 - Important | Protocol only |
| GEPAResult | ~150 | Low | 3 - Nice to have | JSON, state |
| api.py | ~200 | High | 1 - Critical | All components |
| **Proposers** |
| ReflectiveMutation | ~155 | High | 1 - Critical | Adapter, strategies |
| MergeProposer | ~325 | Very High | 2 - Important | State, utils |
| **Strategies** |
| BatchSampler | ~78 | Medium | 2 - Important | Random, collections |
| CandidateSelector | ~51 | Medium | 2 - Important | Pareto utils |
| ComponentSelector | ~37 | Low | 3 - Nice to have | State |
| EvaluationPolicy | ~80 | Medium | 2 - Important | State, loader |
| InstructionProposal | ~113 | Medium | 2 - Important | LLM integration |
| **Utilities** |
| Pareto Utils | ~118 | High | 1 - Critical | Collections |
| StopConditions | ~120 | Medium | 2 - Important | OS, signals |
| ExperimentTracker | ~100 | Medium | 3 - Nice to have | wandb, mlflow |
| Logger | ~150 | Medium | 3 - Nice to have | sys, file I/O |
| **Adapters** |
| DefaultAdapter | ~120 | Low | 2 - Important | LiteLLM |
| DspyAdapter | ~180 | High | 4 - Optional | DSPy |
| DspyFullProgramAdapter | ~220 | Very High | 5 - Skip | DSPy, exec() |
| AnyMathsAdapter | ~100 | Medium | 4 - Optional | Ollama |
| TerminalBenchAdapter | ~150 | High | 5 - Skip | subprocess |
| GenericRAGAdapter | ~300 | Very High | 4 - Optional | Vector stores |

**Total Estimated LOC for Core Port: ~2,500 lines** (Python → Elixir will be similar or less due to pattern matching)

### Critical Path Components

For a minimal viable Elixir port, implement in this order:

**Phase 1 - Foundation (Week 1-2):**
1. Data structures: GEPAState, EvaluationBatch, CandidateProposal
2. Utilities: Pareto functions, basic stop conditions
3. Protocols: GEPAAdapter, DataLoader, CandidateSelector
4. Simple implementations: ListDataLoader, ParetoCandidateSelector

**Phase 2 - Core Engine (Week 3-4):**
5. ReflectiveMutationProposer
6. GEPAEngine (without merge, simplified)
7. BasicAdapter (equivalent to DefaultAdapter)
8. api.optimize() wrapper

**Phase 3 - Strategies (Week 5):**
9. EpochShuffledBatchSampler
10. RoundRobinComponentSelector
11. FullEvaluationPolicy
12. InstructionProposalSignature

**Phase 4 - Advanced Features (Week 6+):**
13. MergeProposer
14. Additional stop conditions
15. Logging and telemetry integration
16. Additional adapters as needed

---

## Integration Patterns

### Pattern 1: Protocol-Based Polymorphism

**Python Implementation:**
```python
class GEPAAdapter(Protocol[DataInst, Trajectory, RolloutOutput]):
    def evaluate(...) -> EvaluationBatch: ...
    def make_reflective_dataset(...) -> dict: ...
    propose_new_texts: ProposalFn | None = None
```

**Elixir Translation:**
```elixir
defmodule GEPA.Adapter do
  @type data_inst :: term()
  @type trajectory :: term()
  @type rollout_output :: term()

  @callback evaluate(
    batch :: [data_inst()],
    candidate :: %{String.t() => String.t()},
    capture_traces :: boolean()
  ) :: {:ok, GEPA.EvaluationBatch.t()} | {:error, term()}

  @callback make_reflective_dataset(
    candidate :: %{String.t() => String.t()},
    eval_batch :: GEPA.EvaluationBatch.t(),
    components_to_update :: [String.t()]
  ) :: {:ok, %{String.t() => [map()]}} | {:error, term()}

  @optional_callbacks propose_new_texts: 3
  @callback propose_new_texts(
    candidate :: %{String.t() => String.t()},
    reflective_dataset :: %{String.t() => [map()]},
    components_to_update :: [String.t()]
  ) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
end
```

**Usage:**
```elixir
defmodule MyApp.CustomAdapter do
  @behaviour GEPA.Adapter

  @impl true
  def evaluate(batch, candidate, capture_traces) do
    # Implementation
  end

  @impl true
  def make_reflective_dataset(candidate, eval_batch, components) do
    # Implementation
  end
end
```

### Pattern 2: Immutable State Threading

**Python Implementation:**
```python
state.program_candidates.append(new_program)
state.total_num_evals += len(batch)
```

**Elixir Translation:**
```elixir
state = %{state |
  program_candidates: [new_program | state.program_candidates],
  total_num_evals: state.total_num_evals + length(batch)
}
```

**With Lenses for Deep Updates:**
```elixir
state
|> put_in([Access.key(:prog_candidate_val_subscores), new_program_idx], new_scores)
|> update_in([Access.key(:pareto_front_valset), val_id], &max(&1, new_score))
```

### Pattern 3: Concurrent Evaluation

**Python Implementation:**
```python
# Sequential processing
for example in batch:
    result = evaluate_single(example, candidate)
    results.append(result)
```

**Elixir Translation:**
```elixir
# Parallel processing with Task.async_stream
batch
|> Task.async_stream(
  fn example -> evaluate_single(example, candidate) end,
  max_concurrency: System.schedulers_online() * 2,
  timeout: 60_000
)
|> Enum.map(fn {:ok, result} -> result end)
```

### Pattern 4: Graceful Error Handling

**Python Implementation:**
```python
try:
    result = adapter.evaluate(batch, candidate)
except Exception as e:
    logger.log(f"Evaluation failed: {e}")
    result = fallback_result(batch)
```

**Elixir Translation:**
```elixir
case Adapter.evaluate(adapter, batch, candidate) do
  {:ok, result} ->
    process_result(result)

  {:error, reason} ->
    Logger.error("Evaluation failed: #{inspect(reason)}")
    fallback_result(batch)
end
```

**With `with` for Pipelines:**
```elixir
with {:ok, eval_result} <- Adapter.evaluate(adapter, batch, candidate),
     {:ok, dataset} <- Adapter.make_reflective_dataset(adapter, candidate, eval_result, components),
     {:ok, new_texts} <- propose_new_texts(dataset),
     {:ok, new_eval} <- Adapter.evaluate(adapter, batch, new_candidate) do
  {:ok, build_proposal(new_candidate, new_eval)}
else
  {:error, reason} -> {:error, {:proposal_failed, reason}}
end
```

### Pattern 5: Process-Based State Management

**For Stateful Components (NoImprovementStopper, etc.):**

**Option 1: GenServer**
```elixir
defmodule GEPA.StopCondition.NoImprovementServer do
  use GenServer

  defstruct [:best_score, :iterations_without_improvement, :max_iterations]

  def start_link(max_iterations) do
    GenServer.start_link(__MODULE__, max_iterations)
  end

  def init(max_iterations) do
    {:ok, %__MODULE__{
      best_score: :neg_infinity,
      iterations_without_improvement: 0,
      max_iterations: max_iterations
    }}
  end

  def should_stop?(pid, current_score) do
    GenServer.call(pid, {:should_stop, current_score})
  end

  def handle_call({:should_stop, current_score}, _from, state) do
    if current_score > state.best_score do
      {:reply, false, %{state | best_score: current_score, iterations_without_improvement: 0}}
    else
      new_count = state.iterations_without_improvement + 1
      should_stop = new_count >= state.max_iterations
      {:reply, should_stop, %{state | iterations_without_improvement: new_count}}
    end
  end
end
```

**Option 2: Agent (simpler)**
```elixir
defmodule GEPA.StopCondition.NoImprovement do
  def new(max_iterations) do
    {:ok, agent} = Agent.start_link(fn ->
      %{best_score: :neg_infinity, iterations_without_improvement: 0, max: max_iterations}
    end)
    agent
  end

  def should_stop?(agent, current_score) do
    Agent.get_and_update(agent, fn state ->
      if current_score > state.best_score do
        {false, %{state | best_score: current_score, iterations_without_improvement: 0}}
      else
        new_count = state.iterations_without_improvement + 1
        {new_count >= state.max, %{state | iterations_without_improvement: new_count}}
      end
    end)
  end
end
```

### Pattern 6: Telemetry Integration

**Python Implementation:**
```python
experiment_tracker.log_metrics({
    "iteration": i,
    "score": score,
    "program_idx": program_idx
}, step=i)
```

**Elixir Translation:**
```elixir
:telemetry.execute(
  [:gepa, :iteration, :complete],
  %{score: score},
  %{iteration: i, program_idx: program_idx}
)

# Attach handlers in application.ex
:telemetry.attach_many(
  "gepa-metrics",
  [
    [:gepa, :iteration, :complete],
    [:gepa, :program, :discovered],
    [:gepa, :evaluation, :complete]
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  %{}
)

defmodule MyApp.TelemetryHandler do
  def handle_event([:gepa, :iteration, :complete], measurements, metadata, _config) do
    # Log to wandb, MLflow, or custom backend
    Wandb.log(measurements, step: metadata.iteration)
  end
end
```

### Pattern 7: Supervision Tree Architecture

```elixir
defmodule GEPA.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Persistent state store
      {GEPA.StateStore, []},

      # Engine supervisor
      {GEPA.EngineSupervisor, []},

      # Task supervisor for parallel evaluation
      {Task.Supervisor, name: GEPA.TaskSupervisor},

      # Stop condition servers (if needed)
      {GEPA.StopConditionSupervisor, []},

      # Telemetry supervisor
      {GEPA.Telemetry, []}
    ]

    opts = [strategy: :one_for_one, name: GEPA.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule GEPA.EngineSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      # Engine GenServer
      {GEPA.Engine, []},

      # Proposer workers
      {GEPA.Proposer.Reflective, []},
      {GEPA.Proposer.Merge, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

---

## Elixir Port Strategy

### Overall Approach

**Philosophy:** Progressive Enhancement
1. Start with core functionality (MVP)
2. Add advanced features incrementally
3. Leverage Elixir strengths (concurrency, fault tolerance)
4. Maintain functional equivalence with Python
5. Enhance with native Elixir features (Telemetry, supervision)

### Module Structure

```
lib/gepa/
├── application.ex              # OTP application & supervision
├── gepa.ex                     # Public API (optimize/1)
├── core/
│   ├── state.ex                # GEPAState struct & functions
│   ├── state/
│   │   ├── persistence.ex      # Save/load with ETF
│   │   └── pareto.ex           # Pareto frontier management
│   ├── engine.ex               # Main optimization GenServer
│   ├── adapter.ex              # Adapter behaviour
│   ├── data_loader.ex          # DataLoader behaviour & ListDataLoader
│   ├── result.ex               # GEPAResult struct
│   └── types.ex                # Shared types (EvaluationBatch, CandidateProposal)
├── proposer/
│   ├── behaviour.ex            # Proposer behaviour
│   ├── reflective.ex           # ReflectiveMutationProposer
│   └── merge.ex                # MergeProposer
├── strategies/
│   ├── batch_sampler.ex        # BatchSampler behaviour & implementations
│   ├── candidate_selector.ex   # CandidateSelector behaviour & implementations
│   ├── component_selector.ex   # ComponentSelector behaviour & implementations
│   ├── evaluation_policy.ex    # EvaluationPolicy behaviour & implementations
│   └── instruction_proposal.ex # InstructionProposal implementation
├── adapters/
│   ├── basic_adapter.ex        # Simple adapter (like DefaultAdapter)
│   └── ... (other adapters as needed)
├── utils/
│   ├── pareto.ex               # Pareto utilities (domination, selection)
│   └── stop_condition.ex       # Stop condition behaviours & implementations
├── logging/
│   ├── telemetry.ex            # Telemetry setup & handlers
│   └── experiment_tracker.ex   # Experiment tracking abstraction
└── test/
    ├── core/
    ├── proposer/
    ├── strategies/
    └── integration/
```

### Configuration Strategy

```elixir
# config/config.exs
config :gepa,
  # Default optimization settings
  default_perfect_score: 1.0,
  default_skip_perfect_score: true,
  default_max_merge_invocations: 5,
  default_merge_val_overlap_floor: 5,

  # Concurrency settings
  max_concurrent_evaluations: System.schedulers_online() * 2,
  evaluation_timeout: 60_000,

  # Storage settings
  default_run_dir: "./gepa_runs",
  persistence_format: :etf,  # :etf | :json

  # Telemetry settings
  enable_telemetry: true,
  telemetry_prefix: [:gepa]

# config/dev.exs
config :gepa,
  enable_progress_bar: true,
  log_level: :debug

# config/prod.exs
config :gepa,
  enable_progress_bar: false,
  log_level: :info
```

### Type Specifications

```elixir
defmodule GEPA.Types do
  @typedoc "Program candidate - maps component names to their text implementations"
  @type candidate :: %{String.t() => String.t()}

  @typedoc "Program index in state"
  @type program_idx :: non_neg_integer()

  @typedoc "Data identifier (generic, can be int, string, etc.)"
  @type data_id :: term()

  @typedoc "Data instance (user-defined)"
  @type data_inst :: term()

  @typedoc "Trajectory (user-defined execution trace)"
  @type trajectory :: term()

  @typedoc "Rollout output (user-defined program output)"
  @type rollout_output :: term()

  @typedoc "Score (higher is better)"
  @type score :: float()

  @typedoc "Sparse validation scores"
  @type sparse_scores :: %{data_id() => score()}

  @typedoc "Pareto front per validation example"
  @type pareto_fronts :: %{data_id() => MapSet.t(program_idx())}
end

defmodule GEPA.EvaluationBatch do
  @moduledoc """
  Container for evaluation results.
  """
  @type t :: %__MODULE__{
    outputs: [GEPA.Types.rollout_output()],
    scores: [GEPA.Types.score()],
    trajectories: [GEPA.Types.trajectory()] | nil
  }

  @enforce_keys [:outputs, :scores]
  defstruct [:outputs, :scores, trajectories: nil]
end

defmodule GEPA.CandidateProposal do
  @moduledoc """
  Proposal for a new candidate program.
  """
  @type t :: %__MODULE__{
    candidate: GEPA.Types.candidate(),
    parent_program_ids: [GEPA.Types.program_idx()],
    subsample_indices: [GEPA.Types.data_id()] | nil,
    subsample_scores_before: [GEPA.Types.score()] | nil,
    subsample_scores_after: [GEPA.Types.score()] | nil,
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
end
```

### Persistence Strategy

```elixir
defmodule GEPA.State.Persistence do
  @moduledoc """
  Handles state serialization and deserialization.
  """

  @current_schema_version 2

  @spec save(GEPA.State.t(), Path.t()) :: :ok | {:error, term()}
  def save(state, run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")

    data = %{
      version: @current_schema_version,
      state: state
    }

    binary = :erlang.term_to_binary(data, [:compressed])

    with :ok <- File.mkdir_p(run_dir),
         :ok <- File.write(path, binary) do
      :ok
    end
  end

  @spec load(Path.t()) :: {:ok, GEPA.State.t()} | {:error, term()}
  def load(run_dir) do
    path = Path.join(run_dir, "gepa_state.etf")

    with {:ok, binary} <- File.read(path),
         %{version: version, state: state} <- :erlang.binary_to_term(binary) do
      {:ok, migrate_if_needed(state, version)}
    end
  end

  defp migrate_if_needed(state, 2), do: state
  defp migrate_if_needed(state, 1), do: migrate_v1_to_v2(state)
  defp migrate_if_needed(_state, v), do: raise "Unknown schema version: #{v}"

  defp migrate_v1_to_v2(state) do
    # Migration logic for schema version 1 → 2
    # E.g., convert list-based to dict-based sparse scores
    state
  end
end
```

### Concurrency Model

**Evaluation Parallelism:**
```elixir
defmodule GEPA.Adapter.Helpers do
  @doc """
  Evaluates a batch in parallel using Task.async_stream.
  """
  def parallel_evaluate(batch, candidate, eval_fn, opts \\ []) do
    max_concurrency = opts[:max_concurrency] || System.schedulers_online() * 2
    timeout = opts[:timeout] || 60_000

    batch
    |> Task.async_stream(
      fn example -> eval_fn.(example, candidate) end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({[], []}, fn
      {:ok, {output, score}}, {outputs, scores} ->
        {:cont, {[output | outputs], [score | scores]}}

      {:exit, reason}, {outputs, scores} ->
        # Handle timeout or crash
        {:cont, {[{:error, reason} | outputs], [0.0 | scores]}}
    end)
    |> then(fn {outputs, scores} ->
      {Enum.reverse(outputs), Enum.reverse(scores)}
    end)
  end
end
```

**Proposal Parallelism:**
```elixir
defmodule GEPA.Proposer.Concurrent do
  @doc """
  Generates multiple proposals in parallel and selects the best.
  """
  def propose_best_of_n(state, proposer_fn, n) do
    1..n
    |> Task.async_stream(fn _ -> proposer_fn.(state) end,
      max_concurrency: n,
      timeout: 120_000
    )
    |> Enum.reduce(nil, fn
      {:ok, {:ok, proposal}}, best ->
        select_better_proposal(best, proposal)

      _, best ->
        best
    end)
  end

  defp select_better_proposal(nil, proposal), do: proposal
  defp select_better_proposal(best, nil), do: best
  defp select_better_proposal(best, proposal) do
    if sum(proposal.subsample_scores_after) > sum(best.subsample_scores_after) do
      proposal
    else
      best
    end
  end
end
```

### Error Handling Strategy

**Adapter Errors:**
```elixir
defmodule GEPA.Engine do
  def evaluate_with_fallback(adapter, batch, candidate, opts) do
    case Adapter.evaluate(adapter, batch, candidate, opts[:capture_traces] || false) do
      {:ok, eval_batch} ->
        {:ok, eval_batch}

      {:error, reason} ->
        Logger.warning("Adapter evaluation failed: #{inspect(reason)}")

        # Return fallback evaluation batch
        {:ok, %GEPA.EvaluationBatch{
          outputs: Enum.map(batch, fn _ -> {:error, reason} end),
          scores: List.duplicate(0.0, length(batch)),
          trajectories: if(opts[:capture_traces], do: [], else: nil)
        }}
    end
  end
end
```

**Proposer Errors:**
```elixir
defmodule GEPA.Engine do
  def handle_proposal_failure(reason, state) do
    Logger.warning("Proposal failed: #{inspect(reason)}")

    :telemetry.execute(
      [:gepa, :proposal, :failed],
      %{},
      %{reason: reason, iteration: state.i}
    )

    # Continue to next iteration
    :continue
  end
end
```

### Testing Strategy

**Unit Tests:**
```elixir
defmodule GEPA.State.ParetoTest do
  use ExUnit.Case

  describe "update_pareto_front/4" do
    test "updates front when new score is higher" do
      state = initial_state()
      new_state = State.Pareto.update_pareto_front(state, "val_001", 0.95, 1)

      assert new_state.pareto_front_valset["val_001"] == 0.95
      assert MapSet.member?(new_state.program_at_pareto_front_valset["val_001"], 1)
    end

    test "adds to front when score is tied" do
      state = initial_state_with_front("val_001", 0.9, [0])
      new_state = State.Pareto.update_pareto_front(state, "val_001", 0.9, 1)

      assert MapSet.size(new_state.program_at_pareto_front_valset["val_001"]) == 2
      assert MapSet.member?(new_state.program_at_pareto_front_valset["val_001"], 0)
      assert MapSet.member?(new_state.program_at_pareto_front_valset["val_001"], 1)
    end
  end
end
```

**Property-Based Tests:**
```elixir
defmodule GEPA.Utils.ParetoPropertiesTest do
  use ExUnit.Case
  use ExUnitProperties

  property "pareto fronts only contain non-dominated programs" do
    check all(
      programs <- list_of(program_generator(), min_length: 1, max_length: 20),
      scores <- list_of(score_map_generator(), length: length(programs))
    ) do
      state = build_state(programs, scores)
      fronts = state.program_at_pareto_front_valset

      for {_val_id, front_programs} <- fronts do
        for prog <- front_programs do
          refute is_dominated?(prog, MapSet.to_list(front_programs) -- [prog], fronts)
        end
      end
    end
  end

  property "pareto selection always picks from pareto front" do
    check all(state <- gepa_state_generator()) do
      {:ok, selected_idx} = GEPA.Strategies.CandidateSelector.Pareto.select(state)

      # Verify selected program is in at least one Pareto front
      assert Enum.any?(state.program_at_pareto_front_valset, fn {_id, front} ->
        MapSet.member?(front, selected_idx)
      end)
    end
  end
end
```

**Integration Tests:**
```elixir
defmodule GEPA.IntegrationTest do
  use ExUnit.Case

  test "complete optimization run on toy problem" do
    # Setup
    trainset = generate_toy_trainset(20)
    valset = generate_toy_valset(10)
    seed_candidate = %{"instruction" => "Solve the problem."}

    adapter = GEPA.Adapters.ToyAdapter.new()

    # Run optimization
    {:ok, result} = GEPA.optimize(
      seed_candidate: seed_candidate,
      trainset: trainset,
      valset: valset,
      adapter: adapter,
      max_metric_calls: 100
    )

    # Verify
    assert length(result.candidates) > 1
    assert result.best_idx >= 0
    assert Enum.max(result.val_aggregate_scores) > 0
  end
end
```

---

## Implementation Roadmap

### Phase 1: Foundation (Weeks 1-2)

**Milestone**: Basic data structures and utilities functional

**Tasks:**
1. **Project Setup**
   - [ ] Create Mix project with `mix new gepa --sup`
   - [ ] Configure dependencies (Jason for JSON, Telemetry, etc.)
   - [ ] Set up directory structure
   - [ ] Configure CI/CD (GitHub Actions)

2. **Core Data Structures**
   - [ ] Implement `GEPA.Types` module with all typespecs
   - [ ] Implement `GEPA.EvaluationBatch` struct
   - [ ] Implement `GEPA.CandidateProposal` struct
   - [ ] Implement `GEPA.State` struct with all fields
   - [ ] Write unit tests for structs

3. **Pareto Utilities**
   - [ ] Implement `is_dominated?/3`
   - [ ] Implement `remove_dominated_programs/2`
   - [ ] Implement `select_program_candidate_from_pareto_front/3`
   - [ ] Property-based tests for Pareto logic

4. **Basic Protocols**
   - [ ] Define `GEPA.Adapter` behaviour
   - [ ] Define `GEPA.DataLoader` behaviour
   - [ ] Implement `GEPA.DataLoader.List`
   - [ ] Define `GEPA.Proposer` behaviour

5. **State Persistence**
   - [ ] Implement `GEPA.State.Persistence.save/2`
   - [ ] Implement `GEPA.State.Persistence.load/2`
   - [ ] Implement schema versioning
   - [ ] Test save/load roundtrip

**Deliverables:**
- Working data structures with tests
- Pareto utility functions with property tests
- Basic protocols defined
- State persistence working

### Phase 2: Core Engine (Weeks 3-4)

**Milestone**: Basic optimization loop functional

**Tasks:**
1. **Strategies Implementation**
   - [ ] Define `GEPA.Strategies.CandidateSelector` behaviour
   - [ ] Implement `ParetoCandidateSelector`
   - [ ] Implement `CurrentBestCandidateSelector`
   - [ ] Define `GEPA.Strategies.BatchSampler` behaviour
   - [ ] Implement `EpochShuffledBatchSampler`
   - [ ] Define `GEPA.Strategies.ComponentSelector` behaviour
   - [ ] Implement `RoundRobinComponentSelector`
   - [ ] Define `GEPA.Strategies.EvaluationPolicy` behaviour
   - [ ] Implement `FullEvaluationPolicy`

2. **Reflective Mutation Proposer**
   - [ ] Implement `GEPA.Proposer.Reflective` module
   - [ ] Implement candidate selection step
   - [ ] Implement minibatch sampling step
   - [ ] Implement evaluation with traces step
   - [ ] Implement component selection step
   - [ ] Implement reflective dataset building step
   - [ ] Implement instruction proposal step (basic)
   - [ ] Implement new candidate evaluation step
   - [ ] Write unit tests for each step

3. **GEPAEngine**
   - [ ] Implement `GEPA.Engine` GenServer
   - [ ] Implement initialization/loading logic
   - [ ] Implement main optimization loop
   - [ ] Implement stop condition checking
   - [ ] Implement state update logic
   - [ ] Implement validation evaluation
   - [ ] Implement Pareto front updates
   - [ ] Add error handling
   - [ ] Write integration tests

4. **Basic Adapter**
   - [ ] Implement `GEPA.Adapters.Basic`
   - [ ] Implement `evaluate/3` with simple LLM calls
   - [ ] Implement `make_reflective_dataset/3`
   - [ ] Mock LLM for testing
   - [ ] Write adapter tests

5. **Public API**
   - [ ] Implement `GEPA.optimize/1` function
   - [ ] Handle configuration options
   - [ ] Setup stop conditions
   - [ ] Initialize strategies
   - [ ] Create engine and run
   - [ ] Return results
   - [ ] Write end-to-end tests

**Deliverables:**
- Working optimization loop
- Basic adapter functional
- Public API complete
- End-to-end test passing

### Phase 3: Stop Conditions & Logging (Week 5)

**Milestone**: Robust stopping and observability

**Tasks:**
1. **Stop Conditions**
   - [ ] Define `GEPA.StopCondition` behaviour
   - [ ] Implement `TimeoutStopCondition`
   - [ ] Implement `MaxMetricCallsStopCondition`
   - [ ] Implement `FileStopCondition`
   - [ ] Implement `ScoreThresholdStopCondition`
   - [ ] Implement `NoImprovementStopCondition`
   - [ ] Implement `SignalStopCondition`
   - [ ] Implement `CompositeStopCondition`
   - [ ] Write tests for each

2. **Telemetry Integration**
   - [ ] Define telemetry events
   - [ ] Instrument engine with telemetry
   - [ ] Instrument proposers with telemetry
   - [ ] Create example telemetry handlers
   - [ ] Write telemetry tests

3. **Logging**
   - [ ] Configure Logger with metadata
   - [ ] Add structured logging throughout
   - [ ] Implement file backend configuration
   - [ ] Add log level controls

4. **Instruction Proposal**
   - [ ] Implement `GEPA.Strategies.InstructionProposal`
   - [ ] Implement markdown formatting
   - [ ] Implement code block extraction
   - [ ] Integrate with LLM client
   - [ ] Write tests

**Deliverables:**
- All stop conditions working
- Telemetry events emitting
- Comprehensive logging
- Instruction proposal complete

### Phase 4: Advanced Features (Week 6)

**Milestone**: Merge proposer and advanced strategies

**Tasks:**
1. **Merge Proposer**
   - [ ] Implement `GEPA.Proposer.Merge` module
   - [ ] Implement dominator finding
   - [ ] Implement common ancestor algorithm
   - [ ] Implement component merge logic
   - [ ] Implement subsample selection
   - [ ] Implement merge evaluation
   - [ ] Write unit tests
   - [ ] Write integration tests

2. **Additional Strategies**
   - [ ] Implement `EpsilonGreedyCandidateSelector`
   - [ ] Implement `AllComponentSelector`
   - [ ] Document strategy extension points

3. **Result Analysis**
   - [ ] Implement `GEPA.Result` struct
   - [ ] Implement analysis functions
   - [ ] Implement serialization (JSON)
   - [ ] Implement lineage tracking
   - [ ] Add visualization helpers

4. **Performance Optimization**
   - [ ] Profile optimization loop
   - [ ] Optimize hot paths
   - [ ] Add ETS for large state
   - [ ] Benchmark against Python

**Deliverables:**
- Merge proposer functional
- Additional strategies implemented
- Result analysis tools
- Performance benchmarks

### Phase 5: Additional Adapters (Week 7-8)

**Milestone**: Support for DSPy, RAG, and other frameworks

**Tasks:**
1. **DSPy Adapter** (if needed)
   - [ ] Research DSPy integration approach
   - [ ] Implement adapter
   - [ ] Write tests
   - [ ] Document usage

2. **RAG Adapter** (if needed)
   - [ ] Define vector store protocol
   - [ ] Implement Qdrant client
   - [ ] Implement RAG pipeline
   - [ ] Implement evaluation metrics
   - [ ] Write tests

3. **Adapter Documentation**
   - [ ] Write adapter developer guide
   - [ ] Provide adapter templates
   - [ ] Document best practices

**Deliverables:**
- Additional adapters as needed
- Adapter developer documentation

### Phase 6: Polish & Documentation (Week 9-10)

**Milestone**: Production-ready library

**Tasks:**
1. **Documentation**
   - [ ] Write comprehensive README
   - [ ] Generate ExDoc documentation
   - [ ] Write getting started guide
   - [ ] Write advanced usage guide
   - [ ] Write API reference
   - [ ] Add code examples
   - [ ] Create tutorial notebooks

2. **Testing**
   - [ ] Achieve >90% test coverage
   - [ ] Add more integration tests
   - [ ] Add performance tests
   - [ ] Add stress tests

3. **Polish**
   - [ ] Code review and refactoring
   - [ ] Optimize performance
   - [ ] Add dialyzer specs
   - [ ] Fix all warnings
   - [ ] Add credo checks

4. **Release**
   - [ ] Version 0.1.0 release
   - [ ] Publish to Hex.pm
   - [ ] Announce release

**Deliverables:**
- Comprehensive documentation
- High test coverage
- Hex.pm package published

---

## Testing Strategy

### Testing Pyramid

```
        ┌─────────────┐
        │  E2E Tests  │  (10%) - Full optimization runs
        │    ~10      │
        ├─────────────┤
        │Integration  │  (20%) - Component interactions
        │   Tests     │
        │    ~40      │
        ├─────────────┤
        │    Unit     │  (70%) - Individual functions
        │   Tests     │
        │   ~150      │
        └─────────────┘
```

### Test Categories

**1. Unit Tests (70% of tests)**

Focus on individual functions and modules:

```elixir
# Pareto utilities
test "is_dominated? returns true when program is dominated"
test "remove_dominated_programs removes only dominated programs"
test "select_program_candidate uses frequency weighting"

# State management
test "update_pareto_front updates when score improves"
test "update_pareto_front adds to set when score ties"
test "update_state_with_new_program increments counters"

# Strategies
test "ParetoCandidateSelector selects from Pareto front"
test "EpochShuffledBatchSampler pads to batch size"
test "RoundRobinComponentSelector cycles through components"

# Stop conditions
test "TimeoutStopCondition triggers after timeout"
test "MaxMetricCallsStopCondition stops at budget"
test "CompositeStopCondition respects mode (any/all)"
```

**2. Property-Based Tests (Subset of unit tests)**

Use StreamData for invariant testing:

```elixir
property "Pareto fronts never contain dominated programs"
property "State updates preserve invariants"
property "Candidate selection always returns valid index"
property "Batch sampler returns correct batch size"
property "Stop conditions are monotonic (once true, stays true)"
property "Score aggregation is commutative"
```

**3. Integration Tests (20% of tests)**

Test component interactions:

```elixir
test "ReflectiveMutation proposal flow end-to-end"
test "Merge proposer with mock state"
test "Engine handles stop conditions correctly"
test "State persistence and recovery"
test "Adapter integration with strategies"
test "Telemetry events are emitted correctly"
```

**4. End-to-End Tests (10% of tests)**

Full optimization runs on toy problems:

```elixir
test "Optimize improves on simple Q&A task"
test "Optimize handles early stopping"
test "Optimize recovers from crash"
test "Optimize respects budget constraints"
test "Merge improves on multi-component optimization"
```

### Test Helpers

```elixir
defmodule GEPA.TestHelpers do
  @doc "Creates a mock GEPA state for testing"
  def create_mock_state(opts \\ []) do
    %GEPA.State{
      program_candidates: opts[:candidates] || [%{"instruction" => "seed"}],
      parent_program_for_candidate: opts[:parents] || [[nil]],
      prog_candidate_val_subscores: opts[:subscores] || [%{}],
      pareto_front_valset: opts[:fronts] || %{},
      program_at_pareto_front_valset: opts[:front_programs] || %{},
      list_of_named_predictors: opts[:predictors] || ["instruction"],
      named_predictor_id_to_update_next_for_program_candidate: opts[:next_predictors] || [0],
      i: opts[:iteration] || 0,
      num_full_ds_evals: 0,
      total_num_evals: 0,
      num_metric_calls_by_discovery: [],
      full_program_trace: [],
      best_outputs_valset: nil,
      validation_schema_version: 2
    }
  end

  @doc "Creates a mock adapter for testing"
  def create_mock_adapter(eval_fn \\ nil) do
    eval_fn = eval_fn || fn _batch, _candidate, _capture_traces ->
      {:ok, %GEPA.EvaluationBatch{
        outputs: ["output"],
        scores: [0.8],
        trajectories: nil
      }}
    end

    MockAdapter.new(eval_fn)
  end

  @doc "Creates toy dataset for testing"
  def create_toy_dataset(n) do
    for i <- 1..n do
      %{
        input: "Question #{i}",
        answer: "Answer #{i}"
      }
    end
  end
end
```

### Continuous Integration

```yaml
# .github/workflows/ci.yml
name: CI

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        elixir: ['1.15', '1.16', '1.17']
        otp: ['25', '26', '27']

    steps:
      - uses: actions/checkout@v3
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ matrix.elixir }}
          otp-version: ${{ matrix.otp }}

      - name: Cache dependencies
        uses: actions/cache@v3
        with:
          path: deps
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}

      - name: Install dependencies
        run: mix deps.get

      - name: Run tests
        run: mix test

      - name: Check formatting
        run: mix format --check-formatted

      - name: Run Credo
        run: mix credo --strict

      - name: Run Dialyzer
        run: mix dialyzer

  coverage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.17'
          otp-version: '27'

      - name: Install dependencies
        run: mix deps.get

      - name: Run tests with coverage
        run: mix test --cover

      - name: Upload coverage
        uses: codecov/codecov-action@v3
```

---

## Performance Considerations

### Bottlenecks in Python Implementation

1. **LLM API Calls** (90% of time)
   - Query reformulation: ~1-2s
   - Instruction proposal: ~2-4s
   - Answer generation: ~2-4s
   - **Total per iteration: 5-10s**

2. **Evaluation** (5-8% of time)
   - Sequential processing in Python
   - Can't parallelize easily due to GIL
   - **Elixir Advantage**: Natural parallelism

3. **State Updates** (1-2% of time)
   - In-memory operations
   - Pareto front updates
   - Dictionary operations

4. **Disk I/O** (<1% of time)
   - State persistence
   - Log file writes

### Elixir Performance Optimizations

**1. Parallel Evaluation**

```elixir
# Python: Sequential (with GIL limitations)
Time: n_examples * time_per_example

# Elixir: Parallel
Time: (n_examples / n_schedulers) * time_per_example

# Example: 100 examples, 10 schedulers
# Python: 100 * 0.5s = 50s
# Elixir: (100 / 10) * 0.5s = 5s
# Speedup: 10x
```

**2. Concurrent Proposals**

Test multiple mutations in parallel:
```elixir
# Generate 3 proposals concurrently
proposals = GEPA.Proposer.propose_multiple(state, 3)
best = Enum.max_by(proposals, &score/1)

# Potential speedup: 3x on proposal generation
```

**3. ETS for Large State**

```elixir
# For large candidate pools (>1000 programs)
:ets.new(:candidates, [:set, :public, :named_table])
:ets.new(:pareto_fronts, [:set, :public, :named_table])

# Constant-time lookups
# Shared across processes
# No deep copies needed
```

**4. Lazy Evaluation**

```elixir
# Stream processing for large datasets
valset
|> Stream.chunk_every(100)
|> Stream.map(&evaluate_chunk/1)
|> Enum.to_list()
```

**5. Binary Optimization**

```elixir
# Use binaries for large texts
defmodule GEPA.State do
  @type t :: %__MODULE__{
    program_candidates: [%{String.t() => binary()}],  # Use binaries
    # ...
  }
end

# Binary pattern matching for parsing
def extract_code_block(<<_ ::binary-size(3), rest::binary>>) do
  # Fast binary operations
end
```

**6. Process Pooling**

```elixir
# Pool of LLM client processes
{:ok, pool} = Poolboy.start_link([
  name: {:local, :llm_pool},
  worker_module: GEPA.LLM.Worker,
  size: 10,
  max_overflow: 20
])

# Reuse connections, avoid setup overhead
```

### Memory Management

**Python Memory Usage:**
- State: ~10-50MB (depending on candidate count)
- Trajectories: ~1-5MB per iteration (if captured)
- Pareto fronts: ~1-10MB

**Elixir Memory Optimization:**

```elixir
# 1. Use ETS for large collections
:ets.insert(:candidates, {idx, candidate})

# 2. Use persistent_term for read-heavy data
:persistent_term.put({:config, :perfect_score}, 1.0)

# 3. Stream large datasets
File.stream!("large_dataset.jsonl")
|> Stream.map(&Jason.decode!/1)
|> Stream.chunk_every(100)
|> Enum.each(&process_batch/1)

# 4. Explicit garbage collection after large operations
:erlang.garbage_collect()

# 5. Limit trajectory retention
config :gepa,
  max_trajectory_history: 100  # Keep only last 100
```

### Benchmarks

**Target Performance (Elixir vs Python):**

| Operation | Python Time | Elixir Target | Notes |
|-----------|------------|---------------|-------|
| Parallel eval (100 examples) | 50s | 5-10s | 5-10x speedup |
| Pareto front update | 10ms | 5ms | 2x speedup |
| State persistence | 100ms | 50ms | 2x speedup |
| Single iteration | 10-15s | 8-12s | 1.2-1.5x speedup |
| Full optimization (100 iters) | 20-30min | 15-20min | 1.3-1.5x speedup |

**Measurement Strategy:**
```elixir
# Telemetry for automatic benchmarking
:telemetry.execute(
  [:gepa, :operation, :start],
  %{system_time: System.system_time()},
  %{operation: :evaluate}
)

# ... operation ...

:telemetry.execute(
  [:gepa, :operation, :stop],
  %{duration: duration},
  %{operation: :evaluate}
)

# Aggregate and report
defmodule GEPA.Benchmarks do
  def report do
    :telemetry_metrics.summary(
      [:gepa, :operation, :stop],
      unit: {:native, :millisecond}
    )
  end
end
```

---

## Deployment Strategy

### Packaging for Hex.pm

```elixir
# mix.exs
defmodule GEPA.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/your_org/gepa_ex"

  def project do
    [
      app: :gepa,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "GEPA",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {GEPA.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:req, "~> 0.4"},  # For HTTP LLM clients
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 0.6", only: :test}
    ]
  end

  defp description do
    """
    A framework for optimizing textual system components (AI prompts, code snippets, etc.)
    using LLM-based reflection and Pareto-efficient evolutionary search.
    """
  end

  defp package do
    [
      name: "gepa",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Python Version" => "https://github.com/gepa-ai/gepa"
      }
    ]
  end

  defp docs do
    [
      main: "GEPA",
      extras: ["README.md", "CHANGELOG.md", "guides/getting_started.md"],
      groups_for_modules: [
        Core: [GEPA, GEPA.Engine, GEPA.State],
        Proposers: [GEPA.Proposer.Reflective, GEPA.Proposer.Merge],
        Strategies: ~r/GEPA.Strategies/,
        Adapters: ~r/GEPA.Adapters/,
        Utilities: ~r/GEPA.Utils/
      ]
    ]
  end
end
```

### Docker Deployment

```dockerfile
# Dockerfile
FROM elixir:1.17-alpine AS builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache build-base git

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Copy source
COPY lib ./lib
COPY config ./config

# Compile
RUN MIX_ENV=prod mix compile

# Release
RUN MIX_ENV=prod mix release

# Runtime stage
FROM alpine:3.18

RUN apk add --no-cache openssl ncurses-libs libstdc++

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/gepa ./

ENV HOME=/app

CMD ["bin/gepa", "start"]
```

### Configuration Management

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  config :gepa,
    llm_api_key: System.get_env("OPENAI_API_KEY"),
    max_concurrent_evaluations: String.to_integer(System.get_env("MAX_CONCURRENCY", "10")),
    default_run_dir: System.get_env("GEPA_RUN_DIR", "/data/gepa_runs")

  config :logger,
    level: :info,
    backends: [:console, {LoggerFileBackend, :file_log}]

  config :logger, :file_log,
    path: "/var/log/gepa/app.log",
    level: :info
end
```

### Observability

```elixir
# lib/gepa/telemetry.ex
defmodule GEPA.Telemetry do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {TelemetryMetricsPrometheus, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # Engine metrics
      last_value("gepa.engine.iterations.count"),
      summary("gepa.iteration.duration", unit: {:native, :millisecond}),

      # Evaluation metrics
      counter("gepa.evaluation.count"),
      summary("gepa.evaluation.duration", unit: {:native, :millisecond}),

      # Proposal metrics
      counter("gepa.proposal.accepted.count"),
      counter("gepa.proposal.rejected.count"),

      # Score metrics
      last_value("gepa.optimization.best_score"),
      last_value("gepa.optimization.candidates.count")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_vm_memory, []},
      {__MODULE__, :measure_process_count, []}
    ]
  end

  def measure_vm_memory do
    :telemetry.execute([:vm, :memory], :erlang.memory(), %{})
  end

  def measure_process_count do
    :telemetry.execute([:vm, :process_count], %{count: length(:erlang.processes())}, %{})
  end
end
```

---

## Summary and Next Steps

### What We Have

**Comprehensive Analysis:**
- ✅ 6 detailed component documentation files
- ✅ ~7,000 lines of Python code analyzed
- ✅ Complete understanding of data flow
- ✅ All integration patterns identified
- ✅ Elixir port strategy defined

**Key Insights:**
1. **GEPA is highly modular** - Protocol-based design maps well to Elixir behaviors
2. **Core complexity is manageable** - ~2,500 LOC for core port
3. **Concurrency opportunities are significant** - 5-10x speedup potential
4. **OTP is a perfect fit** - Supervision trees for fault tolerance
5. **Pareto optimization is the heart** - Must be implemented correctly

### What We Need

**To Begin Implementation:**
1. ✅ Complete architecture documentation (this document)
2. ⬜ Elixir project scaffolding
3. ⬜ Development environment setup
4. ⬜ Test infrastructure
5. ⬜ CI/CD pipeline

**To Reach MVP:**
1. ⬜ Core data structures (Week 1-2)
2. ⬜ Basic optimization loop (Week 3-4)
3. ⬜ Simple adapter (Week 3-4)
4. ⬜ Stop conditions (Week 5)
5. ⬜ End-to-end tests (Week 5)

**To Reach Feature Parity:**
1. ⬜ Merge proposer (Week 6)
2. ⬜ All strategies (Week 6)
3. ⬜ Logging and telemetry (Week 5-6)
4. ⬜ Additional adapters (Week 7-8)
5. ⬜ Documentation (Week 9-10)

### Recommended Next Actions

**Immediate (This Week):**
1. Review this documentation with team
2. Set up Elixir development environment
3. Create GitHub repository
4. Initialize Mix project with supervision tree
5. Set up CI/CD (GitHub Actions)

**Short Term (Weeks 1-2):**
1. Implement core data structures
2. Write property-based tests for Pareto utilities
3. Define all behaviors/protocols
4. Implement state persistence
5. Set up telemetry infrastructure

**Medium Term (Weeks 3-6):**
1. Implement reflective mutation proposer
2. Implement GEPA engine
3. Create basic adapter
4. Build public API
5. Achieve end-to-end optimization

**Long Term (Weeks 7-10):**
1. Add merge proposer
2. Implement additional adapters
3. Optimize performance
4. Write comprehensive documentation
5. Release v0.1.0 to Hex.pm

### Success Criteria

**MVP Success (Week 5):**
- [ ] Can run basic optimization loop
- [ ] Can optimize simple prompts
- [ ] State persists and recovers
- [ ] Tests pass (>80% coverage)
- [ ] End-to-end test completes

**Feature Parity Success (Week 10):**
- [ ] All core features implemented
- [ ] Performance within 2x of Python
- [ ] Documentation complete
- [ ] Published to Hex.pm
- [ ] Example notebooks working

**Production Ready Success (Week 12):**
- [ ] Performance matches or exceeds Python
- [ ] >90% test coverage
- [ ] Comprehensive documentation
- [ ] Multiple adapters available
- [ ] Community adoption starting

### Risk Mitigation

**Technical Risks:**
1. **LLM API Integration**: Mitigate by starting with simple HTTP clients (Req)
2. **State Persistence**: Mitigate by using proven ETF format, extensive testing
3. **Pareto Logic Correctness**: Mitigate with property-based tests, cross-validation with Python
4. **Performance**: Mitigate with benchmarking from day 1, profiling tools

**Project Risks:**
1. **Scope Creep**: Mitigate with phased approach, MVP first
2. **Time Estimation**: Mitigate with buffer in estimates, weekly reviews
3. **Dependency Issues**: Mitigate with minimal dependencies, version pinning
4. **Documentation Lag**: Mitigate with doc-driven development, ExDoc from start

---

## Appendix: Key Files Reference

### Python Source Files by Category

**Core (Priority 1):**
- `src/gepa/core/engine.py` - Main optimization engine
- `src/gepa/core/state.py` - State management
- `src/gepa/core/adapter.py` - Adapter protocol
- `src/gepa/core/data_loader.py` - Data loader protocol
- `src/gepa/core/result.py` - Result container
- `src/gepa/api.py` - Public API
- `src/gepa/gepa_utils.py` - Pareto utilities

**Proposers (Priority 1-2):**
- `src/gepa/proposer/reflective_mutation/reflective_mutation.py` - Reflective mutation
- `src/gepa/proposer/merge.py` - Merge proposer
- `src/gepa/proposer/base.py` - Proposer protocol

**Strategies (Priority 2):**
- `src/gepa/strategies/batch_sampler.py` - Batch sampling
- `src/gepa/strategies/candidate_selector.py` - Candidate selection
- `src/gepa/strategies/component_selector.py` - Component selection
- `src/gepa/strategies/eval_policy.py` - Evaluation policy
- `src/gepa/strategies/instruction_proposal.py` - Instruction proposal

**Utilities (Priority 2-3):**
- `src/gepa/utils/stop_condition.py` - Stop conditions
- `src/gepa/logging/experiment_tracker.py` - Experiment tracking
- `src/gepa/logging/logger.py` - Logger
- `src/gepa/logging/utils.py` - Logging utilities

**Adapters (Priority 2-5):**
- `src/gepa/adapters/default_adapter/` - Simple adapter
- `src/gepa/adapters/dspy_adapter/` - DSPy integration
- `src/gepa/adapters/generic_rag_adapter/` - RAG optimization
- `src/gepa/adapters/anymaths_adapter/` - Math problems
- `src/gepa/adapters/terminal_bench_adapter/` - Terminal tasks

### Generated Documentation Files

1. `docs/20250829/01_core_architecture.md` - Core engine and architecture (1,919 lines)
2. `docs/20250829/02_proposer_system.md` - Proposer system (1,703 lines)
3. `docs/20250829/03_strategies.md` - Optimization strategies (1,507 lines)
4. `docs/20250829/04_adapters.md` - Adapter implementations (1,253 lines)
5. `docs/20250829/05_rag_adapter.md` - RAG adapter system (1,557 lines)
6. `docs/20250829/06_logging_utilities.md` - Logging and utilities (1,250 lines)
7. `docs/20250829/00_complete_integration_guide.md` - This document

**Total Documentation:** ~10,000+ lines of detailed analysis

---

## Conclusion

This integration guide provides a complete roadmap for porting GEPA from Python to Elixir. The analysis reveals that:

1. **GEPA's architecture is well-suited for Elixir** - Protocol-based design, clear separation of concerns, and emphasis on immutability align perfectly with Elixir/OTP patterns

2. **Significant performance gains are possible** - Leveraging BEAM's concurrency primitives can provide 5-10x speedup for evaluation-heavy workloads

3. **The port is achievable in 10-12 weeks** - With a phased approach focusing on MVP first, then feature parity, then optimization

4. **Core functionality requires ~2,500 LOC** - Manageable scope for initial implementation

5. **Testing strategy is clear** - Property-based tests for Pareto logic, unit tests for components, integration tests for flows

**The path forward is clear:** Begin with Phase 1 (Foundation) implementing core data structures and utilities, then progress through the roadmap to deliver a production-ready Elixir implementation of GEPA.

This documentation, combined with the 6 component-specific documents, provides everything needed to begin implementation with confidence.

---

**Document Version:** 1.0
**Last Updated:** 2025-08-29
**Authors:** GEPA Analysis Team
**Status:** Ready for Implementation
