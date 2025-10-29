# GEPA Adapters: Comprehensive Documentation

## Overview

The GEPA adapter system provides the integration point between the GEPA optimization engine and external systems or task-specific implementations. Adapters are implemented as Python Protocols (structural typing), allowing for flexible implementation while maintaining a consistent interface.

### Purpose

Adapters serve three critical functions in GEPA:

1. **Program Construction & Evaluation**: Execute candidate programs on batches of data and compute performance scores
2. **Reflective Dataset Construction**: Extract meaningful traces and feedback from executions to guide improvement
3. **Optional Custom Proposal**: Override default instruction proposal logic with task-specific strategies

### Core Concepts

- **Candidate**: A `Dict[str, str]` mapping component names to their textual implementations (e.g., instructions, prompts, or code)
- **Scoring**: Higher is better. GEPA uses `sum(scores)` for minibatch acceptance and `mean(scores)` for validation tracking
- **Trajectories**: Opaque execution traces that capture intermediate states for reflection
- **Error Handling**: Adapters should return valid results with failure scores (e.g., 0.0) rather than raising exceptions for individual example failures

## The GEPAAdapter Protocol

Located in `/home/home/p/g/n/gepa_ex/gepa/src/gepa/core/adapter.py`

### Type Parameters

```python
GEPAAdapter[DataInst, Trajectory, RolloutOutput]
```

- **DataInst**: User-defined type for input data to the program under optimization
- **Trajectory**: User-defined type capturing execution steps and intermediate states
- **RolloutOutput**: User-defined type for program outputs

### Required Methods

#### 1. evaluate()

```python
def evaluate(
    self,
    batch: list[DataInst],
    candidate: dict[str, str],
    capture_traces: bool = False,
) -> EvaluationBatch[Trajectory, RolloutOutput]
```

**Purpose**: Execute the candidate program on a batch of data.

**Parameters**:
- `batch`: List of task-specific inputs
- `candidate`: Mapping from component names to component text
- `capture_traces`: When True, must populate trajectories for reflection

**Returns**: `EvaluationBatch` containing:
- `outputs`: Raw per-example outputs (opaque to GEPA)
- `scores`: Per-example floats (len == len(batch))
- `trajectories`: If capture_traces=True, list of trajectory objects; otherwise None

**Contracts**:
- `len(outputs) == len(scores) == len(batch)`
- If `capture_traces=True`: `len(trajectories) == len(batch)`
- Do not mutate `batch` or `candidate` in-place
- Return failure scores (e.g., 0.0) for failed examples rather than raising

#### 2. make_reflective_dataset()

```python
def make_reflective_dataset(
    self,
    candidate: dict[str, str],
    eval_batch: EvaluationBatch[Trajectory, RolloutOutput],
    components_to_update: list[str],
) -> dict[str, list[dict[str, Any]]]
```

**Purpose**: Build JSON-serializable datasets to drive instruction refinement.

**Parameters**:
- `candidate`: The candidate that was evaluated
- `eval_batch`: Result from `evaluate(..., capture_traces=True)`
- `components_to_update`: Subset of component names to generate datasets for

**Returns**: Dict mapping component names to lists of records

**Recommended Record Schema**:
```python
{
    "Inputs": Dict[str, str],           # Minimal view of inputs
    "Generated Outputs": Dict[str, str] | str,  # Model outputs
    "Feedback": str                     # Performance feedback, correct answers, errors
}
```

**Contracts**:
- Return deterministic results (seed RNGs if subsampling)
- Extract everything needed from `eval_batch.trajectories`

#### 3. propose_new_texts (Optional)

```python
propose_new_texts: ProposalFn | None = None
```

**Purpose**: Override default instruction proposal with custom logic.

**Signature**:
```python
def propose_new_texts(
    candidate: dict[str, str],
    reflective_dataset: dict[str, list[dict[str, Any]]],
    components_to_update: list[str],
) -> dict[str, str]
```

**Returns**: Dict mapping component names to newly proposed component texts.

---

## Adapter Implementations

### 1. DefaultAdapter

**Location**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/adapters/default_adapter/default_adapter.py`

**Purpose**: Simple single-instruction optimization using LLM API calls.

#### Type Definitions

```python
class DefaultDataInst(TypedDict):
    input: str
    additional_context: dict[str, str]
    answer: str

class DefaultTrajectory(TypedDict):
    data: DefaultDataInst
    full_assistant_response: str

