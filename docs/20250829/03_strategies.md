# GEPA Optimization Strategies

## Overview

The GEPA strategy system provides a flexible, composable framework for controlling optimization behavior across multiple dimensions. These strategies define how the optimizer samples data, selects candidates for mutation, chooses components to optimize, evaluates performance, and proposes new instructions.

### Strategy Architecture

The strategy system is built around **Protocol-based composition**, allowing different strategies to be mixed and matched:

1. **BatchSampler** - Controls training data sampling and batching
2. **CandidateSelector** - Selects which program candidate to mutate
3. **ComponentSelector** - Chooses which components (predictors) to update
4. **EvaluationPolicy** - Determines validation evaluation strategy
5. **InstructionProposal** - Generates new instruction proposals via LM

All strategies follow the Protocol pattern in Python, enabling polymorphism without inheritance. This is particularly well-suited for Elixir's behaviour system.

---

## 1. Batch Sampling Strategy

**File:** `/home/home/p/g/n/gepa_ex/gepa/src/gepa/strategies/batch_sampler.py`

### Purpose

Controls how training data is sampled and organized into mini-batches for optimization. Ensures deterministic, reproducible batch generation across optimization iterations.

### Protocol Definition

```python
class BatchSampler(Protocol[DataId, DataInst]):
    def next_minibatch_ids(
        self,
        loader: DataLoader[DataId, DataInst],
        state: GEPAState
    ) -> list[DataId]: ...
```

### Implementation: EpochShuffledBatchSampler

The primary implementation mirrors traditional deep learning batching logic:

#### Key Features

1. **Epoch-based shuffling** - Shuffles all data IDs at the start of each epoch
2. **Deterministic RNG** - Uses `state.rng1` for reproducibility
3. **Padding to minibatch size** - Pads incomplete batches with least-frequent samples
4. **Stateful tracking** - Maintains epoch counter, shuffled order, and frequency counts

#### Algorithm

```
1. Check if refresh needed:
   - First access (epoch == -1)
   - Training set size changed
   - New epoch started (based on iteration index)

2. If refresh needed:
   a. Get all training IDs from loader
   b. Shuffle IDs using RNG
   c. Calculate padding needed: (minibatch_size - len(ids) % minibatch_size)
   d. Pad with least-frequent IDs (maintains frequency balance)
   e. Update frequency counter

3. Calculate batch index:
   - base_idx = state.i * minibatch_size
   - Wrap around using modulo: base_idx % len(shuffled_ids)
   - Return slice: shuffled_ids[base_idx : base_idx + minibatch_size]
```

#### Padding Strategy

The padding mechanism ensures:
- All batches are exactly `minibatch_size`
- Padded IDs are those seen least frequently (most_common()[::-1][0][0])
- Maintains approximate uniform sampling distribution

#### State Management

```python
self.minibatch_size: int           # Fixed batch size
self.shuffled_ids: list[DataId]    # Current epoch's shuffled order
self.epoch: int                     # Current epoch number (-1 initially)
self.id_freqs: Counter             # Frequency count per ID
self.last_trainset_size: int       # Detect dataset size changes
self.rng: random.Random            # Deterministic RNG
```

### Elixir Port Considerations

1. **Immutable state** - The mutable state (shuffled_ids, epoch, id_freqs) should be part of the BatchSampler struct in Elixir, returned as updated state
2. **Random number generation** - Use Erlang's `:rand` module with seeded state passed through
3. **Padding efficiency** - Consider using `Enum.frequencies/1` for frequency counting
4. **Pattern matching** - The refresh logic can be elegantly expressed with pattern matching on state conditions

**Elixir Structure:**
```elixir
defmodule GEPA.Strategies.BatchSampler do
  @callback next_minibatch_ids(
    loader :: DataLoader.t(),
    state :: GEPAState.t(),
    sampler_state :: term()
  ) :: {list(data_id()), term()}
end

defmodule GEPA.Strategies.EpochShuffledBatchSampler do
  defstruct [
    :minibatch_size,
    :shuffled_ids,
    :epoch,
    :id_freqs,
    :last_trainset_size,
    :rng_state
  ]

  # Returns {batch_ids, updated_sampler_state}
end
```

---

## 2. Candidate Selection Strategy

**File:** `/home/home/p/g/n/gepa_ex/gepa/src/gepa/strategies/candidate_selector.py`

### Purpose

Determines which program candidate to select for mutation in the next optimization iteration. Critical for balancing exploration vs. exploitation.

### Protocol Definition

```python
class CandidateSelector(Protocol):
    def select_candidate_idx(self, state: GEPAState) -> int: ...
```

### Implementation 1: ParetoCandidateSelector

**The core selection strategy based on Pareto optimality.**

#### Key Concept: Pareto Front

A program candidate is on the **Pareto front** for a validation example if no other program performs strictly better on that example. The Pareto front represents the set of non-dominated solutions.

#### Algorithm

```
1. Get Pareto front data from state:
   - program_at_pareto_front_valset: dict[DataId, set[ProgramIdx]]
   - program_full_scores_val_set: list[float]

2. Call select_program_candidate_from_pareto_front():
   a. Remove dominated programs (see Pareto Optimization section)
   b. Count frequency of each program in Pareto fronts
   c. Build weighted sampling list (each program appears freq times)
   d. Randomly sample from weighted list using RNG

3. Return selected program index
```

