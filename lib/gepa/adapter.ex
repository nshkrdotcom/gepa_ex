defmodule GEPA.Adapter do
  @moduledoc """
  Defines the contract for integrating GEPA with external systems.

  Adapters must implement evaluation, reflective dataset construction,
  and optionally custom proposal logic.

  ## Type Parameters

  Adapters work with three user-defined types:
  - `data_inst`: Input data structure for tasks
  - `trajectory`: Execution trace structure for reflection
  - `rollout_output`: Program output structure

  ## Required Callbacks

  - `evaluate/4`: Execute program on batch and return scores
  - `make_reflective_dataset/4`: Extract feedback from execution traces

  ## Optional Callbacks

  - `propose_new_texts/3`: Custom instruction proposal logic
  - `get_adapter_state/1`: Snapshot adapter-owned persistent state
  - `set_adapter_state/2`: Restore adapter-owned persistent state after resume

  ## Example Implementation

      defmodule MyAdapter do
        @behaviour GEPA.Adapter

        @impl true
        def evaluate(adapter, batch, candidate, capture_traces) do
          # Run program on batch
          # Return {:ok, %GEPA.EvaluationBatch{}}
        end

        @impl true
        def make_reflective_dataset(adapter, candidate, eval_batch, components) do
          # Extract feedback from trajectories
          # Return {:ok, dataset_map}
        end
      end
  """

  @type data_inst :: term()
  @type candidate :: %{String.t() => String.t()}
  @type eval_batch :: GEPA.EvaluationBatch.t()
  @type reflective_dataset :: %{String.t() => [map()]}

  @doc """
  Evaluate a candidate program on a batch of data.

  ## Parameters

  - `batch`: List of data instances to evaluate
  - `adapter`: Adapter struct or state
  - `candidate`: Program as map of component name -> component text
  - `capture_traces`: Whether to capture execution trajectories for reflection

  ## Returns

  - `{:ok, eval_batch}`: Successful evaluation with outputs, scores, and optional trajectories
  - `{:error, reason}`: Systemic failure (configuration error, missing dependencies, etc.)

  ## Contract

  - Never raise on individual example failures - return failure scores instead
  - `length(eval_batch.outputs) == length(eval_batch.scores) == length(batch)`
  - If `capture_traces=true`, must populate `eval_batch.trajectories`
  - Scores should be >= 0, higher is better
  - Failed examples should return low scores (e.g., 0.0)

  ## Scoring Semantics

  - GEPA uses `sum(scores)` for minibatch acceptance testing
  - GEPA uses `mean(scores)` for validation set tracking
  """
  @callback evaluate(
              adapter :: term(),
              batch :: [data_inst()],
              candidate :: candidate(),
              capture_traces :: boolean()
            ) :: {:ok, eval_batch()} | {:error, term()}

  @doc """
  Build reflective dataset from execution traces.

  Extracts actionable feedback from trajectories to guide instruction refinement.
  Only called when `evaluate/4` was called with `capture_traces=true`.

  ## Parameters

  - `candidate`: The candidate that was evaluated
  - `adapter`: Adapter struct or state
  - `eval_batch`: Results from evaluate/4 with trajectories
  - `components_to_update`: Subset of component names to generate feedback for

  ## Returns

  `{:ok, dataset}` where dataset is a map from component name to list of feedback records.

  ## Recommended Record Schema

      %{
        "Inputs" => %{...},              # Minimal view of inputs to component
        "Generated Outputs" => "...",    # What the component produced
        "Feedback" => "..."              # Performance feedback, errors, suggestions
      }

  ## Contract

  - Dataset must be JSON-serializable (will be embedded in LLM prompts)
  - Feedback should be actionable and concise
  - Only generate datasets for components in `components_to_update`
  - If using randomness for sampling, seed the RNG for determinism
  """
  @callback make_reflective_dataset(
              adapter :: term(),
              candidate :: candidate(),
              eval_batch :: eval_batch(),
              components_to_update :: [String.t()]
            ) :: {:ok, reflective_dataset()} | {:error, term()}

  @doc """
  Optional: Custom instruction proposal logic.

  Override default LLM-based proposal with task-specific logic.
  If not implemented, GEPA uses `GEPA.Strategies.InstructionProposal`.

  ## Parameters

  - `candidate`: Current candidate program
  - `reflective_dataset`: Feedback dataset from make_reflective_dataset/4
  - `components_to_update`: Components to propose new text for

  ## Returns

  `{:ok, new_texts}` where new_texts is a map from component name to new text.

  ## Use Cases

  - Custom LLM prompting strategies
  - Non-LLM based proposal (templates, rules, etc.)
  - Multi-component joint optimization
  """
  @callback propose_new_texts(
              candidate :: candidate(),
              reflective_dataset :: reflective_dataset(),
              components_to_update :: [String.t()]
            ) :: {:ok, %{String.t() => String.t()}} | {:error, term()}

  @doc """
  Optional: Custom instruction proposal logic with adapter state.

  Prefer this arity for new adapters. `propose_new_texts/3` remains supported
  for backward compatibility with early `gepa_ex` adapters.
  """
  @callback propose_new_texts(
              adapter :: term(),
              candidate :: candidate(),
              reflective_dataset :: reflective_dataset(),
              components_to_update :: [String.t()]
            ) :: {:ok, %{String.t() => String.t()}} | {:error, term()}

  @doc """
  Optional: Return adapter-specific state for checkpoint persistence.

  The returned value must be a fresh map and should be safe to serialize. GEPA
  stores it opaquely in `GEPA.State.adapter_state` and never inspects it.
  """
  @callback get_adapter_state(adapter :: term()) :: map() | {:ok, map()}

  @doc """
  Optional: Restore adapter-specific state from a checkpoint.

  Mutable adapters may update their internal process/resource and return `:ok`.
  Pure data adapters may return an updated adapter struct; the current engine
  treats that as advisory because adapter structs are passed in user config.
  """
  @callback set_adapter_state(adapter :: term(), state :: map()) :: :ok | {:ok, term()} | term()

  @optional_callbacks propose_new_texts: 3,
                      propose_new_texts: 4,
                      get_adapter_state: 1,
                      set_adapter_state: 2
end