class DefaultRolloutOutput(TypedDict):
    full_assistant_response: str
```

#### Implementation Details

**Initialization**:
```python
def __init__(
    self,
    model: str | Callable,
    failure_score: float = 0.0,
    max_litellm_workers: int = 10,
)
```

- Supports both string model names (via LiteLLM) and custom callable models
- Configurable parallelism via `max_litellm_workers`

**evaluate() Logic**:
1. Extracts the single system instruction from candidate (assumes one component)
2. Constructs messages: `[{"role": "system", "content": system_content}, {"role": "user", "content": input}]`
3. Uses `litellm.batch_completion()` for parallel LLM calls
4. Scores by checking if the expected answer appears in the response (exact substring match)
5. Optionally captures trajectories with data and full response

**make_reflective_dataset() Logic**:
1. Assumes single component to update
2. For each trajectory:
   - If score > 0: Provides positive feedback confirming correctness
   - If score = 0: Provides negative feedback with correct answer and additional context
3. Returns structured records with Inputs, Generated Outputs, and Feedback

**Key Characteristics**:
- Simplest adapter implementation
- Single-turn interactions
- Substring-based scoring
- No structured output parsing

**Use Cases**:
- Simple Q&A tasks
- Instruction optimization
- Tasks where answer appears in free-form text

---

### 2. DspyAdapter

**Location**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/adapters/dspy_adapter/dspy_adapter.py`

**Purpose**: Optimize DSPy program component instructions (per-predictor optimization).

#### Type Definitions

```python
DataInst = Example  # DSPy's Example type
Trajectory = TraceData  # DSPy's TraceData from bootstrap_trace
RolloutOutput = Prediction  # DSPy's Prediction type
```

#### Implementation Details

**Initialization**:
```python
def __init__(
    self,
    student_module,  # DSPy module to optimize
    metric_fn: Callable,
    feedback_map: dict[str, Callable],
    failure_score=0.0,
    num_threads: int | None = None,
    add_format_failure_as_feedback: bool = False,
    rng: random.Random | None = None,
)
```

- `student_module`: The DSPy module to optimize
- `feedback_map`: Maps predictor names to feedback functions that analyze predictor outputs
- `metric_fn`: Overall metric for program evaluation

**Program Construction**:
```python
def build_program(self, candidate: dict[str, str]):
    new_prog = self.student.deepcopy()
    for name, pred in new_prog.named_predictors():
        if name in candidate:
            pred.signature = pred.signature.with_instructions(candidate[name])
    return new_prog
```

Deep copies the student module and updates predictor signatures with new instructions.

**evaluate() Logic**:

When `capture_traces=True`:
1. Uses DSPy's `bootstrap_trace_data()` to capture full execution traces
2. Extracts scores from trace data, using `failure_score` for None scores
3. Returns trajectories containing full trace information

When `capture_traces=False`:
1. Uses DSPy's `Evaluate` class for efficient evaluation
2. Returns only outputs and scores, no trajectories

**make_reflective_dataset() Logic**:
1. Rebuilds program from candidate
2. For each component to update:
   - Finds matching module by signature
   - Extracts trace instances for that module
   - Handles `FailedPrediction` objects specially
   - For successful predictions:
     - Formats History objects as JSON-like context
     - Calls component-specific feedback function
     - Validates feedback score matches module score
   - For failed predictions:
     - Extracts raw completion text
     - Provides parsing failure feedback with expected structure
3. Returns structured records per predictor

**Key Characteristics**:
- Integrates deeply with DSPy framework
- Per-predictor optimization
- Handles parsing failures explicitly
- Uses DSPy's trace capture mechanism
- Supports custom feedback functions per predictor

**Unique Features**:
- `ScoreWithFeedback` return type for feedback functions
- `PredictorFeedbackFn` protocol for type-safe feedback
- Special handling of `History` type for chat-based tasks
- Integration with DSPy's `ChatAdapter` for format instructions

**Use Cases**:
- Optimizing DSPy program instructions
- Multi-step reasoning tasks
- Tasks requiring per-component feedback

---

### 3. DspyFullProgramAdapter