#### Why Pareto-Based Selection?

- **Multi-objective** - Some programs may excel on certain examples but fail on others
- **Diversity preservation** - Maintains multiple viable solutions
- **Adaptive exploration** - Programs on more fronts are sampled more frequently

#### Frequency-Weighted Sampling

The key insight: A program appearing in Pareto fronts for many validation examples is more promising. The weighted sampling naturally prioritizes these:

```python
program_frequency_in_validation_pareto_front = {}
for testcase_pareto_front in pareto_fronts.values():
    for prog_idx in testcase_pareto_front:
        program_frequency[prog_idx] += 1

# Build sampling list with repetition based on frequency
sampling_list = [
    prog_idx
    for prog_idx, freq in program_frequency.items()
    for _ in range(freq)
]

return rng.choice(sampling_list)
```

### Implementation 2: CurrentBestCandidateSelector

**Greedy selection strategy - always picks highest scoring candidate.**

#### Algorithm

```python
def select_candidate_idx(self, state: GEPAState) -> int:
    return idxmax(state.program_full_scores_val_set)
```

Simply returns the index of the maximum value in the validation scores list.

#### Use Cases

- Pure exploitation
- Final refinement phase
- Benchmarking baseline

### Implementation 3: EpsilonGreedyCandidateSelector

**Balances exploration and exploitation with epsilon-greedy strategy.**

#### Algorithm

```
1. Generate random number: r = rng.random()
2. If r < epsilon:
     Return random candidate index (exploration)
   Else:
     Return best candidate index (exploitation)
```

#### Parameters

- `epsilon: float` - Exploration probability (0.0 to 1.0)
- `rng: random.Random` - Deterministic RNG

#### Use Cases

- Early optimization (high epsilon ~0.3)
- Gradual annealing (decrease epsilon over time)
- Breaking out of local optima

### Elixir Port Considerations

1. **Protocol as Behaviour** - Define CandidateSelector as an Elixir behaviour
2. **Pure functions** - All selectors are pure functions of state + RNG
3. **Pattern matching** - Epsilon-greedy naturally maps to `if` or `case`
4. **idxmax utility** - Implement as `Enum.with_index/1` + `Enum.max_by/2`

**Elixir Structure:**
```elixir
defmodule GEPA.Strategies.CandidateSelector do
  @callback select_candidate_idx(
    state :: GEPAState.t(),
    rng_state :: term()
  ) :: {integer(), term()}
end

defmodule GEPA.Strategies.ParetoCandidateSelector do
  @behaviour GEPA.Strategies.CandidateSelector

  def select_candidate_idx(state, rng_state) do
    # Returns {program_idx, new_rng_state}
  end
end
```

---

## 3. Pareto Optimization Concepts

**File:** `/home/home/p/g/n/gepa_ex/gepa/src/gepa/gepa_utils.py`

### Core Functions

The Pareto optimization system consists of several interconnected functions:

#### 1. is_dominated/3

```python
def is_dominated(y, programs, program_at_pareto_front_valset):
    """
    Check if program y is dominated by programs in the given set.
    A program is dominated if, for every Pareto front it appears in,
    there exists another program from the candidate set in that same front.
    """
```

**Logic:**
1. Find all fronts containing program y
2. For each such front:
   - Check if any other program from candidates is also in that front
   - If yes, mark as "found dominator in front"
3. If ANY front has no dominator, y is NOT dominated
4. If ALL fronts have dominators, y IS dominated

**Purpose:** Identifies programs that are redundant given other candidates.

#### 2. remove_dominated_programs/2

**The core Pareto filtering algorithm.**

```python
def remove_dominated_programs(program_at_pareto_front_valset, scores=None):
    """
    Iteratively removes dominated programs from Pareto fronts.
    Returns filtered Pareto front mapping.
    """
```

**Algorithm:**

```
1. Count frequency of each program across all fronts
2. Sort programs by score (ascending) - removes lower-scoring dominated first
3. Iterative elimination:
   while found_to_remove:
     for each program y (not already dominated):
       if is_dominated(y, other_programs - dominated, fronts):
         add y to dominated set
         found_to_remove = True
         break
4. Build new Pareto fronts with only non-dominated programs
5. Validate: every front must have at least one non-dominated program
```

**Key Properties:**
- **Monotonic reduction** - Repeatedly removes dominated until none remain
- **Score-aware** - Lower-scoring dominated programs removed first
- **Soundness check** - Asserts every original front retains at least one program

#### 3. find_dominator_programs/2

```python
def find_dominator_programs(pareto_front_programs, train_val_weighted_agg_scores):
    """
    Returns the unique set of non-dominated programs.
    """
```

Simple wrapper that:
1. Calls remove_dominated_programs
2. Extracts unique program indices from resulting fronts
3. Returns as list

#### 4. select_program_candidate_from_pareto_front/3

**The selection function used by ParetoCandidateSelector.**

```python
def select_program_candidate_from_pareto_front(
    pareto_front_programs: Mapping[Any, set[int]],
    train_val_weighted_agg_scores: list[float],
    rng: random.Random
) -> int:
```

**Algorithm:**

