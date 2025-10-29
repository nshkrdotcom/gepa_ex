# GEPA Proposer System Documentation

**Purpose**: This document describes the Proposer System of the GEPA (Genetic Evolutionary Prompt Augmentation) library for the purpose of porting to Elixir.

**Date**: 2025-08-29

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Base Proposer Interface](#base-proposer-interface)
4. [Reflective Mutation Proposer](#reflective-mutation-proposer)
5. [Merge Proposer](#merge-proposer)
6. [Supporting Components](#supporting-components)
7. [Mutation Algorithms](#mutation-algorithms)
8. [Reflection Mechanisms](#reflection-mechanisms)
9. [LLM Integration](#llm-integration)
10. [Elixir Port Considerations](#elixir-port-considerations)

---

## Overview

The Proposer System is the core mutation engine of GEPA. It is responsible for generating new candidate programs (prompt/instruction variants) based on:
- **Reflective Mutation**: Using execution feedback and LLM-based reflection to improve instructions
- **Merge Operations**: Combining successful program candidates through common ancestor analysis

### Key Concepts

- **Candidate**: A program represented as `dict[str, str]` mapping component names to instruction text
- **Proposal**: A new candidate with metadata about parents, subsample evaluations, and acceptance criteria
- **State**: Persistent optimizer state tracking all candidates, scores, and Pareto fronts
- **Reflection**: The process of analyzing execution traces to generate improvement feedback
- **Mutation**: Creating new candidates by modifying existing ones based on feedback

---

## Architecture

### Proposer Protocol

The proposer system uses a protocol-based architecture with a single interface:

```python
class ProposeNewCandidate(Protocol[DataId]):
    """
    Strategy that receives the current optimizer state and proposes a new candidate or returns None.
    """
    def propose(self, state: GEPAState[Any, DataId]) -> CandidateProposal | None: ...
```

### Data Structures

#### CandidateProposal

A proposal contains:
- `candidate`: The new program as a dict of component name -> instruction text
- `parent_program_ids`: List of parent program indices
- `subsample_indices`: IDs of validation examples used for evaluation (optional)
- `subsample_scores_before`: Scores of parent(s) on subsample (optional)
- `subsample_scores_after`: Scores of new candidate on subsample (optional)
- `tag`: String identifier for the proposal type ("reflective_mutation", "merge")
- `metadata`: Additional proposal-specific data

**Key Design**: The proposer evaluates on a subsample and returns the proposal. The engine then decides acceptance and performs full validation evaluation.

---

## Base Proposer Interface

**File**: `/gepa/src/gepa/proposer/base.py`

### ProposeNewCandidate Protocol

This is the core interface that all proposers implement:

```python
class ProposeNewCandidate(Protocol[DataId]):
    def propose(self, state: GEPAState[Any, DataId]) -> CandidateProposal | None: ...
```

**Contract**:
- Receives the current optimizer state
- May compute subsample evaluations
- May set trace fields in state for logging
- Returns a `CandidateProposal` or `None` if no proposal can be made
- The engine handles full evaluation and acceptance

**State Access**: Proposers have read/write access to:
- `state.program_candidates`: All program candidates
- `state.program_full_scores_val_set`: Aggregate validation scores
- `state.prog_candidate_val_subscores`: Sparse validation scores per example
- `state.program_at_pareto_front_valset`: Pareto front membership
- `state.parent_program_for_candidate`: Parent relationships
- `state.full_program_trace`: Execution trace for logging
- `state.total_num_evals`: Evaluation counter

---

## Reflective Mutation Proposer

**File**: `/gepa/src/gepa/proposer/reflective_mutation/reflective_mutation.py`

### Overview

Reflective mutation is the primary strategy for improving candidates through feedback-driven instruction refinement. It uses execution traces and LLM-based reflection to propose improved instruction text.

### Algorithm Flow

```
1. Select Candidate
   ↓
2. Sample Minibatch from Training Set
   ↓
3. Evaluate with Trace Capture
   ↓
4. Check Perfect Score (optional skip)
   ↓
5. Select Components to Update
   ↓
6. Build Reflective Dataset
   ↓
7. LLM Proposes New Instructions
   ↓
8. Evaluate New Candidate on Same Minibatch
   ↓
9. Return Proposal
```

### Class: ReflectiveMutationProposer

```python
class ReflectiveMutationProposer(ProposeNewCandidate[DataId]):
    def __init__(
        self,
        logger: Any,
        trainset: list[DataInst] | DataLoader[DataId, DataInst],
        adapter: GEPAAdapter[DataInst, Trajectory, RolloutOutput],
        candidate_selector: CandidateSelector,
        module_selector: ReflectionComponentSelector,
        batch_sampler: BatchSampler[DataId, DataInst],
        perfect_score: float,
        skip_perfect_score: bool,
        experiment_tracker: Any,
        reflection_lm: LanguageModel | None = None,
        reflection_prompt_template: str | None = None,
    )
```

**Dependencies**:
- `trainset`: Training data loader
- `adapter`: User-defined evaluation and reflection adapter
- `candidate_selector`: Strategy for selecting which candidate to mutate
- `module_selector`: Strategy for selecting which components to update
- `batch_sampler`: Strategy for sampling minibatches
- `reflection_lm`: Language model for generating new instructions
- `reflection_prompt_template`: Optional custom prompt template

### Step-by-Step Process

#### 1. Candidate Selection

```python
curr_prog_id = self.candidate_selector.select_candidate_idx(state)
curr_prog = state.program_candidates[curr_prog_id]
```

**Available Selectors** (from `/gepa/src/gepa/strategies/candidate_selector.py`):
- `ParetoCandidateSelector`: Samples from Pareto front weighted by frequency
- `CurrentBestCandidateSelector`: Always selects highest-scoring candidate
- `EpsilonGreedyCandidateSelector`: ε-greedy exploration

#### 2. Minibatch Sampling

```python
subsample_ids = self.batch_sampler.next_minibatch_ids(self.trainset, state)
minibatch = self.trainset.fetch(subsample_ids)
```

**Batch Sampler** (from `/gepa/src/gepa/strategies/batch_sampler.py`):
- `EpochShuffledBatchSampler`: Shuffles data each epoch, pads to batch size

#### 3. Evaluation with Trace Capture

```python
eval_curr = self.adapter.evaluate(minibatch, curr_prog, capture_traces=True)
state.total_num_evals += len(subsample_ids)
```

**Returns**: `EvaluationBatch` containing:
- `outputs`: Raw per-example outputs
- `scores`: Per-example numeric scores
- `trajectories`: Execution traces for reflection

**Perfect Score Check**:
```python
if self.skip_perfect_score and all(s >= self.perfect_score for s in eval_curr.scores):
    return None  # Skip if all examples are perfect
```

#### 4. Component Selection

```python
predictor_names_to_update = self.module_selector(
    state, eval_curr.trajectories, eval_curr.scores, curr_prog_id, curr_prog
)
```

**Available Selectors** (from `/gepa/src/gepa/strategies/component_selector.py`):
- `RoundRobinReflectionComponentSelector`: Updates one component at a time in sequence
- `AllReflectionComponentSelector`: Updates all components simultaneously

#### 5. Reflective Dataset Construction

```python
reflective_dataset = self.adapter.make_reflective_dataset(
    curr_prog, eval_curr, predictor_names_to_update
)
```

**User-Defined**: The adapter builds a JSON-serializable dataset per component with:
- Input data
- Generated outputs
- Feedback on performance (errors, correct answers, etc.)

**Example Schema**:
```python
{
    "component_name": [
        {
            "Inputs": {...},
            "Generated Outputs": {...},
            "Feedback": "..."
        },
        ...
    ]
}
```

#### 6. Instruction Proposal

```python
new_texts = self.propose_new_texts(curr_prog, reflective_dataset, predictor_names_to_update)
```

**Two Paths**:
1. **Custom**: Uses `adapter.propose_new_texts` if provided
2. **Default**: Uses `InstructionProposalSignature.run()` (see [LLM Integration](#llm-integration))

#### 7. New Candidate Evaluation

```python
new_candidate = curr_prog.copy()
for pname, text in new_texts.items():
    new_candidate[pname] = text

eval_new = self.adapter.evaluate(minibatch, new_candidate, capture_traces=False)
state.total_num_evals += len(subsample_ids)
```

#### 8. Return Proposal

```python
return CandidateProposal(
    candidate=new_candidate,
    parent_program_ids=[curr_prog_id],
    subsample_indices=subsample_ids,
    subsample_scores_before=eval_curr.scores,
    subsample_scores_after=eval_new.scores,
    tag="reflective_mutation",
)
```

**Note**: The engine will later check if `sum(eval_new.scores) > sum(eval_curr.scores)` for acceptance.

---

## Merge Proposer

**File**: `/gepa/src/gepa/proposer/merge.py`

### Overview

The Merge Proposer combines successful program candidates by finding common ancestors and intelligently merging their components. This explores the space of hybrid solutions that combine strengths from multiple lineages.

### Algorithm Flow

```
1. Check Merge Conditions
   ↓
2. Find Pareto Front Dominators
   ↓
3. Find Common Ancestor Pair
   ↓
4. Merge Programs by Components
   ↓
5. Select Evaluation Subsample
   ↓
6. Evaluate Merged Candidate
   ↓
7. Return Proposal if Improved
```

### Class: MergeProposer

```python
class MergeProposer(ProposeNewCandidate[DataId]):
    def __init__(
        self,
        logger: Any,
        valset: DataLoader[DataId, DataInst],
        evaluator: Callable[[list[DataInst], dict[str, str]], tuple[list[RolloutOutput], list[float]]],
        use_merge: bool,
        max_merge_invocations: int,
        val_overlap_floor: int = 5,
        rng: random.Random | None = None,
    )
```

**Key Parameters**:
- `valset`: Validation data for subsample evaluation
- `evaluator`: Function to evaluate candidates
- `use_merge`: Toggle for merge functionality
- `max_merge_invocations`: Maximum number of merge attempts
- `val_overlap_floor`: Minimum overlapping validation examples required (default 5)

**Internal State**:
- `merges_due`: Counter scheduled by engine after finding new programs
- `total_merges_tested`: Total merge attempts
- `merges_performed`: Tuple of two lists tracking merge history
  - `merges_performed[0]`: List of `(id1, id2, ancestor)` triplets attempted
  - `merges_performed[1]`: List of `(id1, id2, prog_desc)` triplets with component sources
- `last_iter_found_new_program`: Flag set by engine

### Step-by-Step Process

#### 1. Merge Scheduling

```python
def schedule_if_needed(self):
    if self.use_merge and self.total_merges_tested < self.max_merge_invocations:
        self.merges_due += 1
```

**Called By**: Engine after accepting a new program

#### 2. Merge Conditions Check

```python
if not (self.use_merge and self.last_iter_found_new_program and self.merges_due > 0):
    return None
```

**Conditions**:
- Merge is enabled
- Last iteration found a new program
- Merge is scheduled (`merges_due > 0`)

#### 3. Find Merge Candidates

```python
pareto_front_programs = state.program_at_pareto_front_valset
merge_candidates = find_dominator_programs(
    pareto_front_programs,
    state.program_full_scores_val_set
)
```

**Process**:
1. Get all programs on Pareto front
2. Remove dominated programs (see `/gepa/src/gepa/gepa_utils.py`)
3. Return set of dominator program indices

**Domination Logic**:
- Program A dominates B if A is on the Pareto front for all examples where B is
- Dominated programs are iteratively removed until only dominators remain

#### 4. Find Common Ancestor Pair

```python
def find_common_ancestor_pair(
    rng, parent_list, program_indexes, merges_performed,
    agg_scores, program_candidates, max_attempts=10
)
```

**Algorithm**:
```
for attempt in max_attempts:
    1. Sample two programs (i, j) from merge candidates
    2. Get ancestors for each: ancestors_i, ancestors_j
    3. Check: neither is ancestor of the other
    4. Find common_ancestors = ancestors_i ∩ ancestors_j
    5. Filter ancestors:
       - Not already merged
       - Ancestor score ≤ both descendants
       - Has "desirable predictors" (see below)
    6. If filtered_ancestors non-empty:
       - Weight by scores
       - Return (i, j, selected_ancestor)
```

**Desirable Predictors Criterion**:
```python
def does_triplet_have_desirable_predictors(program_candidates, ancestor, id1, id2):
    for each component:
        if (ancestor[comp] == id1[comp] OR ancestor[comp] == id2[comp])
           AND id1[comp] != id2[comp]:
            return True  # Can merge this component
    return False
```

This ensures the triplet has at least one component where:
- One descendant changed from ancestor
- Other descendant kept ancestor's version
- We can "upgrade" ancestor with the changed version

#### 5. Validation Support Overlap Check

```python
def has_val_support_overlap(id1: ProgramIdx, id2: ProgramIdx) -> bool:
    common_ids = set(state.prog_candidate_val_subscores[id1].keys()) &
                 set(state.prog_candidate_val_subscores[id2].keys())
    return len(common_ids) >= self.val_overlap_floor
```

**Purpose**: Ensures both candidates have been evaluated on enough common validation examples to make meaningful comparisons.

#### 6. Merge Programs by Components

```python
def sample_and_attempt_merge_programs_by_common_predictors(...)
```

**Component Merge Logic**:

For each component (predictor) in the program:

```python
pred_anc = ancestor[component]
pred_id1 = id1[component]
pred_id2 = id2[component]

if (pred_anc == pred_id1 OR pred_anc == pred_id2) AND pred_id1 != pred_id2:
    # Case 1: One descendant changed, other kept ancestor
    # → Use the changed version
    same_as_ancestor_id = 1 if pred_anc == pred_id1 else 2
    new_program[component] = id2[component] if same_as_ancestor_id == 1 else id1[component]

elif pred_anc != pred_id1 AND pred_anc != pred_id2:
    # Case 2: Both descendants changed
    # → Use version from higher-scoring descendant
    if agg_scores[id1] > agg_scores[id2]:
        new_program[component] = id1[component]
    elif agg_scores[id2] > agg_scores[id1]:
        new_program[component] = id2[component]
    else:
        # Tie → random choice
        new_program[component] = random.choice([id1, id2])[component]

elif pred_id1 == pred_id2:
    # Case 3: Both descendants have same version
    # → Use either (choose id1)
    new_program[component] = id1[component]
```

**Merge Description Tracking**:
- Records which program each component came from: `new_prog_desc`
- Checks if this exact merge description was already attempted
- Skips duplicate merges

#### 7. Select Evaluation Subsample

```python
def select_eval_subsample_for_merged_program(
    self, scores1: dict[DataId, float], scores2: dict[DataId, float],
    num_subsample_ids: int = 5
) -> list[DataId]
```

**Strategy**: Stratified sampling from three buckets:
```python
common_ids = set(scores1.keys()) & set(scores2.keys())

p1 = [id for id in common_ids if scores1[id] > scores2[id]]  # id1 better
p2 = [id for id in common_ids if scores2[id] > scores1[id]]  # id2 better
p3 = [id for id in common_ids if id not in p1 and not in p2]  # tied

# Sample ~1/3 from each bucket, pad if needed
selected = sample_from_each_bucket(p1, p2, p3, n_each=ceil(5/3))
```

**Purpose**: Ensure subsample includes examples where each parent excels, to test if merge combines their strengths.

#### 8. Evaluate Merged Candidate

```python
subsample_ids = self.select_eval_subsample_for_merged_program(
    state.prog_candidate_val_subscores[id1],
    state.prog_candidate_val_subscores[id2],
)
mini_devset = self.valset.fetch(subsample_ids)

id1_sub_scores = [state.prog_candidate_val_subscores[id1][k] for k in subsample_ids]
id2_sub_scores = [state.prog_candidate_val_subscores[id2][k] for k in subsample_ids]

_, new_sub_scores = self.evaluator(mini_devset, new_program)
state.total_num_evals += len(subsample_ids)
```

#### 9. Return Proposal

```python
return CandidateProposal(
    candidate=new_program,
    parent_program_ids=[id1, id2],
    subsample_indices=subsample_ids,
    subsample_scores_before=[sum(id1_sub_scores), sum(id2_sub_scores)],
    subsample_scores_after=new_sub_scores,
    tag="merge",
    metadata={"ancestor": ancestor},
)
```

**Acceptance Criteria** (evaluated by engine):
```python
sum(new_sub_scores) >= max(sum(id1_sub_scores), sum(id2_sub_scores))
```

---

## Supporting Components

### Protocol Definitions

**File**: `/gepa/src/gepa/proposer/reflective_mutation/base.py`

#### CandidateSelector

```python
class CandidateSelector(Protocol):
    def select_candidate_idx(self, state: GEPAState) -> int: ...
```

Selects which program candidate to mutate next.

#### ReflectionComponentSelector

```python
class ReflectionComponentSelector(Protocol):
    def __call__(
        self,
        state: GEPAState,
        trajectories: list[Trajectory],
        subsample_scores: list[float],
        candidate_idx: int,
        candidate: dict[str, str],
    ) -> list[str]: ...
```

Selects which components (predictors) of the program to update.

#### LanguageModel

```python
class LanguageModel(Protocol):
    def __call__(self, prompt: str) -> str: ...
```

LLM interface for instruction proposal.

#### Signature

```python
@dataclass
class Signature:
    prompt_template: str
    input_keys: list[str]
    output_keys: list[str]
    prompt_renderer: Callable[[dict[str, str]], str]
    output_extractor: Callable[[str], dict[str, str]]

    @classmethod
    def run(cls, lm: LanguageModel, input_dict: dict[str, str]) -> dict[str, str]:
        full_prompt = cls.prompt_renderer(input_dict)
        lm_out = lm(full_prompt).strip()
        return cls.output_extractor(lm_out)
```

Generic pattern for LLM prompting with structured input/output.

---

## Mutation Algorithms

### Reflective Mutation Algorithm

**High-Level**:
1. Execute program on examples
2. Capture failure cases and successes
3. Analyze what went wrong/right
4. Generate improved instruction
5. Validate improvement

**Key Insight**: Uses execution feedback to guide mutations, not random perturbation.

### Merge Algorithm

**High-Level**:
1. Find successful programs with common lineage
2. Identify components where one improved over ancestor
3. Combine improvements into single program
4. Test if combination is better than both parents

**Key Insight**: Exploits genealogy to recombine proven improvements.

### Pareto Front Management

**File**: `/gepa/src/gepa/gepa_utils.py`

Programs are evaluated on multiple validation examples, creating a multi-objective optimization problem.

**Pareto Front**:
- For each validation example, track best score and programs achieving it
- `pareto_front_valset: dict[DataId, float]` - best score per example
- `program_at_pareto_front_valset: dict[DataId, set[ProgramIdx]]` - programs at front

**Domination**:
```python
def is_dominated(y, programs, program_at_pareto_front_valset):
    # y is dominated if for every example where y is on the front,
    # there exists another program in `programs` also on that front
    for each front where y appears:
        if no other program from `programs` is in that front:
            return False  # y is not dominated
    return True
```

**Finding Dominators**:
```python
def remove_dominated_programs(program_at_pareto_front_valset, scores):
    # Iteratively remove dominated programs
    # Lower-scoring programs checked first
    programs = sorted(programs, key=scores)
    for y in programs:
        if is_dominated(y, other_programs, fronts):
            remove y
```

---

## Reflection Mechanisms

### Execution Trace Capture

**Adapter Responsibility**:
```python
eval_result = adapter.evaluate(minibatch, candidate, capture_traces=True)
# Returns EvaluationBatch with trajectories
```

**Trajectory**: User-defined type capturing:
- Intermediate computation steps
- Model inputs/outputs at each step
- Errors or failures
- Anything needed for reflection

**Example** (hypothetical for a QA system):
```python
@dataclass
class QATrajectory:
    question: str
    retrieved_docs: list[str]
    reasoning: str
    answer: str
    correct_answer: str
    score: float
    error_message: str | None
```

### Reflective Dataset Construction

**Adapter Responsibility**:
```python
reflective_dataset = adapter.make_reflective_dataset(
    candidate, eval_batch, components_to_update
)
```

**Output Format**:
```python
{
    "component_name": [
        {
            "Inputs": {...},           # Clean view of inputs
            "Generated Outputs": {...}, # What the component produced
            "Feedback": "..."          # What went wrong / how to improve
        },
        ...
    ]
}
```

**Design Principles**:
1. **Concise**: Only essential information for improvement
2. **Actionable**: Feedback should clearly indicate what to fix
3. **Deterministic**: Use seeded sampling if subsampling traces
4. **JSON-Serializable**: Must be embeddable in prompt

### Feedback Generation

**User's Responsibility**: In `make_reflective_dataset`, generate feedback by:

1. **Error Analysis**: Identify parsing errors, format issues, logic errors
2. **Correctness**: Compare outputs to ground truth
3. **Task-Specific Criteria**: Apply domain knowledge
4. **Explanation**: Provide clear, actionable guidance

**Example**:
```python
def make_reflective_dataset(self, candidate, eval_batch, components_to_update):
    dataset = {name: [] for name in components_to_update}

    for traj, score in zip(eval_batch.trajectories, eval_batch.scores):
        if score < perfect_score:
            feedback = generate_feedback(traj)  # User-defined
            for component in components_to_update:
                dataset[component].append({
                    "Inputs": extract_inputs(traj, component),
                    "Generated Outputs": extract_outputs(traj, component),
                    "Feedback": feedback
                })

    return dataset
```

---

## LLM Integration

### InstructionProposalSignature

**File**: `/gepa/src/gepa/strategies/instruction_proposal.py`

This is the default implementation for generating new instructions using an LLM.

#### Default Prompt Template

```
I provided an assistant with the following instructions to perform a task for me:
```
<curr_instructions>
```

The following are examples of different task inputs provided to the assistant
along with the assistant's response for each of them, and some feedback on how
the assistant's response could be better:
```
<inputs_outputs_feedback>
```

Your task is to write a new instruction for the assistant.

Read the inputs carefully and identify the input format and infer detailed task
description about the task I wish to solve with the assistant.

Read all the assistant responses and the corresponding feedback. Identify all
niche and domain specific factual information about the task and include it in
the instruction, as a lot of it may not be available to the assistant in the future.
The assistant may have utilized a generalizable strategy to solve the task, if so,
include that in the instruction as well.

Provide the new instructions within ``` blocks.
```

#### Prompt Rendering

**Markdown Formatting**:
```python
def format_samples(samples):
    # Converts list of dicts to markdown
    # Each sample becomes:
    # # Example 1
    # ## Inputs
    # ### key1
    # value1
    # ## Generated Outputs
    # ...
    # ## Feedback
    # ...
```

**Template Substitution**:
```python
prompt = template.replace("<curr_instructions>", current_instruction)
prompt = prompt.replace("<inputs_outputs_feedback>", format_samples(dataset))
```

#### Output Extraction

```python
def output_extractor(lm_out: str) -> dict[str, str]:
    # Extract text within ``` blocks
    # Handles incomplete blocks gracefully
    # Strips language specifiers (e.g., ```python)
    return {"new_instruction": extracted_text}
```

**Robustness**:
- Handles missing closing ```
- Handles missing opening ```
- Handles language specifiers after opening ```

### Custom Proposal Functions

Users can override with `adapter.propose_new_texts`:

```python
class CustomAdapter:
    def propose_new_texts(
        self,
        candidate: dict[str, str],
        reflective_dataset: dict[str, list[dict[str, Any]]],
        components_to_update: list[str]
    ) -> dict[str, str]:
        # Custom LLM interaction
        # Could use DSPy, LangChain, etc.
        # Could update multiple components jointly
        return {name: new_text for name in components_to_update}
```

---

## GEPAAdapter Protocol

**File**: `/gepa/src/gepa/core/adapter.py`

The adapter is the integration point between GEPA and the user's system.

### Required Methods

#### evaluate

```python
def evaluate(
    self,
    batch: list[DataInst],
    candidate: dict[str, str],
    capture_traces: bool = False,
) -> EvaluationBatch[Trajectory, RolloutOutput]
```

**Responsibilities**:
1. Instantiate program from candidate (component texts)
2. Execute on batch
3. Compute per-example scores
4. Optionally capture trajectories

**Returns**:
```python
@dataclass
class EvaluationBatch:
    outputs: list[RolloutOutput]  # Raw outputs (opaque to GEPA)
    scores: list[float]           # Per-example scores (higher is better)
    trajectories: list[Trajectory] | None  # If capture_traces=True
```

**Scoring Semantics**:
- GEPA uses `sum(scores)` for minibatch acceptance
- GEPA uses `mean(scores)` for full validation tracking
- Higher is better
- Failed examples should have low score (e.g., 0.0)

**Error Handling**:
- Don't raise for individual example failures
- Return valid EvaluationBatch with failure scores
- Populate trajectory with error information if possible
- Only raise for systemic failures (misconfiguration, missing model, etc.)

#### make_reflective_dataset

```python
def make_reflective_dataset(
    self,
    candidate: dict[str, str],
    eval_batch: EvaluationBatch[Trajectory, RolloutOutput],
    components_to_update: list[str],
) -> dict[str, list[dict[str, Any]]]
```

**Responsibilities**:
1. Extract relevant information from trajectories
2. Generate feedback for each component
3. Create JSON-serializable dataset

**Returns**: `dict[component_name -> list of example dicts]`

**Recommended Schema**:
```python
{
    "Inputs": {...},              # Minimal inputs to component
    "Generated Outputs": {...},   # What component produced
    "Feedback": "..."             # Actionable improvement guidance
}
```

#### propose_new_texts (optional)

```python
propose_new_texts: ProposalFn | None = None
```

If provided, overrides default LLM-based proposal.

---

## GEPAState

**File**: `/gepa/src/gepa/core/state.py`

The state tracks the entire optimization history.

### Key Fields

```python
class GEPAState:
    # All program candidates discovered
    program_candidates: list[dict[str, str]]

    # Parent relationships (genealogy)
    parent_program_for_candidate: list[list[ProgramIdx | None]]

    # Sparse validation scores (only evaluated examples)
    prog_candidate_val_subscores: list[dict[DataId, float]]

    # Pareto front tracking
    pareto_front_valset: dict[DataId, float]
    program_at_pareto_front_valset: dict[DataId, set[ProgramIdx]]

    # Component management
    list_of_named_predictors: list[str]
    named_predictor_id_to_update_next_for_program_candidate: list[int]

    # Iteration tracking
    i: int                    # Current iteration
    num_full_ds_evals: int    # Full dataset evaluations
    total_num_evals: int      # Total example evaluations

    # Logging
    full_program_trace: list  # Detailed execution trace

    # Optional output tracking
    best_outputs_valset: dict[DataId, list[tuple[ProgramIdx, RolloutOutput]]] | None
```

### Sparse Validation

**Key Design**: Not all programs are evaluated on all validation examples.

- `prog_candidate_val_subscores[prog_idx]` is a `dict[DataId, float]`
- Only contains scores for examples the program was evaluated on
- Aggregate score: `mean(scores)` over evaluated examples

**Benefits**:
- Saves computation
- Enables progressive evaluation strategies
- Allows targeted evaluation on difficult examples

### Pareto Front Updates

```python
def _update_pareto_front_for_val_id(
    self, val_id: DataId, score: float, program_idx: ProgramIdx,
    output: RolloutOutput | None, run_dir: str | None, iteration: int
):
    prev_score = self.pareto_front_valset.get(val_id, float("-inf"))

    if score > prev_score:
        # New best score for this example
        self.pareto_front_valset[val_id] = score
        self.program_at_pareto_front_valset[val_id] = {program_idx}
        if self.best_outputs_valset is not None:
            self.best_outputs_valset[val_id] = [(program_idx, output)]

    elif score == prev_score:
        # Tied for best score
        self.program_at_pareto_front_valset[val_id].add(program_idx)
        if self.best_outputs_valset is not None:
            self.best_outputs_valset[val_id].append((program_idx, output))
```

### Adding New Programs

```python
def update_state_with_new_program(
    self,
    parent_program_idx: list[ProgramIdx],
    new_program: dict[str, str],
    valset_subscores: dict[DataId, float],
    valset_outputs: dict[DataId, RolloutOutput] | None,
    run_dir: str | None,
    num_metric_calls_by_discovery_of_new_program: int,
) -> ProgramIdx
```

**Process**:
1. Append to `program_candidates`
2. Record parent relationships
3. Add validation subscores
4. Update Pareto fronts for all evaluated examples
5. Return new program index

---

## Elixir Port Considerations

### Functional Paradigm Shift

#### State Management

**Python**: Mutable state object passed around
```python
state.program_candidates.append(new_program)
state.total_num_evals += len(batch)
```

**Elixir**: Immutable state updates
```elixir
state = %State{state |
  program_candidates: [new_program | state.program_candidates],
  total_num_evals: state.total_num_evals + length(batch)
}
```

**Recommendation**: Use a `State` struct with explicit updates returned from functions.

#### Protocol vs Behavior

**Python**: Protocols with runtime checking
```python
class ProposeNewCandidate(Protocol[DataId]):
    def propose(self, state: GEPAState) -> CandidateProposal | None: ...
```

**Elixir**: Behaviours with compile-time checking
```elixir
defmodule GEPA.Proposer do
  @callback propose(State.t()) :: {:ok, CandidateProposal.t()} | :none
end
```

**Recommendation**: Define behaviours for `Proposer`, `CandidateSelector`, `BatchSampler`, `Adapter`.

### Concurrency and Processes

#### Parallel Evaluation Opportunities

1. **Batch Evaluation**: Map-reduce across examples
```elixir
scores = batch
|> Task.async_stream(&evaluate_example(&1, candidate))
|> Enum.map(fn {:ok, score} -> score end)
```

2. **Multiple Proposals**: Run reflective mutation and merge in parallel
```elixir
proposals = [
  Task.async(fn -> ReflectiveMutation.propose(state) end),
  Task.async(fn -> MergeProposer.propose(state) end)
]
|> Enum.map(&Task.await/1)
|> Enum.reject(&is_nil/1)
```

3. **Validation Evaluation**: Parallel per-example evaluation
```elixir
def evaluate_on_validation(candidate, valset) do
  valset
  |> Task.async_stream(fn {id, example} ->
    {id, evaluate_single(example, candidate)}
  end, max_concurrency: System.schedulers_online())
  |> Enum.into(%{})
end
```

#### Process Architecture Options

**Option 1: Functional Pipeline** (Recommended for initial port)
```elixir
# Stateless functions, state passed explicitly
def run_iteration(state, proposers) do
  state
  |> select_proposer(proposers)
  |> generate_proposal()
  |> evaluate_proposal()
  |> maybe_accept()
end
```

**Option 2: GenServer for State Management**
```elixir
defmodule GEPA.Optimizer do
  use GenServer

  def handle_call(:propose, _from, state) do
    case ReflectiveMutation.propose(state) do
      {:ok, proposal} ->
        new_state = accept_proposal(state, proposal)
        {:reply, proposal, new_state}
      :none ->
        {:reply, :none, state}
    end
  end
end
```

**Option 3: Supervised Task Tree**
```elixir
# Supervisor manages long-running optimization
# Workers handle evaluation tasks
# State stored in ETS or persistent storage
```

**Recommendation**: Start with Option 1, add concurrency incrementally.

### Data Structures

#### Program Candidates

**Python**: `dict[str, str]`
```python
candidate = {
    "predictor1": "instruction text 1",
    "predictor2": "instruction text 2"
}
```

**Elixir**: Map or struct
```elixir
# Option 1: Plain map
candidate = %{
  "predictor1" => "instruction text 1",
  "predictor2" => "instruction text 2"
}

# Option 2: Struct with dynamic components
defmodule Candidate do
  defstruct components: %{}
end

candidate = %Candidate{
  components: %{
    "predictor1" => "instruction text 1",
    "predictor2" => "instruction text 2"
  }
}
```

**Recommendation**: Use plain map for flexibility, wrap in struct if type safety needed.

#### Sparse Validation Scores

**Python**: `list[dict[DataId, float]]`
```python
prog_candidate_val_subscores = [
    {0: 1.0, 5: 0.8, 10: 0.9},  # Program 0 scores
    {0: 0.9, 5: 1.0, 12: 0.7},  # Program 1 scores
]
```

**Elixir**: List of maps
```elixir
prog_candidate_val_subscores = [
  %{0 => 1.0, 5 => 0.8, 10 => 0.9},  # Program 0 scores
  %{0 => 0.9, 5 => 1.0, 12 => 0.7}   # Program 1 scores
]
```

**Consideration**: Use ETS table for large state if memory becomes an issue.

#### Pareto Front

**Python**: `dict[DataId, set[ProgramIdx]]`
```python
program_at_pareto_front_valset = {
    0: {0, 3, 5},
    1: {2, 4},
}
```

**Elixir**: Map with MapSet values
```elixir
program_at_pareto_front_valset = %{
  0 => MapSet.new([0, 3, 5]),
  1 => MapSet.new([2, 4])
}
```

### Random Number Generation

**Python**: `random.Random(seed)` with instance state
```python
rng = random.Random(42)
rng.sample([1,2,3,4], k=2)
```

**Elixir**: `:rand` module with explicit seed state
```elixir
# Initialize
seed = :rand.seed(:exsss, {42, 42, 42})

# Use
{value, new_seed} = :rand.uniform_s(seed)

# Or use process dictionary (not recommended for pure functions)
:rand.seed(:exsss, {42, 42, 42})
value = :rand.uniform()
```

**Recommendation**: Pass seed state explicitly through function calls for determinism.

### LLM Integration

**Python**: Simple callable protocol
```python
class LanguageModel(Protocol):
    def __call__(self, prompt: str) -> str: ...
```

**Elixir**: Behavior with async support
```elixir
defmodule GEPA.LanguageModel do
  @callback generate(prompt :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback generate_async(prompt :: String.t()) :: Task.t()
end

# Example implementation
defmodule MyLM do
  @behaviour GEPA.LanguageModel

  def generate(prompt) do
    # HTTP call to LLM API
    {:ok, response}
  end

  def generate_async(prompt) do
    Task.async(fn -> generate(prompt) end)
  end
end
```

**Considerations**:
- HTTP client: Use `Req` or `Finch`
- Retries and backoff: Use `Retry` library
- Rate limiting: Use `Hammer` or custom GenServer
- Caching: Use `Cachex` for prompt/response memoization

### Error Handling

**Python**: Exceptions with try/catch
```python
try:
    reflective_dataset = self.adapter.make_reflective_dataset(...)
    new_texts = self.propose_new_texts(...)
except Exception as e:
    self.logger.log(f"Exception during reflection: {e}")
    return None
```

**Elixir**: Tagged tuples and pattern matching
```elixir
case Adapter.make_reflective_dataset(adapter, curr_prog, eval_batch, components) do
  {:ok, reflective_dataset} ->
    case propose_new_texts(curr_prog, reflective_dataset, components) do
      {:ok, new_texts} ->
        # Continue
      {:error, reason} ->
        Logger.error("Failed to propose new texts: #{inspect(reason)}")
        :none
    end
  {:error, reason} ->
    Logger.error("Failed to create reflective dataset: #{inspect(reason)}")
    :none
end

# Or use `with` for cleaner chaining
with {:ok, reflective_dataset} <- Adapter.make_reflective_dataset(...),
     {:ok, new_texts} <- propose_new_texts(...),
     {:ok, new_eval} <- Adapter.evaluate(...) do
  {:ok, %CandidateProposal{...}}
else
  {:error, reason} ->
    Logger.error("Proposal failed: #{inspect(reason)}")
    :none
end
```

**Recommendation**: Use `{:ok, result}` / `{:error, reason}` convention with `with` for pipelines.

### Adapter Design

**Python**: Protocol with optional method
```python
class GEPAAdapter(Protocol[DataInst, Trajectory, RolloutOutput]):
    def evaluate(...) -> EvaluationBatch: ...
    def make_reflective_dataset(...) -> dict: ...
    propose_new_texts: ProposalFn | None = None
```

**Elixir**: Behavior with optional callback
```elixir
defmodule GEPA.Adapter do
  @callback evaluate(batch, candidate, capture_traces?) ::
    {:ok, EvaluationBatch.t()} | {:error, term()}

  @callback make_reflective_dataset(candidate, eval_batch, components) ::
    {:ok, map()} | {:error, term()}

  @callback propose_new_texts(candidate, reflective_dataset, components) ::
    {:ok, map()} | {:error, term()}

  @optional_callbacks [propose_new_texts: 3]
end

# Check if optional callback is defined
defmodule Proposer do
  def propose_new_texts(adapter, ...) do
    if function_exported?(adapter, :propose_new_texts, 3) do
      adapter.propose_new_texts(...)
    else
      InstructionProposal.run(...)  # Default implementation
    end
  end
end
```

### Testing Strategy

#### Unit Tests

1. **Pure Functions**: Easy to test
```elixir
test "merge logic selects correct components" do
  ancestor = %{"comp1" => "v1", "comp2" => "v2"}
  id1 = %{"comp1" => "v1", "comp2" => "v3"}
  id2 = %{"comp1" => "v4", "comp2" => "v2"}

  result = MergeProposer.merge_programs(ancestor, id1, id2, scores)

  assert result["comp1"] == "v4"  # id1 changed, use id2
  assert result["comp2"] == "v3"  # id2 changed, use id1
end
```

2. **Stateful Operations**: Test state transformations
```elixir
test "adding program updates pareto front" do
  state = initial_state()
  new_program = %{"comp" => "improved"}
  scores = %{0 => 1.0, 1 => 0.9}  # Better than initial

  new_state = State.add_program(state, new_program, [0], scores)

  assert length(new_state.program_candidates) == 2
  assert new_state.pareto_front_valset[0] == 1.0
  assert 1 in new_state.program_at_pareto_front_valset[0]
end
```

3. **Property-Based Testing**: Use StreamData
```elixir
property "pareto front only contains non-dominated programs" do
  check all programs <- list_of(program_generator()),
            scores <- list_of(score_map_generator()),
            max_runs: 100 do

    state = build_state(programs, scores)
    front = state.program_at_pareto_front_valset

    # Property: no program on front is dominated by another
    for {_id, front_programs} <- front do
      assert Enum.all?(front_programs, fn prog ->
        !is_dominated?(prog, front_programs -- [prog], state)
      end)
    end
  end
end
```

#### Integration Tests

1. **Mock Adapters**: Test proposers with predictable behavior
```elixir
defmodule MockAdapter do
  @behaviour GEPA.Adapter

  def evaluate(batch, candidate, _capture_traces) do
    # Return fixed scores based on candidate
    {:ok, %EvaluationBatch{
      scores: Enum.map(batch, fn _ -> score_for(candidate) end),
      outputs: [],
      trajectories: nil
    }}
  end
end
```

2. **End-to-End Tests**: Small toy problem
```elixir
test "optimization improves toy problem" do
  adapter = ToyAdapter.new()
  proposer = ReflectiveMutation.new(adapter, ...)
  state = State.init(seed_candidate, valset)

  final_state = Enum.reduce(1..10, state, fn _i, s ->
    case proposer.propose(s) do
      {:ok, proposal} -> maybe_accept(s, proposal)
      :none -> s
    end
  end)

  best_score = final_state |> State.best_program_score()
  initial_score = state |> State.best_program_score()

  assert best_score > initial_score
end
```

### Persistence and Serialization

**Python**: Pickle for state
```python
with open("gepa_state.bin", "wb") as f:
    pickle.dump(state.__dict__, f)
```

**Elixir**: ETF (Erlang Term Format) or JSON
```elixir
# Option 1: ETF (preserves Elixir types)
File.write!("gepa_state.bin", :erlang.term_to_binary(state))
state = :erlang.binary_to_term(File.read!("gepa_state.bin"))

# Option 2: JSON (human-readable, language-agnostic)
json = Jason.encode!(state)
File.write!("gepa_state.json", json)
state = File.read!("gepa_state.json") |> Jason.decode!()

# Option 3: Custom serialization with versioning
defmodule State.Serializer do
  def serialize(state) do
    %{
      version: 2,
      program_candidates: state.program_candidates,
      # ... other fields
    }
  end

  def deserialize(%{"version" => 2} = data) do
    # Latest version
    %State{
      program_candidates: data["program_candidates"],
      # ...
    }
  end

  def deserialize(%{"version" => 1} = data) do
    # Migrate from v1
    migrate_v1_to_v2(data) |> deserialize()
  end
end
```

**Recommendation**: Use ETF for snapshots during optimization, JSON for final results and debugging.

### Logging and Observability

**Python**: Logger passed to constructors
```python
self.logger.log(f"Iteration {i}: Selected program {curr_prog_id}")
```

**Elixir**: Structured logging with metadata
```elixir
Logger.info("Selected program",
  iteration: i,
  program_id: curr_prog_id,
  score: score
)

# Or use Logger metadata for context
Logger.metadata(iteration: i, proposer: :reflective_mutation)
Logger.info("Selected program #{curr_prog_id}")
```

**Telemetry**: Add instrumentation for metrics
```elixir
:telemetry.execute(
  [:gepa, :proposal, :complete],
  %{duration: duration, evaluations: num_evals},
  %{proposer: :reflective_mutation, accepted: true}
)

# Attach handlers for metrics collection
:telemetry.attach(
  "gepa-metrics",
  [:gepa, :proposal, :complete],
  &MetricsHandler.handle_event/4,
  nil
)
```

**Recommendation**: Use `Logger` for human-readable logs, `:telemetry` for metrics and monitoring.

### Performance Considerations

#### Bottlenecks

1. **LLM Calls**: Dominant cost
   - **Mitigation**: Cache prompts/responses, batch when possible

2. **Evaluation**: Can be expensive depending on task
   - **Mitigation**: Parallel execution via `Task.async_stream`

3. **State Updates**: Frequent copies of large data structures
   - **Mitigation**: Use ETS for large collections, only copy what changes

#### Memory Management

**Python**: Garbage collected, can accumulate large state
**Elixir**: Garbage collected per-process, immutable data shared

**Recommendations**:
1. Use `:ets` tables for large lookup structures (Pareto fronts, scores)
2. Use `:persistent_term` for read-heavy, rarely-updated data
3. Consider binary-based representations for large text fields
4. Periodically checkpoint and restart optimization process to reclaim memory

#### Optimization Opportunities

1. **Lazy Evaluation**: Don't compute scores until needed
```elixir
defmodule LazyScores do
  defstruct [:compute_fn, :cache]

  def get(lazy, key) do
    case Map.fetch(lazy.cache, key) do
      {:ok, value} -> value
      :error ->
        value = lazy.compute_fn.(key)
        cache = Map.put(lazy.cache, key, value)
        {value, %{lazy | cache: cache}}
    end
  end
end
```

2. **Incremental Updates**: Only recompute affected parts
```elixir
# When adding a new program, only update Pareto fronts for evaluated examples
def add_program(state, new_program, scores) do
  # Only update fronts for examples in `scores`, not all examples
  new_fronts = Enum.reduce(scores, state.fronts, fn {id, score}, fronts ->
    update_front_for_id(fronts, id, score, new_program_idx)
  end)

  %{state | fronts: new_fronts}
end
```

3. **Structural Sharing**: Leverage Elixir's immutable data structures
```elixir
# Prepending is O(1) and shares tail
new_candidates = [new_program | state.program_candidates]

# Updating map is O(log n) and shares most of structure
new_scores = Map.put(state.scores, new_id, score)
```

### Module Organization

Suggested structure:

```
lib/gepa/
├── core/
│   ├── state.ex                 # GEPAState struct and functions
│   ├── adapter.ex               # Adapter behaviour
│   ├── data_loader.ex           # DataLoader protocol
│   └── types.ex                 # Shared types (CandidateProposal, etc.)
├── proposer/
│   ├── proposer.ex              # Proposer behaviour
│   ├── reflective_mutation/
│   │   ├── reflective_mutation.ex
│   │   └── base.ex              # Protocols (CandidateSelector, etc.)
│   └── merge.ex                 # MergeProposer
├── strategies/
│   ├── batch_sampler.ex
│   ├── candidate_selector.ex
│   ├── component_selector.ex
│   └── instruction_proposal.ex
├── utils/
│   ├── pareto.ex                # Pareto front utilities
│   └── random.ex                # RNG helpers
└── engine.ex                    # Main optimization loop
```

### Configuration

**Python**: Constructor arguments
```python
proposer = ReflectiveMutationProposer(
    logger=logger,
    trainset=trainset,
    adapter=adapter,
    # ... many more parameters
)
```

**Elixir**: Keyword lists or application config
```elixir
# Option 1: Keyword lists
proposer = ReflectiveMutation.new(
  logger: Logger,
  trainset: trainset,
  adapter: MyAdapter,
  candidate_selector: ParetoCandidateSelector.new(),
  # ...
)

# Option 2: Application config
config :gepa,
  perfect_score: 1.0,
  skip_perfect_score: true,
  max_merge_invocations: 10

# Option 3: Struct with defaults
defmodule GEPA.Config do
  defstruct [
    perfect_score: 1.0,
    skip_perfect_score: true,
    max_merge_invocations: 10,
    # ...
  ]
end

config = %GEPA.Config{}
proposer = ReflectiveMutation.new(config, adapter: MyAdapter)
```

**Recommendation**: Use keyword lists for flexibility, with a config struct for validation and defaults.

---

## Summary

The GEPA Proposer System consists of two main strategies:

### Reflective Mutation
- Selects a candidate from Pareto front
- Evaluates on training minibatch with trace capture
- Builds reflective dataset with execution feedback
- Uses LLM to propose improved instructions
- Evaluates new candidate on same minibatch
- Returns proposal if improved

### Merge
- Finds programs on Pareto front
- Removes dominated programs to get dominators
- Samples two programs with common ancestor
- Merges components intelligently based on lineage
- Evaluates on stratified validation subsample
- Returns proposal if better than both parents

### Key Design Patterns for Elixir Port
1. **Immutable State**: Pass state explicitly, return updated state
2. **Behaviours**: Define behaviours for Proposer, Adapter, CandidateSelector, etc.
3. **Tagged Tuples**: Use `{:ok, result}` / `{:error, reason}` / `:none`
4. **Concurrency**: Leverage `Task.async_stream` for parallel evaluation
5. **Functional Composition**: Pipeline state through transformations
6. **Explicit Dependencies**: Pass all dependencies (LM, adapter, selectors) explicitly
7. **Deterministic Randomness**: Thread RNG seed state explicitly
8. **Telemetry**: Instrument for observability

### Critical Algorithms to Implement
1. **Pareto front management**: Domination checking, front updates
2. **Common ancestor finding**: Genealogy traversal with filtering
3. **Component merging**: Three-way merge logic (ancestor + two descendants)
4. **Reflective dataset construction**: User-defined in adapter
5. **Instruction proposal**: LLM prompting with markdown formatting
6. **Subsample selection**: Stratified sampling for merge evaluation

### User Extension Points
1. **Adapter**: Evaluation, reflection, optional custom proposal
2. **CandidateSelector**: Which program to mutate
3. **ComponentSelector**: Which components to update
4. **BatchSampler**: Minibatch sampling strategy
5. **LanguageModel**: LLM integration
6. **Prompt Template**: Custom reflection prompts

This system is designed for flexibility and extensibility while maintaining a clean separation between the core optimization logic and domain-specific task logic (captured in the Adapter).