**Location**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/adapters/dspy_full_program_adapter/full_program_adapter.py`

**Purpose**: Optimize entire DSPy program code (not just instructions).

#### Type Definitions

Same as DspyAdapter (Example, TraceData, Prediction).

#### Implementation Details

**Initialization**:
```python
def __init__(
    self,
    task_lm: dspy.LM,
    metric_fn: Callable,
    reflection_lm: dspy.LM,  # Required!
    failure_score=0.0,
    num_threads: int | None = None,
    add_format_failure_as_feedback: bool = False,
    rng: random.Random | None = None,
)
```

Key difference: Requires `reflection_lm` for program code generation.

**Program Construction**:
```python
def build_program(self, candidate: dict[str, str]) -> tuple[dspy.Module, None] | tuple[None, str]:
    candidate_src = candidate["program"]
    context = {}
    return self.load_dspy_program_from_code(candidate_src, context)
```

- Expects `candidate["program"]` to contain Python source code
- Compiles and executes code to create program instance
- Returns `(program, None)` on success or `(None, error_message)` on failure

**load_dspy_program_from_code() Logic**:
1. Attempts to compile code using `compile()`
2. Catches `SyntaxError` and returns error traceback
3. Executes code with `exec()` in isolated context
4. Validates that `program` object exists and is a `dspy.Module` instance
5. Sets the task LM on the program
6. Returns program or detailed error message

**evaluate() Logic**:

When program build fails:
- Returns `EvaluationBatch` with `failure_score` for all examples
- Sets `trajectories` to the error message string

When program build succeeds:
- Same logic as DspyAdapter (uses `bootstrap_trace_data` or `Evaluate`)

**make_reflective_dataset() Logic**:

If program build failed:
- Returns simple feedback dict: `{"program": {"Feedback": error_message}}`

If program build succeeded:
1. Expects `components_to_update == ["program"]`
2. For each trajectory:
   - Extracts program inputs, outputs, and score
   - Extracts feedback from score if available
   - Builds detailed trace information:
     - Identifies called module names
     - Formats predictor inputs/outputs
     - Handles History types
     - Includes failed predictions
3. Returns structured records with:
   - `Program Inputs`: Original example inputs
   - `Program Outputs`: Final prediction
   - `Program Trace`: List of predictor invocations with inputs/outputs
   - `Feedback`: Task-level feedback (if available)

**propose_new_texts() Override**:
```python
def propose_new_texts(
    self,
    candidate: dict[str, str],
    reflective_dataset: dict[str, list[dict[str, Any]]],
    components_to_update: list[str],
) -> dict[str, str]:
    from gepa.adapters.dspy_full_program_adapter.dspy_program_proposal_signature import DSPyProgramProposalSignature

    new_texts: dict[str, str] = {}
    for name in components_to_update:
        base_instruction = candidate[name]
        dataset_with_feedback = reflective_dataset[name]
        new_texts[name] = DSPyProgramProposalSignature.run(
            lm=self.reflection_lm,
            input_dict={"curr_program": base_instruction, "dataset_with_feedback": dataset_with_feedback},
        )["new_program"]
    return new_texts
```

Uses custom `DSPyProgramProposalSignature` for code generation.

**DSPyProgramProposalSignature Details**:

Located in `/home/home/p/g/n/gepa_ex/gepa/src/gepa/adapters/dspy_full_program_adapter/dspy_program_proposal_signature.py`

**Prompt Template Highlights**:
- Comprehensive DSPy tutorial including Signatures, Modules, built-in types
- Improvement strategies: decomposition, consolidation, refinement, control flow
- Requests step-by-step analysis and checklist
- Outputs code in triple backticks
- Expects valid Python with `program` object assignment

**output_extractor()**:
Extracts code from triple backtick blocks, handling various edge cases.

**Key Characteristics**:
- Optimizes entire program structure, not just instructions
- Dynamic code execution with safety checks
- Rich error reporting for syntax/execution errors
- Custom proposal signature for code generation
- Handles compilation and runtime errors gracefully

**Unique Features**:
- Code compilation and execution
- Detailed trace with called module names
- Program-level rather than component-level optimization
- YAML serialization of feedback datasets

**Use Cases**:
- Optimizing DSPy program architecture
- Tasks requiring module decomposition/composition
- Exploring different DSPy module combinations

**Risks for Elixir Port**:
- Code execution is inherently unsafe (consider sandboxing)
- String-based code manipulation is brittle
- May need AST-based approach in Elixir

---

### 4. AnyMathsAdapter

**Location**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/adapters/anymaths_adapter/anymaths_adapter.py`

**Purpose**: Mathematical word problem solving with structured outputs.

#### Type Definitions