```
1. Filter to non-dominated programs
   new_fronts = remove_dominated_programs(pareto_front_programs, scores)

2. Calculate frequency across fronts:
   frequency[prog] = number of fronts containing prog

3. Build weighted sampling list:
   sampling_list = [prog repeated frequency[prog] times for each prog]

4. Randomly select from sampling list
   return rng.choice(sampling_list)
```

**Why Frequency Weighting?**
- Programs on more Pareto fronts → appear more often in sampling list
- Higher probability of selection → more optimization focus
- Natural multi-objective optimization bias

**Fallback (Commented Out):**
```python
# If no programs survive (should not happen with assertions):
# return idxmax(train_val_weighted_agg_scores)
```
Current implementation asserts sampling_list is non-empty.

### Pareto Front Data Structure

```python
program_at_pareto_front_valset: dict[DataId, set[ProgramIdx]]
```

**Interpretation:**
- **Keys:** Validation example IDs
- **Values:** Set of program indices on Pareto front for that example
- **Meaning:** For each validation example, which programs are non-dominated?

**Example:**
```python
{
  "val_001": {0, 2, 5},    # Programs 0, 2, 5 are best for val_001
  "val_002": {2, 3},       # Programs 2, 3 are best for val_002
  "val_003": {0, 1, 2, 5}  # Programs 0, 1, 2, 5 are best for val_003
}
```

Program 2 appears in all three fronts → highest frequency → most likely to be selected.

### Elixir Port Considerations

1. **Immutable data structures** - Pareto fronts are naturally immutable
2. **MapSet for sets** - Use `MapSet` for program index sets
3. **Recursive elimination** - The while loop becomes tail-recursive function
4. **Frequency counting** - Use `Enum.frequencies_by/2` or `Enum.reduce/3`
5. **Sampling** - Build list, then use `:rand.uniform/1` with list length

**Elixir Structure:**
```elixir
defmodule GEPA.Utils.ParetoFront do
  @type program_idx :: non_neg_integer()
  @type data_id :: term()
  @type pareto_fronts :: %{data_id() => MapSet.t(program_idx())}

  @spec remove_dominated_programs(pareto_fronts(), map()) :: pareto_fronts()
  def remove_dominated_programs(fronts, scores) do
    # Tail-recursive elimination
    programs = get_all_programs(fronts)
    sorted_programs = Enum.sort_by(programs, &Map.get(scores, &1, 1))
    do_eliminate(fronts, sorted_programs, MapSet.new())
  end

  defp do_eliminate(fronts, programs, dominated) do
    # Recursive elimination until fixpoint
  end
end
```

---

## 4. Component Selection Strategy

**File:** `/home/home/p/g/n/gepa_ex/gepa/src/gepa/strategies/component_selector.py`

### Purpose

In multi-component optimization (where a program has multiple named predictors), this strategy determines which components to update in the next mutation step.

### Protocol Definition

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

**Returns:** List of component names (strings) to update.

### Implementation 1: RoundRobinReflectionComponentSelector

**Cycles through components one at a time.**

#### Algorithm

```
1. Get current component ID from state:
   pid = state.named_predictor_id_to_update_next_for_program_candidate[candidate_idx]

2. Update state for next iteration (circular increment):
   state.named_predictor_id_to_update_next_for_program_candidate[candidate_idx]
     = (pid + 1) % len(state.list_of_named_predictors)

3. Get component name:
   name = state.list_of_named_predictors[pid]

4. Return [name]
```

#### State Tracking

Each program candidate maintains its own position in the round-robin cycle:

```python
state.named_predictor_id_to_update_next_for_program_candidate: list[int]
```

- **Index:** Program candidate index
- **Value:** Next component ID to update for that candidate

This enables:
- **Independent cycles** - Different candidates can be at different stages
- **Parent inheritance** - New candidates inherit parent's cycle position (with max across parents)

#### Use Cases

- **Uniform attention** - All components get equal optimization focus
- **Systematic coverage** - Guarantees no component is neglected
- **Debugging** - Predictable, deterministic component selection

### Implementation 2: AllReflectionComponentSelector

**Always updates all components simultaneously.**

#### Algorithm

```python
def __call__(self, state, trajectories, subsample_scores,
             candidate_idx, candidate) -> list[str]:
    return list(candidate.keys())
```

Simply returns all component names from the candidate dictionary.

#### Use Cases

- **Holistic optimization** - All components updated together
- **Coordination** - When components have interdependencies
- **Rapid convergence** - Faster initial progress (but more LM calls)

### Component Data Structures

#### state.list_of_named_predictors

```python
state.list_of_named_predictors: list[str]
```

Canonical ordering of all component names. Examples:
- Single-component: `["instruction"]`
- Multi-component: `["context", "instruction", "few_shot_examples"]`

#### Program Candidates as Dictionaries

```python
candidate: dict[str, str]
```

**Keys:** Component names
**Values:** Component content (instructions, prompts, etc.)

Example:
```python
{
  "context": "You are a helpful assistant...",
  "instruction": "Solve the following problem step-by-step:",
  "few_shot_examples": "Example 1: ...\nExample 2: ..."
}
```

### Multi-Component Optimization Flow

```
1. CandidateSelector picks program candidate index
2. ComponentSelector picks component names to update
3. For each selected component:
   - InstructionProposal generates new content
   - Component is replaced in candidate dictionary
4. New candidate evaluated and added to state
```

### Elixir Port Considerations