```python
class AnyMathsDataInst(TypedDict):
    input: str
    additional_context: dict[str, str]
    answer: str

class AnyMathsTrajectory(TypedDict):
    data: AnyMathsDataInst
    full_assistant_response: str

class AnyMathsRolloutOutput(TypedDict):
    full_assistant_response: str

class AnyMathsStructuredOutput(BaseModel):
    final_answer: str  # No units, just the answer
    solution_pad: str  # Step-by-step solution
```

#### Implementation Details

**Initialization**:
```python
def __init__(
    self,
    model: str,
    failure_score: float = 0.0,
    api_base: str | None = "http://localhost:11434",
    max_litellm_workers: int = 10,
)
```

- Designed for Ollama models (local inference)
- Requires `api_base` when using Ollama
- Enforces structured output via Pydantic schema

**evaluate() Logic**:
1. Extracts system instruction from candidate
2. Constructs messages for each example
3. Calls `litellm.batch_completion()` with:
   - `format`: Pydantic model JSON schema
   - `response_format`: JSON object with schema validation
4. Parses responses using `ast.literal_eval()`
5. If parsing fails:
   - Sets `correct_output_format = False`
   - Uses failure message as output
   - Assigns `failure_score`
6. If parsing succeeds:
   - Formats structured response as "Assistant's Solution: ... Final Answer: ..."
   - Checks if expected answer appears in `final_answer`
   - Assigns score 1.0 or failure_score
7. Captures trajectories with data and formatted response

**make_reflective_dataset() Logic**:
1. Assumes single component to update
2. For each trajectory:
   - If score > 0: Provides positive feedback with final answer
   - If score = 0:
     - Provides negative feedback with correct answer
     - Includes additional context if available
3. Returns structured records

**Key Characteristics**:
- Enforces structured JSON output
- Designed for local Ollama models
- Separates solution process from final answer
- Handles JSON parsing failures gracefully

**Unique Features**:
- Pydantic schema for output validation
- `JSONSchemaValidationError` handling (may raise on schema mismatch)
- Solution pad + final answer separation
- Ollama-specific configuration

**Use Cases**:
- Mathematical reasoning tasks (GSM8K, AIME)
- Tasks requiring step-by-step solutions
- Local model inference scenarios

---

### 5. TerminalBenchAdapter (TerminusAdapter)

**Location**: `/home/home/p/g/n/gepa_ex/gepa/src/gepa/adapters/terminal_bench_adapter/terminal_bench_adapter.py`

**Purpose**: Optimize agents for terminal-based tasks using Terminal-Bench.

#### Type Definitions

```python
class TerminalBenchTask(BaseModel):
    task_id: str
    model_name: str
```

No explicit type parameters for Trajectory/RolloutOutput (uses generic protocol).

#### Implementation Details

**Initialization**:
```python
def __init__(
    self,
    n_concurrent: int = 6,
    instruction_prompt_path: str = "prompt-templates/instruction_prompt.txt",
)
```

- `n_concurrent`: Number of concurrent task executions
- `instruction_prompt_path`: File path where instruction prompt is written

**External Integration**:

Uses `tb run` CLI command to execute Terminal-Bench tasks:

```python
def run_agent_tb(
    task_ids: str | list[str],
    run_id: str,
    model_name: str,
    instruction_prompt: str,
    dataset_name: str = "terminal-bench-core",
    dataset_version: str = "head",
    agent_import_path: str = "train_terminus:TerminusWrapper",
    n_concurrent: int = 6,
    prompt_template_path: str = "prompt-templates/instruction_prompt.txt",
)
```

1. Writes instruction prompt to file
2. Constructs `tb run` command with parameters
3. Executes via `subprocess.run()`
4. Returns exit code

**get_results() Logic**:
1. Locates logging directory for task/run
2. Reads `results.json`:
   - Extracts parser results (sum of "passed" checks)
   - Determines success via `is_resolved` flag
   - Captures failure mode
3. Reads trajectory from latest episode's `debug.json`
4. Extracts message history from trajectory
5. Appends final assistant response from `response.json`
6. Returns: `(success, score, failed_reason, messages)`

**evaluate() Logic**:
1. Creates unique run ID with timestamp
2. Calls `run_agent_tb()` for entire batch
3. For each task:
   - Calls `get_results()` to extract outcomes
   - Handles exceptions gracefully
   - Constructs output message (points to logging dir)
   - Collects score
   - Builds trajectory with:
     - `messages`: Full conversation history
     - `instruction_prompt`: The instruction used
     - `failed_reason`: Failure mode if unsuccessful
     - `success`: Boolean flag