1. **Stateful tracking** - Round-robin position is part of GEPAState
2. **Mutable update** - In Python, state is mutated; in Elixir, return updated state
3. **Map keys** - Components naturally map to Elixir map with string keys
4. **Behaviour pattern** - Component selector as behaviour with single callback

**Elixir Structure:**
```elixir
defmodule GEPA.Strategies.ComponentSelector do
  @callback select_components(
    state :: GEPAState.t(),
    trajectories :: list(Trajectory.t()),
    subsample_scores :: list(float()),
    candidate_idx :: integer(),
    candidate :: %{String.t() => String.t()}
  ) :: {list(String.t()), GEPAState.t()}
end

defmodule GEPA.Strategies.RoundRobinComponentSelector do
  @behaviour GEPA.Strategies.ComponentSelector

  def select_components(state, _trajectories, _scores, candidate_idx, _candidate) do
    pid = Enum.at(state.named_predictor_id_to_update_next, candidate_idx)
    next_pid = rem(pid + 1, length(state.list_of_named_predictors))
    name = Enum.at(state.list_of_named_predictors, pid)

    updated_state = put_in(
      state.named_predictor_id_to_update_next[candidate_idx],
      next_pid
    )

    {[name], updated_state}
  end
end
```

---

## 5. Evaluation Policy Strategy

**File:** `/home/home/p/g/n/gepa_ex/gepa/src/gepa/strategies/eval_policy.py`

### Purpose

Controls validation evaluation strategy, determining which validation examples to evaluate and how to score programs. Enables trade-offs between evaluation thoroughness and computational cost.

### Protocol Definition

```python
class EvaluationPolicy(Protocol[DataId, DataInst]):
    @abstractmethod
    def get_eval_batch(
        self,
        loader: DataLoader[DataId, DataInst],
        state: GEPAState,
        target_program_idx: ProgramIdx | None = None
    ) -> list[DataId]:
        """Select examples for evaluation for a program"""

    @abstractmethod
    def get_best_program(self, state: GEPAState) -> ProgramIdx:
        """Return "best" program given all validation results"""

    @abstractmethod
    def get_valset_score(self, program_idx: ProgramIdx, state: GEPAState) -> float:
        """Return the score of the program on the valset"""
```

### Three-Method Contract

1. **get_eval_batch** - Which validation examples to evaluate
2. **get_best_program** - Which program is best given current evaluations
3. **get_valset_score** - Score a specific program on valset

This abstraction enables:
- **Incremental evaluation** - Evaluate subset of validation examples
- **Adaptive sampling** - Focus on informative examples
- **Sparse coverage** - Different programs evaluated on different examples

### Implementation: FullEvaluationPolicy

**Always evaluates all validation examples.**

#### get_eval_batch

```python
def get_eval_batch(self, loader, state, target_program_idx=None) -> list[DataId]:
    return list(loader.all_ids())
```

Ignores `target_program_idx`, always returns full validation set.

#### get_best_program

```python
def get_best_program(self, state: GEPAState) -> ProgramIdx:
    best_idx, best_score, best_coverage = -1, float("-inf"), -1

    for program_idx, scores in enumerate(state.prog_candidate_val_subscores):
        coverage = len(scores)
        avg = sum(scores.values()) / coverage if coverage else float("-inf")

        # Tie-breaking: prefer higher coverage
        if avg > best_score or (avg == best_score and coverage > best_coverage):
            best_score = avg
            best_idx = program_idx
            best_coverage = coverage

    return best_idx
```

**Algorithm:**
1. Iterate through all programs
2. Calculate average score across evaluated examples
3. Track best by: (1) highest average, (2) highest coverage for ties
4. Return best program index

**Tie-Breaking:** Prefers programs evaluated on more examples when scores are equal. Important for fairness with sparse evaluation policies.

#### get_valset_score

```python
def get_valset_score(self, program_idx: ProgramIdx, state: GEPAState) -> float:
    return state.get_program_average_val_subset(program_idx)[0]
```

Delegates to state method that computes average over evaluated examples.

### Sparse Evaluation Context

The evaluation policy abstraction is designed for **sparse validation coverage**:

#### State Tracking

```python
state.prog_candidate_val_subscores: list[dict[DataId, float]]
```

- **Outer list:** One entry per program candidate
- **Inner dict:** Sparse mapping from DataId to score
- **Missing keys:** Examples not yet evaluated for that program

#### Coverage Tracking

```python
@property
def valset_evaluations(self) -> dict[DataId, list[ProgramIdx]]:
    """Validation examples by id and programs that have evaluated them."""
    result = defaultdict(list)
    for program_idx, val_scores in enumerate(self.prog_candidate_val_subscores):
        for val_id in val_scores.keys():
            result[val_id].append(program_idx)
    return result
```

This inverted index enables:
- **Per-example coverage** - Which programs have evaluated which examples
- **Fairness** - Detect evaluation imbalance
- **Incremental policies** - Choose under-evaluated examples

### Future Evaluation Policies

The protocol enables sophisticated strategies:

#### IncrementalEvaluationPolicy (hypothetical)

```python
def get_eval_batch(self, loader, state, target_program_idx):
    # Evaluate only examples where target_program is likely to improve
    scores = state.prog_candidate_val_subscores[target_program_idx]
    evaluated = set(scores.keys())
    unevaluated = set(loader.all_ids()) - evaluated

    # Sample from unevaluated
    return list(unevaluated)[:budget]
```

#### AdaptiveEvaluationPolicy (hypothetical)

```python
def get_eval_batch(self, loader, state, target_program_idx):
    # Focus on examples with high variance across programs
    coverage = state.valset_evaluations
    high_variance_examples = [
        ex_id for ex_id, prog_list in coverage.items()
        if variance_of_scores(prog_list, state) > threshold
    ]
    return high_variance_examples
```

### Elixir Port Considerations

1. **Behaviour definition** - EvaluationPolicy maps to Elixir behaviour
2. **Optional parameters** - `target_program_idx` can be `nil` in Elixir
3. **Sparse dictionaries** - Use Map for sparse score storage
4. **Coverage computation** - Can be memoized or cached
5. **Pure functions** - All methods are pure transformations of state

**Elixir Structure:**
```elixir
defmodule GEPA.Strategies.EvaluationPolicy do
  @callback get_eval_batch(
    loader :: DataLoader.t(),
    state :: GEPAState.t(),
    target_program_idx :: integer() | nil
  ) :: list(data_id())

  @callback get_best_program(state :: GEPAState.t()) :: integer()

  @callback get_valset_score(
    program_idx :: integer(),
    state :: GEPAState.t()
  ) :: float()
end

defmodule GEPA.Strategies.FullEvaluationPolicy do
  @behaviour GEPA.Strategies.EvaluationPolicy

  def get_eval_batch(loader, _state, _target_idx) do
    DataLoader.all_ids(loader)
  end

  def get_best_program(state) do
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {scores, idx} -> {idx, average_score(scores), map_size(scores)} end)
    |> Enum.max_by(fn {_idx, avg, coverage} -> {avg, coverage} end)
    |> elem(0)
  end

  defp average_score(scores) when scores == %{}, do: :neg_infinity
  defp average_score(scores) do
    Enum.sum(Map.values(scores)) / map_size(scores)
  end
end
```

---

## 6. Instruction Proposal Strategy

**File:** `/home/home/p/g/n/gepa_ex/gepa/src/gepa/strategies/instruction_proposal.py`

### Purpose

Generates new instruction proposals by prompting a language model with current instructions, example trajectories, and feedback. This is the core mechanism for instruction evolution.

### Signature Pattern

GEPA uses a **Signature** abstraction for structured LM interaction:

```python
@dataclass
class Signature:
    prompt_template: str
    input_keys: list[str]
    output_keys: list[str]
    prompt_renderer: Callable[[dict[str, str]], str]
    output_extractor: Callable[[str], dict[str, str]]
```

**Purpose:** Encapsulates prompt construction and output parsing for specific tasks.

### InstructionProposalSignature

#### Configuration

```python
class InstructionProposalSignature(Signature):
    default_prompt_template = """..."""  # See below
    input_keys = ["current_instruction_doc", "dataset_with_feedback", "prompt_template"]
    output_keys = ["new_instruction"]
```

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
the instruction, as a lot of it may not be available to the assistant in the
future. The assistant may have utilized a generalizable strategy to solve the
task, if so, include that in the instruction as well.

Provide the new instructions within ``` blocks.
```

**Key Components:**
1. **Current instructions** - What the assistant currently uses
2. **Examples with feedback** - Concrete demonstrations of successes/failures
3. **Meta-instructions** - How to synthesize new instructions

#### Prompt Rendering

The `prompt_renderer` method transforms input dictionary into a formatted prompt:

```python
@classmethod
def prompt_renderer(cls, input_dict: dict[str, str]) -> str:
    prompt_template = input_dict.get("prompt_template") or cls.default_prompt_template
    cls.validate_prompt_template(prompt_template)

    # Replace placeholders
    prompt = prompt_template.replace("<curr_instructions>",
                                      input_dict["current_instruction_doc"])
    prompt = prompt.replace("<inputs_outputs_feedback>",
                             format_samples(input_dict["dataset_with_feedback"]))

    return prompt
```

##### format_samples Helper

Converts structured data (list of dicts) into markdown format:

```python
def format_samples(samples):
    def render_value(value, level=3):
        if isinstance(value, dict):
            # Render as markdown headers for nested structure
            s = ""
            for k, v in value.items():
                s += f"{'#' * level} {k}\n"
                s += render_value(v, min(level + 1, 6))
            return s
        elif isinstance(value, (list, tuple)):
            # Render list items with numbered headers
            s = ""
            for i, item in enumerate(value):
                s += f"{'#' * level} Item {i + 1}\n"
                s += render_value(item, min(level + 1, 6))
            return s
        else:
            return f"{str(value).strip()}\n\n"

    def convert_sample_to_markdown(sample, examplenum):
        s = f"# Example {examplenum}\n"
        for key, val in sample.items():
            s += f"## {key}\n"
            s += render_value(val, level=3)
        return s

    return "\n\n".join(convert_sample_to_markdown(sample, i + 1)
                       for i, sample in enumerate(samples))
```

**Markdown Structure:**
```
# Example 1
## input
### field1
value1

### field2
value2

## output
assistant's response

## feedback
feedback text

# Example 2
...
```

This hierarchical structure helps LMs understand complex nested data.

#### Output Extraction

The `output_extractor` method parses LM output to extract the new instruction:

```python
@classmethod
def output_extractor(cls, lm_out: str) -> dict[str, str]:
    def extract_instruction_text() -> str:
        start = lm_out.find("```") + 3
        end = lm_out.rfind("```")

        if start >= end:
            # Handle incomplete code blocks
            stripped = lm_out.strip()
            if stripped.startswith("```"):
                # Remove opening ``` and optional language specifier
                match = re.match(r"^```\S*\n?", lm_out)
                return lm_out[match.end():].strip() if match else stripped
            elif stripped.endswith("```"):
                return stripped[:-3].strip()
            return stripped

        # Skip optional language specifier after opening ```
        content = lm_out[start:end]
        match = re.match(r"^\S*\n", content)
        if match:
            content = content[match.end():]

        return content.strip()

    return {"new_instruction": extract_instruction_text()}
```

**Handles:**
- Complete code blocks: ` ```instruction``` `
- Language specifiers: ` ```text\ninstruction``` `
- Incomplete blocks: ` ```instruction ` (no closing)
- No blocks at all: raw text

This robustness ensures LM output variations don't break the pipeline.

#### Validation

```python
@classmethod
def validate_prompt_template(cls, prompt_template: str | None):
    if prompt_template is None:
        return
    missing = [p for p in ["<curr_instructions>", "<inputs_outputs_feedback>"]
               if p not in prompt_template]
    if missing:
        raise ValueError(f"Missing placeholder(s): {', '.join(missing)}")
```

Ensures custom templates include required placeholders.

### Usage Pattern

```python
# 1. Prepare input
input_dict = {
    "current_instruction_doc": candidate["instruction"],
    "dataset_with_feedback": [
        {
            "input": {...},
            "output": {...},
            "feedback": "..."
        },
        ...
    ],
    "prompt_template": None  # Use default
}

# 2. Generate proposal
result = InstructionProposalSignature.run(language_model, input_dict)

# 3. Extract new instruction
new_instruction = result["new_instruction"]

# 4. Update candidate
new_candidate = {**candidate, "instruction": new_instruction}
```

### Integration with Optimization Loop

```
1. CandidateSelector picks program candidate
2. ComponentSelector picks components to update (e.g., ["instruction"])
3. For each component:
   a. Prepare input dict with current component content + feedback
   b. InstructionProposalSignature.run() generates proposal
   c. Replace component in candidate
4. Evaluate new candidate on validation set
5. Update state with new candidate and scores
```

### Elixir Port Considerations

1. **Signature as struct** - Elixir struct with function references
2. **Function references** - Store renderer/extractor as captured functions
3. **Markdown rendering** - Recursive function with pattern matching
4. **Regex parsing** - Use Elixir `Regex` module for output extraction
5. **Protocol for LM** - Language model as protocol/behaviour

**Elixir Structure:**
```elixir
defmodule GEPA.Strategies.Signature do
  defstruct [
    :prompt_template,
    :input_keys,
    :output_keys,
    :prompt_renderer,
    :output_extractor
  ]

  def run(%__MODULE__{} = sig, language_model, input_dict) do
    full_prompt = sig.prompt_renderer.(input_dict)
    lm_output = LanguageModel.call(language_model, full_prompt)
    sig.output_extractor.(String.trim(lm_output))
  end
end

defmodule GEPA.Strategies.InstructionProposal do
  @default_template """
  I provided an assistant with the following instructions...
  ```
  <curr_instructions>
  ```
  ...
  """

  def signature(prompt_template \\ nil) do
    %Signature{
      prompt_template: prompt_template || @default_template,
      input_keys: ["current_instruction_doc", "dataset_with_feedback", "prompt_template"],
      output_keys: ["new_instruction"],
      prompt_renderer: &prompt_renderer/1,
      output_extractor: &output_extractor/1
    }
  end

  defp prompt_renderer(input_dict) do
    # Rendering logic
  end

  defp output_extractor(lm_out) do
    # Extraction logic with pattern matching
    case extract_code_block(lm_out) do
      {:ok, instruction} -> %{"new_instruction" => instruction}
      :error -> %{"new_instruction" => String.trim(lm_out)}
    end
  end

  defp extract_code_block(text) do
    # Regex-based extraction with fallbacks
  end
end
```

---

## Strategy Interaction with Core Engine

### Optimization Loop Integration

The strategies plug into the main optimization loop at specific points:

```
Loop Iteration i:
  1. state.i += 1

  2. BatchSampler.next_minibatch_ids(loader, state)
     → Returns training example IDs for this iteration

  3. CandidateSelector.select_candidate_idx(state)
     → Returns program candidate index to mutate

  4. Evaluate candidate on training batch
     → Get trajectories and scores

  5. ComponentSelector(state, trajectories, scores, candidate_idx, candidate)
     → Returns component names to update

  6. For each component:
     a. Prepare feedback dataset
     b. InstructionProposalSignature.run(lm, input_dict)
        → Generate new component content
     c. Update component in candidate

  7. EvaluationPolicy.get_eval_batch(loader, state, new_program_idx)
     → Returns validation example IDs to evaluate

  8. Evaluate new candidate on validation batch
     → Get validation scores

  9. state.update_state_with_new_program(...)
     → Add new candidate to state
     → Update Pareto fronts

  10. EvaluationPolicy.get_best_program(state)
      → Determine current best program

  11. Log metrics, save state

  12. Repeat
```

### Strategy Dependencies