4. Returns `EvaluationBatch`

**make_reflective_dataset() Logic**:
1. Creates dataset for `instruction_prompt` component
2. For each trajectory:
   - If successful: Simple success feedback
   - If failed: Includes failure reason
3. Returns records with:
   - `Message History`: Full conversation
   - `Instruction Prompt`: Current instruction
   - `Feedback`: Success or failure message

**Key Characteristics**:
- External subprocess execution
- File-based communication (writes prompt to file)
- Complex result extraction from file system
- Episode-based trajectories
- Integration with Terminal-Bench framework

**Unique Features**:
- Subprocess-based evaluation
- Multi-episode support
- Parses structured JSON from external tool
- Timestamp-based run IDs
- Reads from multiple JSON files per task

**Use Cases**:
- Terminal command execution tasks
- Multi-step system administration
- Tasks requiring environment interaction

**Integration Patterns**:
- Wraps Terminal-Bench's `Terminus` agent
- `TerminusWrapper` injects instruction prompt into system
- Uses file system for state communication

**Challenges for Elixir Port**:
- Subprocess management (use Elixir's `System.cmd/3` or `Port`)
- File system navigation and JSON parsing
- Error handling across process boundaries
- Concurrent task execution (Elixir tasks/async)

---

## Common Patterns Across Adapters

### 1. Batch Processing

All adapters process batches of examples:
- **DefaultAdapter**: Uses `litellm.batch_completion()` for parallelism
- **DspyAdapter**: Uses DSPy's `Evaluate` with threading
- **AnyMathsAdapter**: Uses `litellm.batch_completion()` with structured output
- **TerminalBenchAdapter**: Uses subprocess with concurrent execution

**Elixir Approach**: Use `Task.async_stream/3` or `Flow` for concurrent processing.

### 2. Error Handling Philosophy

Prefer returning failure scores over raising exceptions:
- Parse errors → `failure_score` + error message in trajectory
- Execution errors → `failure_score` + traceback in feedback
- Only raise for systemic/configuration errors

**Elixir Approach**: Use `{:ok, result}` / `{:error, reason}` tuples, accumulate errors.

### 3. Trajectory Capture

Conditional trace capture based on `capture_traces` flag:
- When `True`: Build detailed trajectory objects with all execution details
- When `False`: Return `None`/`nil` to save memory

**Elixir Approach**: Use `nil` or `{:ok, nil}` when traces not needed.

### 4. Reflective Dataset Construction

Common structure:
```python
{
    "Inputs": {...},
    "Generated Outputs": {...},
    "Feedback": "..."
}
```

Different adapters add:
- **DSPy**: Module signatures, trace instances, parsing failures
- **DspyFullProgram**: Program traces with called modules
- **TerminalBench**: Message history, failure reasons

**Elixir Approach**: Use maps with atom keys, structs for stronger typing.

### 5. Component Naming

- Most adapters: Single component (unnamed or "instruction_prompt")
- **DspyAdapter**: Multiple components (predictor names)
- **DspyFullProgramAdapter**: Single "program" component

**Elixir Approach**: Use atom keys for component names.

### 6. Model Integration

Three patterns:
1. **String-based** (DefaultAdapter, AnyMathsAdapter): Model name → LiteLLM
2. **Callable-based** (DefaultAdapter option): Custom function
3. **Framework-integrated** (DspyAdapter): DSPy's LM objects

**Elixir Approach**:
- Behavior for model abstraction
- Protocol for polymorphic dispatch
- Struct-based model configuration

---

## Adapter Comparison Matrix

| Adapter | Data Type | Complexity | External Dependencies | Structured Output | Multi-Component | Custom Proposal |
|---------|-----------|------------|----------------------|-------------------|-----------------|-----------------|
| DefaultAdapter | Simple Q&A | Low | LiteLLM | No | No | No |
| DspyAdapter | DSPy Examples | Medium | DSPy, LiteLLM | Partial (DSPy Predictions) | Yes | No |
| DspyFullProgramAdapter | DSPy Examples | High | DSPy, LiteLLM | Partial (DSPy Predictions) | No (single "program") | Yes |
| AnyMathsAdapter | Math Problems | Low-Medium | LiteLLM, Ollama | Yes (Pydantic) | No | No |
| TerminalBenchAdapter | Terminal Tasks | High | Terminal-Bench, subprocess | Partial (agent responses) | No | No |

---

## Implementing New Adapters

### Step-by-Step Guide

1. **Define Type Parameters**:
   ```python
   class MyDataInst(TypedDict):
       # Define your input structure
       pass

   class MyTrajectory(TypedDict):
       # Define what you capture during execution
       pass

   class MyRolloutOutput(TypedDict):
       # Define output structure
       pass
   ```

2. **Implement evaluate()**:
   - Build program from candidate
   - Execute on each example in batch
   - Compute scores (higher = better)
   - Optionally capture trajectories
   - Return `EvaluationBatch`

3. **Implement make_reflective_dataset()**:
   - Extract from trajectories
   - Build feedback for each component
   - Return structured records

4. **Optional: Implement propose_new_texts()**:
   - If default instruction proposal insufficient
   - Return Dict[str, str] mapping components to new texts

### Best Practices

1. **Determinism**: Seed RNGs for reproducibility
2. **Efficiency**: Skip trajectory building when `capture_traces=False`
3. **Feedback Quality**: Provide actionable, specific feedback in reflective datasets
4. **Error Handling**: Return failure scores rather than raising
5. **Testing**: Test with small batches first
6. **Documentation**: Document expected data formats clearly

### Example Skeleton

```python
class MyAdapter(GEPAAdapter[MyDataInst, MyTrajectory, MyRolloutOutput]):
    def __init__(self, model, failure_score=0.0):
        self.model = model
        self.failure_score = failure_score

    def evaluate(self, batch, candidate, capture_traces=False):
        outputs = []
        scores = []
        trajectories = [] if capture_traces else None

        # Extract component(s) from candidate
        instruction = candidate["my_component"]

        for example in batch:
            try:
                # Execute program
                output = self.run_program(instruction, example)
                score = self.compute_score(output, example)

                outputs.append(output)
                scores.append(score)

                if capture_traces:
                    trajectories.append({
                        "example": example,
                        "output": output,
                        # ... other trace info
                    })
            except Exception as e:
                outputs.append({"error": str(e)})
                scores.append(self.failure_score)
                if capture_traces:
                    trajectories.append({"error": str(e)})

        return EvaluationBatch(
            outputs=outputs,
            scores=scores,
            trajectories=trajectories
        )

    def make_reflective_dataset(self, candidate, eval_batch, components_to_update):
        ret_d = {}

        for component in components_to_update:
            items = []
            for traj, score in zip(eval_batch.trajectories, eval_batch.scores):
                # Extract feedback from trajectory
                feedback = self.generate_feedback(traj, score)

                items.append({
                    "Inputs": traj["example"]["input"],
                    "Generated Outputs": str(traj["output"]),
                    "Feedback": feedback
                })

            ret_d[component] = items

        return ret_d
```

---

## Considerations for Elixir Port

### 1. Protocol vs. Behavior

**Python**: Uses `Protocol` (structural subtyping)
**Elixir**: Consider two approaches:

**Option A: Behavior (nominal typing)**
```elixir
defmodule GEPA.Adapter do
  @callback evaluate(
    batch :: [data_inst()],
    candidate :: %{String.t() => String.t()},
    capture_traces :: boolean()
  ) :: EvaluationBatch.t()

  @callback make_reflective_dataset(
    candidate :: %{String.t() => String.t()},
    eval_batch :: EvaluationBatch.t(),
    components_to_update :: [String.t()]
  ) :: %{String.t() => [map()]}

  @optional_callbacks propose_new_texts: 3
end
```

**Option B: Protocol (structural typing)**
```elixir
defprotocol GEPA.Adapter do
  def evaluate(adapter, batch, candidate, capture_traces)
  def make_reflective_dataset(adapter, candidate, eval_batch, components_to_update)
end
```

**Recommendation**: Use Behavior for clearer contracts and compile-time checking.

### 2. Type Specifications

Use typespecs and structs:

```elixir
defmodule GEPA.EvaluationBatch do
  @type t :: %__MODULE__{
    outputs: [any()],
    scores: [float()],
    trajectories: [any()] | nil
  }

  defstruct [:outputs, :scores, :trajectories]
end
```

### 3. Error Handling

Replace exceptions with tagged tuples:

```elixir
def evaluate(batch, candidate, capture_traces) do
  results =
    Enum.map(batch, fn example ->
      case run_program(candidate, example) do
        {:ok, output} ->
          {:ok, output, compute_score(output, example)}
        {:error, reason} ->
          {:error, reason, @failure_score}
      end
    end)

  # Build EvaluationBatch from results
end
```

### 4. Concurrency

Use Elixir's native concurrency:

```elixir
def evaluate_concurrent(batch, candidate, _capture_traces) do
  batch
  |> Task.async_stream(fn example ->
    run_program(candidate, example)
  end, max_concurrency: 10, timeout: 30_000)
  |> Enum.to_list()
  |> process_results()
end
```

### 5. External Process Integration

For TerminalBenchAdapter-like scenarios:

```elixir
def run_external_task(task_id, instruction) do
  # Write instruction to file
  File.write!(prompt_path, instruction)

  # Run external command
  case System.cmd("tb", ["run", "--task-id", task_id],
                   stderr_to_stdout: true) do
    {output, 0} -> {:ok, output}
    {output, exit_code} -> {:error, {exit_code, output}}
  end
end
```

Or use Ports for streaming communication.

### 6. Model Abstraction

Define behavior for model interaction:

```elixir
defmodule GEPA.Model do
  @callback complete(messages :: [map()], opts :: keyword()) ::
    {:ok, String.t()} | {:error, term()}
end

defmodule GEPA.Models.LiteLLM do
  @behaviour GEPA.Model

  def complete(messages, opts) do
    # Call LiteLLM via HTTP or port
  end
end
```

### 7. Structured Output Parsing

Use libraries like `Jason` for JSON and Ecto for validation:

```elixir
defmodule AnyMaths.StructuredOutput do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :final_answer, :string
    field :solution_pad, :string
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:final_answer, :solution_pad])
    |> validate_required([:final_answer, :solution_pad])
  end
end
```

### 8. Code Execution (DspyFullProgramAdapter)

**Caution**: Dynamic code execution is risky.

**Options**:
1. **Avoid entirely**: Don't port this adapter
2. **Sandboxing**: Use safe evaluation libraries (limited in Elixir)
3. **AST approach**: Parse and validate code structures
4. **External process**: Run in isolated container

**Recommendation**: Start without DspyFullProgramAdapter, add later if needed with proper sandboxing.

### 9. Trace Capture Optimization

Use lazy evaluation or streams:

```elixir
def evaluate(batch, candidate, capture_traces) do
  batch
  |> Enum.map(fn example ->
    output = run_program(candidate, example)
    score = compute_score(output, example)

    trajectory =
      if capture_traces do
        build_trajectory(example, output)
      else
        nil
      end

    {output, score, trajectory}
  end)
  |> build_evaluation_batch()
end
```

### 10. Reflective Dataset Serialization

Use Jason for JSON-compatible structures:

```elixir
def make_reflective_dataset(candidate, eval_batch, components_to_update) do
  components_to_update
  |> Map.new(fn component ->
    items =
      eval_batch.trajectories
      |> Enum.map(&build_reflective_item/1)

    {component, items}
  end)
end

defp build_reflective_item(trajectory) do
  %{
    "Inputs" => trajectory.inputs,
    "Generated Outputs" => trajectory.outputs,
    "Feedback" => generate_feedback(trajectory)
  }
end
```

---

## Advanced Adapter Patterns

### 1. Feedback Functions (DspyAdapter Pattern)

**Python**:
```python
feedback_map = {
    "predictor_name": lambda predictor_output, predictor_inputs,
                             module_inputs, module_outputs, captured_trace:
                      ScoreWithFeedback(score=..., feedback="...")
}
```

**Elixir**:
```elixir
defmodule MyAdapter do
  def feedback_for(:predictor_name, predictor_output, predictor_inputs,
                    module_inputs, module_outputs, captured_trace) do
    %{score: ..., feedback: "..."}
  end
end

# Or use function references:
feedback_map = %{
  "predictor_name" => &MyFeedback.for_predictor_1/5
}
```

### 2. Multi-Component Updates

**Pattern**: Track which components to update, build datasets only for those.

```elixir
def make_reflective_dataset(candidate, eval_batch, components_to_update) do
  # Only process requested components
  components_to_update
  |> Enum.reduce(%{}, fn component, acc ->
    dataset = extract_dataset_for_component(component, eval_batch)
    Map.put(acc, component, dataset)
  end)
end
```

### 3. Trajectory Sampling

Some adapters sample traces for efficiency:

```elixir
def sample_trajectories(trajectories, max_samples, rng) do
  if length(trajectories) <= max_samples do
    trajectories
  else
    trajectories
    |> Enum.shuffle(rng)
    |> Enum.take(max_samples)
  end
end
```

### 4. History Formatting (DSPy Pattern)

For chat-based tasks:

```elixir
defp format_history(%History{messages: messages}) do
  messages
  |> Enum.with_index()
  |> Enum.map_join("\n", fn {msg, idx} ->
    "#{idx}: #{inspect(msg)}"
  end)
end
```

---

## Testing Strategies for Adapters

### 1. Unit Tests

Test each method independently:

```elixir
defmodule MyAdapterTest do
  use ExUnit.Case

  test "evaluate returns correct structure" do
    adapter = MyAdapter.new(model: "test")
    batch = [%{input: "test"}]
    candidate = %{"component" => "instruction"}

    result = adapter.evaluate(batch, candidate, false)

    assert %GEPA.EvaluationBatch{} = result
    assert length(result.scores) == length(batch)
    assert result.trajectories == nil
  end

  test "evaluate captures traces when requested" do
    adapter = MyAdapter.new(model: "test")
    batch = [%{input: "test"}]
    candidate = %{"component" => "instruction"}

    result = adapter.evaluate(batch, candidate, true)

    assert length(result.trajectories) == length(batch)
  end
end
```

### 2. Integration Tests

Test with real (or mocked) external systems:

```elixir
test "integrates with LiteLLM" do
  # Mock HTTP calls or use VCR-style recording
end

test "handles external process failures" do
  # Test subprocess error handling
end
```

### 3. Property Tests

Use StreamData for property-based testing:

```elixir
property "scores are always between 0 and 1" do
  check all batch <- list_of(data_inst_generator(), min_length: 1),
            candidate <- candidate_generator() do
    result = MyAdapter.evaluate(batch, candidate, false)
    assert Enum.all?(result.scores, &(&1 >= 0 and &1 <= 1))
  end
end
```

### 4. Reflective Dataset Validation

Ensure datasets are JSON-serializable:

```elixir
test "reflective dataset is JSON-serializable" do
  dataset = adapter.make_reflective_dataset(candidate, eval_batch, ["comp"])

  assert {:ok, _json} = Jason.encode(dataset)
end
```

---

## Performance Considerations

### 1. Batch Size Optimization

- **Small batches**: Better error isolation, more overhead
- **Large batches**: Better throughput, memory intensive

**Recommendation**: Make batch size configurable, default to 10-50.

### 2. Concurrency Tuning

```elixir
# Respect rate limits
def evaluate_with_rate_limit(batch, candidate, opts) do
  max_concurrency = opts[:max_concurrency] || 10

  batch
  |> Task.async_stream(
    &run_program(candidate, &1),
    max_concurrency: max_concurrency,
    timeout: 60_000
  )
  |> Enum.to_list()
end
```

### 3. Memory Management

- Avoid storing full traces when not needed
- Stream large batches
- Consider GenServer for stateful adapters

### 4. Caching

Cache expensive operations:

```elixir
defmodule CachedAdapter do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def evaluate(batch, candidate, capture_traces) do
    # Check cache for candidate
    case get_cached_results(candidate, batch) do
      {:ok, results} -> results
      :miss ->
        results = run_evaluation(batch, candidate, capture_traces)
        cache_results(candidate, batch, results)
        results
    end
  end
end
```

---

## Summary

The GEPA adapter system provides a flexible, protocol-based interface for integrating optimization with diverse systems. Key insights:

1. **Adapters bridge GEPA to external systems** via three core methods
2. **Different adapters target different use cases**: simple instructions, DSPy programs, math problems, terminal tasks
3. **Common patterns** include batch processing, error handling, trajectory capture, and reflective feedback
4. **Elixir port should use Behaviors** for clear contracts and compile-time safety
5. **Concurrency is first-class** in Elixir, making parallel evaluation natural
6. **Error handling** should favor tagged tuples over exceptions
7. **External integrations** can use System.cmd, Ports, or HTTP clients
8. **Code execution adapters** require careful security consideration

The adapter pattern is well-suited for Elixir's strengths: concurrency, fault tolerance, and functional design. The main challenges are external system integration (subprocess, DSPy) and structured output enforcement.