**Flow of Information:**

```
GEPAState
    ↓
BatchSampler → training_batch_ids
    ↓
CandidateSelector → candidate_idx
    ↓
[Evaluate on training batch] → trajectories, scores
    ↓
ComponentSelector → component_names
    ↓
InstructionProposal (for each component) → new_component_content
    ↓
[Combine into new_candidate]
    ↓
EvaluationPolicy.get_eval_batch → validation_ids
    ↓
[Evaluate on validation batch] → validation_scores
    ↓
GEPAState.update_state_with_new_program
    ↓
EvaluationPolicy.get_best_program → best_program_idx
    ↓
Updated GEPAState
```

### State Updates

Strategies read from state but typically don't modify it (except ComponentSelector in Python - should be refactored in Elixir to be pure).

**State Evolution:**
```
Initial State (seed candidate)
    ↓ [Iteration 1]
State with candidate 0, 1
    ↓ [Iteration 2]
State with candidates 0, 1, 2
    ↓ [Iteration n]
State with candidates 0..n
    ↓ [Pareto front filtering]
State with dominated programs marked
```

---

## Elixir Port Strategy

### Overall Architecture

```elixir
defmodule GEPA.Strategies do
  # Behaviours
  defmodule BatchSampler do
    @callback next_minibatch_ids(DataLoader.t(), GEPAState.t(), term())
      :: {list(data_id()), term()}
  end

  defmodule CandidateSelector do
    @callback select_candidate_idx(GEPAState.t(), term())
      :: {integer(), term()}
  end

  defmodule ComponentSelector do
    @callback select_components(
      GEPAState.t(),
      list(Trajectory.t()),
      list(float()),
      integer(),
      %{String.t() => String.t()}
    ) :: {list(String.t()), GEPAState.t()}
  end

  defmodule EvaluationPolicy do
    @callback get_eval_batch(DataLoader.t(), GEPAState.t(), integer() | nil)
      :: list(data_id())
    @callback get_best_program(GEPAState.t()) :: integer()
    @callback get_valset_score(integer(), GEPAState.t()) :: float()
  end
end
```

### Immutability Pattern

All strategies return updated state rather than mutating:

```elixir
# Python (mutation)
def select_candidate_idx(self, state: GEPAState) -> int:
    pid = state.named_predictor_id_to_update_next[candidate_idx]
    state.named_predictor_id_to_update_next[candidate_idx] = (pid + 1) % n
    return candidate_idx

# Elixir (immutable)
def select_components(state, candidate_idx, ...) do
  pid = Enum.at(state.named_predictor_id_to_update_next, candidate_idx)
  next_pid = rem(pid + 1, n)

  updated_state = %{state |
    named_predictor_id_to_update_next:
      List.replace_at(state.named_predictor_id_to_update_next, candidate_idx, next_pid)
  }

  {[component_name], updated_state}
end
```

### Random State Threading

All strategies requiring randomness accept and return RNG state:

```elixir
defmodule GEPA.Engine do
  def optimize_iteration(state, rng_state, strategies) do
    # Thread RNG state through all strategy calls
    {batch_ids, rng_state} =
      BatchSampler.next_minibatch_ids(strategies.batch_sampler, state, rng_state)

    {candidate_idx, rng_state} =
      CandidateSelector.select_candidate_idx(strategies.candidate_selector, state, rng_state)

    # ... continue threading
  end
end
```

### Configuration Pattern

Strategies configured as structs:

```elixir
strategies = %{
  batch_sampler: %EpochShuffledBatchSampler{
    minibatch_size: 8,
    shuffled_ids: [],
    epoch: -1,
    id_freqs: %{},
    last_trainset_size: 0,
    rng_state: :rand.seed(:exsss, {1, 2, 3})
  },
  candidate_selector: %ParetoCandidateSelector{
    rng_state: :rand.seed(:exsss, {4, 5, 6})
  },
  component_selector: %RoundRobinComponentSelector{},
  evaluation_policy: %FullEvaluationPolicy{},
  instruction_proposal: InstructionProposal.signature()
}
```

### Protocol Alternative

Could also use Elixir protocols for polymorphism:

```elixir
defprotocol CandidateSelector do
  def select_candidate_idx(strategy, state, rng_state)
end

defimpl CandidateSelector, for: ParetoCandidateSelector do
  def select_candidate_idx(_strategy, state, rng_state) do
    # Implementation
  end
end
```

**Trade-offs:**
- **Protocols:** More dynamic, open extension, single dispatch
- **Behaviours:** More static, compile-time checks, explicit modules

**Recommendation:** Use behaviours for better compile-time guarantees and clearer documentation.

---

## Key Algorithms Summary

### 1. Epoch-Shuffled Batch Sampling
- **Purpose:** Deterministic, reproducible batch generation
- **Key:** Padding with least-frequent IDs to maintain batch size
- **Complexity:** O(n) shuffle, O(1) batch retrieval

### 2. Pareto-Based Candidate Selection
- **Purpose:** Multi-objective program selection
- **Key:** Frequency-weighted sampling from non-dominated programs
- **Complexity:** O(p * v) domination check, O(p * f) sampling list construction
  - p = number of programs, v = number of validation examples, f = max frequency

### 3. Dominated Program Removal
- **Purpose:** Filter Pareto fronts to non-dominated programs
- **Key:** Iterative elimination sorted by score
- **Complexity:** O(p^2 * v) worst case, typically much faster
  - Monotonic reduction reduces iterations

### 4. Round-Robin Component Selection
- **Purpose:** Uniform component update distribution
- **Key:** Per-candidate cycle tracking with modulo arithmetic
- **Complexity:** O(1)

### 5. Markdown Formatting for LM Input
- **Purpose:** Structured data presentation to language model
- **Key:** Recursive hierarchical rendering with header levels
- **Complexity:** O(d * n) where d = depth, n = number of nodes

### 6. Code Block Extraction from LM Output
- **Purpose:** Robust instruction extraction
- **Key:** Multiple fallback strategies for incomplete/malformed output
- **Complexity:** O(m) where m = output length (string search)

---

## Testing Considerations for Elixir Port

### Unit Tests

1. **BatchSampler**
   - Test deterministic shuffling with seeded RNG
   - Test padding logic with non-divisible dataset sizes
   - Test epoch transitions
   - Test empty dataset handling

2. **CandidateSelector**
   - Test Pareto selection distribution matches frequency
   - Test greedy selection picks max
   - Test epsilon-greedy exploration/exploitation ratio
   - Test with degenerate cases (single candidate)

3. **ComponentSelector**
   - Test round-robin cycles through all components
   - Test independent cycles per candidate
   - Test "all" selector returns all keys

4. **EvaluationPolicy**
   - Test full policy returns all validation IDs
   - Test best program selection with ties
   - Test score calculation with sparse coverage

5. **InstructionProposal**
   - Test markdown rendering with nested structures
   - Test code block extraction with all formats
   - Test template validation

### Property-Based Tests

```elixir
# BatchSampler properties
property "batch sampler produces correct batch size" do
  check all minibatch_size <- integer(1..100),
            dataset_size <- integer(1..1000) do
    # Verify all batches have correct size
  end
end

# Pareto selection properties
property "selected candidate is always in some pareto front" do
  check all state <- gepa_state_generator() do
    {candidate_idx, _rng} = ParetoCandidateSelector.select(state, rng)
    assert candidate_in_some_front?(candidate_idx, state.program_at_pareto_front_valset)
  end
end

# Round-robin properties
property "round robin eventually selects all components" do
  check all num_components <- integer(1..10),
            num_iterations <- integer(num_components..100) do
    # Verify all components selected within num_components iterations
  end
end
```

### Integration Tests

Test strategy composition:
```elixir
test "strategies compose correctly in optimization loop" do
  state = initial_state()
  strategies = default_strategies()

  {updated_state, metrics} = GEPA.Engine.run_iteration(state, strategies)

  assert length(updated_state.program_candidates) == length(state.program_candidates) + 1
  assert updated_state.i == state.i + 1
  # ... verify Pareto fronts updated correctly
end
```

---

## Performance Considerations

### Python Implementation

1. **Pareto domination check:** O(p^2 * v) worst case
   - Mitigated by sorting and early exit
   - Dominated programs removed incrementally

2. **Batch sampling:** O(n) shuffle per epoch
   - Cached until epoch transition
   - Padding adds O(k) where k = padding size

3. **Component selection:** O(1) for round-robin
   - Dictionary lookup for "all" selector

### Elixir Optimizations

1. **Immutable data structures**
   - Use persistent data structures (ETS for large state?)
   - Consider zipper pattern for deep updates

2. **Pareto front filtering**
   - Parallelize domination checks with `Task.async_stream`
   - Memoize frequency counts

3. **Batch sampling**
   - Pre-compute padding once per epoch
   - Use arrays for index-based access (`:array` module)

4. **Large instruction proposals**
   - Stream markdown rendering for very large datasets
   - Consider chunking for extremely large feedback sets

---

## Conclusion

The GEPA optimization strategies form a cohesive, modular system for:
1. **Data sampling** - Deterministic, reproducible batch generation
2. **Candidate selection** - Multi-objective Pareto-based exploration
3. **Component selection** - Flexible multi-component update strategies
4. **Evaluation** - Extensible validation policies (full or incremental)
5. **Proposal generation** - Structured LM interaction for instruction evolution

### Elixir Port Priorities

1. **Immutability first** - All strategies return new state
2. **RNG threading** - Explicit RNG state in/out
3. **Behaviours** - Strong typing and documentation
4. **Pattern matching** - Leverage Elixir's strengths for conditional logic
5. **Testing** - Property-based tests for combinatorial explosion

### Critical Algorithms

The most complex and critical component is the **Pareto optimization system**:
- `is_dominated/3` - Core domination check
- `remove_dominated_programs/2` - Iterative filtering
- `select_program_candidate_from_pareto_front/3` - Frequency-weighted sampling

These require careful porting to maintain correctness while adapting to Elixir's functional paradigm.

### Next Steps for Port

1. Implement core utility functions (`idxmax`, Pareto functions)
2. Define behaviour modules for all strategies
3. Port `FullEvaluationPolicy` and `EpochShuffledBatchSampler` first (simpler)
4. Implement Pareto-based candidate selector (most complex)
5. Port component selectors and instruction proposal
6. Comprehensive test suite with property-based tests
7. Integration testing with core engine

This strategy system, when properly ported, will provide the same flexible optimization capabilities in Elixir while maintaining idiomatic functional programming patterns.
