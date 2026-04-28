defmodule GEPA.State do
  @moduledoc """
  Persistent state tracking the complete optimization history.

  This is the heart of GEPA - all candidates, scores, Pareto fronts,
  and lineage are stored here.
  """

  alias GEPA.Types

  @validation_schema_version 5
  @state_file "gepa_state.etf"
  @legacy_state_file "gepa_state.bin"

  @type t :: %__MODULE__{
          # All discovered program candidates
          program_candidates: [Types.candidate()],

          # Parent relationships (genealogy) - list per program
          parent_program_for_candidate: [[Types.program_idx() | nil]],

          # Sparse validation scores (only evaluated examples)
          prog_candidate_val_subscores: [Types.sparse_scores()],
          prog_candidate_objective_scores: [%{String.t() => float()}],

          # Pareto front tracking
          frontier_type: :instance | :objective | :hybrid | :cartesian,
          pareto_front_valset: %{Types.data_id() => float()},
          program_at_pareto_front_valset: Types.pareto_fronts(),
          objective_pareto_front: %{String.t() => float()},
          program_at_pareto_front_objectives: %{String.t() => MapSet.t(Types.program_idx())},
          pareto_front_cartesian: %{{Types.data_id(), String.t()} => float()},
          program_at_pareto_front_cartesian: %{
            {Types.data_id(), String.t()} => MapSet.t(Types.program_idx())
          },

          # Component metadata
          list_of_named_predictors: [String.t()],
          named_predictor_id_to_update_next_for_program_candidate: [non_neg_integer()],

          # Iteration tracking
          i: integer(),
          num_full_ds_evals: non_neg_integer(),
          total_num_evals: non_neg_integer(),
          num_metric_calls_by_discovery: [non_neg_integer()],

          # Trace and metadata
          full_program_trace: [map()],
          best_outputs_valset: %{Types.data_id() => [{Types.program_idx(), term()}]} | nil,
          evaluation_cache: term() | nil,
          adapter_state: map(),
          budget_hooks: [(non_neg_integer(), non_neg_integer() -> term())],
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
    prog_candidate_objective_scores: [],
    frontier_type: :instance,
    objective_pareto_front: %{},
    program_at_pareto_front_objectives: %{},
    pareto_front_cartesian: %{},
    program_at_pareto_front_cartesian: %{},
    named_predictor_id_to_update_next_for_program_candidate: [],
    i: -1,
    num_full_ds_evals: 1,
    total_num_evals: 0,
    num_metric_calls_by_discovery: [0],
    full_program_trace: [],
    best_outputs_valset: nil,
    evaluation_cache: nil,
    adapter_state: %{},
    budget_hooks: [],
    validation_schema_version: @validation_schema_version
  ]

  @doc """
  Create new state from seed candidate and initial evaluation.

  ## Parameters

  - `seed_candidate`: Initial program as map of component name -> text
  - `eval_batch`: Results from evaluating seed on validation set
  - `valset_ids`: List of validation example IDs

  ## Returns

  New `GEPA.State` struct initialized with seed program
  """
  @spec new(Types.candidate(), GEPA.EvaluationBatch.t(), [Types.data_id()], Keyword.t()) :: t()
  def new(seed_candidate, eval_batch, valset_ids, opts \\ []) do
    frontier_type = Keyword.get(opts, :frontier_type, :instance)
    objective_scores_by_val_id = objective_scores_by_val_id(eval_batch, valset_ids)
    validate_frontier_objective_scores!(frontier_type, objective_scores_by_val_id)

    # Get component names (sorted for determinism)
    component_names = Map.keys(seed_candidate) |> Enum.sort()

    # Create initial Pareto fronts from seed scores
    {pareto_front, program_at_pareto_front} =
      valset_ids
      |> Enum.zip(eval_batch.scores)
      |> Enum.reduce({%{}, %{}}, fn {val_id, score}, {fronts, programs} ->
        {
          Map.put(fronts, val_id, score),
          Map.put(programs, val_id, MapSet.new([0]))
        }
      end)

    # Create sparse scores map for seed program
    seed_scores =
      valset_ids
      |> Enum.zip(eval_batch.scores)
      |> Enum.into(%{})

    objective_scores = aggregate_objective_scores(objective_scores_by_val_id)

    {cartesian_front, cartesian_programs} =
      cartesian_frontier(objective_scores_by_val_id, frontier_type, 0)

    best_outputs =
      if Keyword.get(opts, :track_best_outputs, false) do
        valset_ids
        |> Enum.zip(eval_batch.outputs)
        |> Map.new(fn {val_id, output} -> {val_id, [{0, output}]} end)
      end

    %__MODULE__{
      program_candidates: [seed_candidate],
      parent_program_for_candidate: [[nil]],
      prog_candidate_val_subscores: [seed_scores],
      prog_candidate_objective_scores: [objective_scores],
      frontier_type: frontier_type,
      pareto_front_valset: pareto_front,
      program_at_pareto_front_valset: program_at_pareto_front,
      objective_pareto_front: objective_scores,
      program_at_pareto_front_objectives:
        Map.new(objective_scores, fn {objective, _score} -> {objective, MapSet.new([0])} end),
      pareto_front_cartesian: cartesian_front,
      program_at_pareto_front_cartesian: cartesian_programs,
      list_of_named_predictors: component_names,
      named_predictor_id_to_update_next_for_program_candidate: [0],
      i: -1,
      num_full_ds_evals: 1,
      total_num_evals: eval_batch.num_metric_calls || length(valset_ids),
      num_metric_calls_by_discovery: [0],
      full_program_trace: [],
      best_outputs_valset: best_outputs,
      evaluation_cache: Keyword.get(opts, :evaluation_cache),
      adapter_state: Keyword.get(opts, :adapter_state, %{}),
      budget_hooks: [],
      validation_schema_version: @validation_schema_version
    }
  end

  @doc "Return the current persisted state schema version."
  @spec validation_schema_version() :: pos_integer()
  def validation_schema_version, do: @validation_schema_version

  @doc "Return whether the state has internally consistent candidate-indexed fields."
  @spec consistent?(t()) :: boolean()
  def consistent?(%__MODULE__{} = state) do
    candidate_count = length(state.program_candidates)
    val_front_keys = state.pareto_front_valset |> Map.keys() |> MapSet.new()
    val_program_keys = state.program_at_pareto_front_valset |> Map.keys() |> MapSet.new()
    objective_keys = state.objective_pareto_front |> Map.keys() |> MapSet.new()

    objective_program_keys =
      state.program_at_pareto_front_objectives |> Map.keys() |> MapSet.new()

    candidate_count == length(state.parent_program_for_candidate) and
      candidate_count == length(state.named_predictor_id_to_update_next_for_program_candidate) and
      candidate_count == length(state.prog_candidate_val_subscores) and
      candidate_count == length(state.prog_candidate_objective_scores) and
      candidate_count == length(state.num_metric_calls_by_discovery) and
      val_front_keys == val_program_keys and
      objective_keys == objective_program_keys and
      Enum.all?(state.program_at_pareto_front_valset, fn {_val_id, front} ->
        Enum.all?(front, &(&1 < candidate_count))
      end)
  end

  @doc """
  Add a runtime-only budget hook.

  Hooks are invoked by `increment_evals/2` and intentionally omitted from
  persisted state.
  """
  @spec add_budget_hook(t(), (non_neg_integer(), non_neg_integer() -> term())) :: t()
  def add_budget_hook(%__MODULE__{} = state, hook) when is_function(hook, 2) do
    %{state | budget_hooks: state.budget_hooks ++ [hook]}
  end

  @doc "Increment metric evaluation count and notify budget hooks."
  @spec increment_evals(t(), non_neg_integer()) :: t()
  def increment_evals(%__MODULE__{} = state, count) when is_integer(count) and count >= 0 do
    new_total = state.total_num_evals + count
    Enum.each(state.budget_hooks, & &1.(new_total, count))
    %{state | total_num_evals: new_total}
  end

  @doc """
  Persist state to a run directory.

  GEPA Ex writes `gepa_state.etf` instead of upstream Python's pickle-based
  `gepa_state.bin`, and also writes human-readable `candidates.json` and
  `run_log.json` when available.
  """
  @spec save(t(), Path.t() | nil, keyword()) :: :ok
  def save(state, run_dir, opts \\ [])
  def save(%__MODULE__{}, nil, _opts), do: :ok

  def save(%__MODULE__{} = state, run_dir, _opts) when is_binary(run_dir) do
    File.mkdir_p!(run_dir)

    state = %{state | budget_hooks: [], validation_schema_version: @validation_schema_version}

    File.write!(Path.join(run_dir, @state_file), :erlang.term_to_binary(state, [:compressed]))
    write_json_atomic(Path.join(run_dir, "candidates.json"), state.program_candidates)

    if state.full_program_trace != [] do
      write_json_atomic(Path.join(run_dir, "run_log.json"), state.full_program_trace)
    end

    :ok
  end

  @doc "Load persisted state from a run directory."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(run_dir) when is_binary(run_dir) do
    with {:ok, path} <- state_file_path(run_dir),
         {:ok, data} <- File.read(path) do
      decode_state(data)
    end
  end

  @doc "Load persisted state from a run directory or raise."
  @spec load!(Path.t()) :: t()
  def load!(run_dir) do
    case load(run_dir) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "could not load GEPA state: #{inspect(reason)}"
    end
  end

  @doc """
  Upgrade a persisted state dictionary into the current `GEPA.State` struct.

  Accepts atom or string keys and migrates legacy list-shaped validation fields
  to sparse maps.
  """
  @spec upgrade_dict(map()) :: t()
  def upgrade_dict(data) when is_map(data), do: from_dict(data)

  @doc "Build state from a persisted dictionary or legacy map payload."
  @spec from_dict(map()) :: t()
  def from_dict(data) when is_map(data) do
    program_candidates = dict_get(data, :program_candidates, [])
    candidate_count = length(program_candidates)

    struct(__MODULE__, %{
      program_candidates: program_candidates,
      parent_program_for_candidate:
        dict_get(data, :parent_program_for_candidate, default_parents(candidate_count)),
      prog_candidate_val_subscores:
        upcast_val_subscores(dict_get(data, :prog_candidate_val_subscores, [])),
      prog_candidate_objective_scores:
        dict_get(data, :prog_candidate_objective_scores, List.duplicate(%{}, candidate_count)),
      frontier_type: normalize_frontier_type(dict_get(data, :frontier_type, :instance)),
      pareto_front_valset: upcast_indexed_map(dict_get(data, :pareto_front_valset, %{})),
      program_at_pareto_front_valset:
        mapset_fronts(dict_get(data, :program_at_pareto_front_valset, %{})),
      objective_pareto_front: dict_get(data, :objective_pareto_front, %{}),
      program_at_pareto_front_objectives:
        mapset_fronts(dict_get(data, :program_at_pareto_front_objectives, %{})),
      pareto_front_cartesian: dict_get(data, :pareto_front_cartesian, %{}),
      program_at_pareto_front_cartesian:
        mapset_fronts(dict_get(data, :program_at_pareto_front_cartesian, %{})),
      list_of_named_predictors:
        dict_get(data, :list_of_named_predictors, predictors_from(program_candidates)),
      named_predictor_id_to_update_next_for_program_candidate:
        dict_get(
          data,
          :named_predictor_id_to_update_next_for_program_candidate,
          List.duplicate(0, candidate_count)
        ),
      i: dict_get(data, :i, -1),
      num_full_ds_evals: dict_get(data, :num_full_ds_evals, 1),
      total_num_evals: dict_get(data, :total_num_evals, dict_get(data, :total_metric_calls, 0)),
      num_metric_calls_by_discovery:
        dict_get(data, :num_metric_calls_by_discovery, List.duplicate(0, candidate_count)),
      full_program_trace: dict_get(data, :full_program_trace, []),
      best_outputs_valset: upcast_indexed_map(dict_get(data, :best_outputs_valset)),
      evaluation_cache: dict_get(data, :evaluation_cache),
      adapter_state: dict_get(data, :adapter_state, %{}),
      budget_hooks: [],
      validation_schema_version: @validation_schema_version
    })
  end

  @doc "Return validation ids and program indices that have evaluated them."
  @spec valset_evaluations(t()) :: %{Types.data_id() => [Types.program_idx()]}
  def valset_evaluations(%__MODULE__{} = state) do
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {scores, program_idx}, acc ->
      Enum.reduce(scores, acc, fn {val_id, _score}, inner_acc ->
        Map.update(inner_acc, val_id, [program_idx], &(&1 ++ [program_idx]))
      end)
    end)
  end

  @doc "Write generated validation outputs to the run-directory inspection tree."
  @spec write_valset_outputs(
          Path.t() | nil,
          [Types.data_id()],
          [term()],
          integer(),
          Types.program_idx()
        ) :: :ok
  def write_valset_outputs(nil, _valset_ids, _outputs, _iteration, _program_idx), do: :ok

  def write_valset_outputs(run_dir, valset_ids, outputs, iteration, program_idx)
      when is_binary(run_dir) do
    base = Path.join(run_dir, "generated_best_outputs_valset")

    valset_ids
    |> Enum.zip(outputs)
    |> Enum.each(fn {val_id, output} ->
      path =
        Path.join([
          base,
          "task_#{val_id}",
          "iter_#{iteration}_prog_#{program_idx}.json"
        ])

      write_json_atomic(path, output)
    end)

    :ok
  end

  @doc """
  Add a new program to the state and update Pareto fronts.

  ## Parameters

  - `state`: Current state
  - `new_candidate`: New program to add
  - `parent_program_ids`: List of parent indices
  - `val_scores`: Map of val_id -> score for new program

  ## Returns

  `{new_state, new_program_idx}` tuple
  """
  @spec add_program(
          t(),
          Types.candidate(),
          [Types.program_idx()],
          Types.sparse_scores(),
          Keyword.t()
        ) ::
          {t(), Types.program_idx()}
  def add_program(state, new_candidate, parent_program_ids, val_scores, opts \\ []) do
    new_idx = length(state.program_candidates)
    objective_scores_by_val_id = Keyword.get(opts, :objective_scores_by_val_id)
    validate_frontier_objective_scores!(state.frontier_type, objective_scores_by_val_id)
    objective_scores = aggregate_objective_scores(objective_scores_by_val_id)
    outputs_by_val_id = Keyword.get(opts, :outputs_by_val_id, %{})
    metric_calls = Keyword.get(opts, :metric_calls, map_size(val_scores))

    pareto_context = %{
      outputs_by_val_id: outputs_by_val_id,
      program_idx: new_idx,
      run_dir: Keyword.get(opts, :run_dir),
      iteration: Keyword.get(opts, :iteration, state.i + 1)
    }

    # Update Pareto fronts for all scored validation examples
    {new_pareto_front, new_pareto_programs, best_outputs} =
      Enum.reduce(
        val_scores,
        {state.pareto_front_valset, state.program_at_pareto_front_valset,
         state.best_outputs_valset},
        fn {val_id, score}, {fronts, programs, best_outputs_acc} ->
          {fronts, programs, best_outputs_acc} =
            update_pareto_front_for_val(
              fronts,
              programs,
              best_outputs_acc,
              val_id,
              score,
              pareto_context
            )

          {fronts, programs, best_outputs_acc}
        end
      )

    {objective_front, objective_programs} =
      update_objective_pareto_front(
        state.objective_pareto_front,
        state.program_at_pareto_front_objectives,
        objective_scores,
        new_idx
      )

    {cartesian_front, cartesian_programs} =
      update_cartesian_pareto_front(
        state.pareto_front_cartesian,
        state.program_at_pareto_front_cartesian,
        objective_scores_by_val_id,
        state.frontier_type,
        new_idx
      )

    next_component_pointer =
      parent_program_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Enum.at(state.named_predictor_id_to_update_next_for_program_candidate, &1, 0))
      |> Enum.max(fn -> 0 end)

    new_state = %{
      state
      | program_candidates: state.program_candidates ++ [new_candidate],
        parent_program_for_candidate: state.parent_program_for_candidate ++ [parent_program_ids],
        prog_candidate_val_subscores: state.prog_candidate_val_subscores ++ [val_scores],
        prog_candidate_objective_scores:
          state.prog_candidate_objective_scores ++ [objective_scores],
        pareto_front_valset: new_pareto_front,
        program_at_pareto_front_valset: new_pareto_programs,
        objective_pareto_front: objective_front,
        program_at_pareto_front_objectives: objective_programs,
        pareto_front_cartesian: cartesian_front,
        program_at_pareto_front_cartesian: cartesian_programs,
        best_outputs_valset: best_outputs,
        named_predictor_id_to_update_next_for_program_candidate:
          state.named_predictor_id_to_update_next_for_program_candidate ++
            [next_component_pointer],
        num_full_ds_evals: state.num_full_ds_evals + 1,
        total_num_evals: state.total_num_evals + metric_calls,
        num_metric_calls_by_discovery:
          state.num_metric_calls_by_discovery ++ [state.total_num_evals]
    }

    {new_state, new_idx}
  end

  @doc """
  Get average score for a program across evaluated validation examples.

  ## Returns

  `{average_score, count}` tuple
  """
  @spec get_program_score(t(), Types.program_idx()) :: {float(), non_neg_integer()}
  def get_program_score(state, program_idx) do
    scores = Enum.at(state.prog_candidate_val_subscores, program_idx, %{})

    if map_size(scores) == 0 do
      {0.0, 0}
    else
      score_values = Map.values(scores)
      avg = Enum.sum(score_values) / length(score_values)
      {avg, length(score_values)}
    end
  end

  @doc "Return average validation score and evaluated-count for a program."
  @spec get_program_average_val_subset(t(), Types.program_idx()) :: {float(), non_neg_integer()}
  def get_program_average_val_subset(state, program_idx),
    do: get_program_score(state, program_idx)

  @doc "Return the active Pareto-front mapping for the configured frontier type."
  @spec get_pareto_front_mapping(t()) :: map()
  def get_pareto_front_mapping(%__MODULE__{frontier_type: :objective} = state) do
    state.program_at_pareto_front_objectives
  end

  def get_pareto_front_mapping(%__MODULE__{frontier_type: :cartesian} = state) do
    state.program_at_pareto_front_cartesian
  end

  def get_pareto_front_mapping(%__MODULE__{frontier_type: :hybrid} = state) do
    Map.merge(
      tag_front_keys(state.program_at_pareto_front_valset, :instance),
      tag_front_keys(state.program_at_pareto_front_objectives, :objective)
    )
  end

  def get_pareto_front_mapping(%__MODULE__{} = state), do: state.program_at_pareto_front_valset

  @doc "Return per-program average validation scores in candidate-index order."
  @spec tracked_scores(t()) :: [float()]
  def tracked_scores(%__MODULE__{} = state) do
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {_scores, idx} -> elem(get_program_score(state, idx), 0) end)
  end

  defp state_file_path(run_dir) do
    etf_path = Path.join(run_dir, @state_file)
    legacy_path = Path.join(run_dir, @legacy_state_file)

    cond do
      File.exists?(etf_path) -> {:ok, etf_path}
      File.exists?(legacy_path) -> {:ok, legacy_path}
      true -> {:error, :enoent}
    end
  end

  defp decode_state(data) do
    data
    |> :erlang.binary_to_term()
    |> state_from_term()
  rescue
    exception -> {:error, {:invalid_state_file, Exception.message(exception)}}
  end

  defp state_from_term(%__MODULE__{} = state),
    do: {:ok, state |> Map.from_struct() |> from_dict()}

  defp state_from_term(%{} = data), do: {:ok, from_dict(data)}
  defp state_from_term(other), do: {:error, {:invalid_state_payload, other}}

  defp default_parents(0), do: []
  defp default_parents(candidate_count), do: [[nil] | List.duplicate([], candidate_count - 1)]

  defp predictors_from([%{} = candidate | _]) do
    candidate
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp predictors_from(_program_candidates), do: []

  defp normalize_frontier_type(value) when value in [:instance, "instance"], do: :instance
  defp normalize_frontier_type(value) when value in [:objective, "objective"], do: :objective
  defp normalize_frontier_type(value) when value in [:hybrid, "hybrid"], do: :hybrid
  defp normalize_frontier_type(value) when value in [:cartesian, "cartesian"], do: :cartesian
  defp normalize_frontier_type(_value), do: :instance

  defp dict_get(data, key, default \\ nil) do
    Map.get(data, key, Map.get(data, Atom.to_string(key), default))
  end

  defp upcast_val_subscores(values) when is_list(values) do
    Enum.map(values, fn
      %{} = scores -> normalize_indexed_map(scores)
      scores when is_list(scores) -> list_to_indexed_map(scores)
    end)
  end

  defp upcast_val_subscores(values), do: values

  defp upcast_indexed_map(nil), do: nil
  defp upcast_indexed_map(values) when is_list(values), do: list_to_indexed_map(values)
  defp upcast_indexed_map(values) when is_map(values), do: normalize_indexed_map(values)
  defp upcast_indexed_map(values), do: values

  defp list_to_indexed_map(values) do
    values
    |> Enum.with_index()
    |> Map.new(fn {value, idx} -> {idx, value} end)
  end

  defp normalize_indexed_map(values) do
    Map.new(values, fn {key, value} -> {normalize_index_key(key), value} end)
  end

  defp normalize_index_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {integer, ""} -> integer
      _other -> key
    end
  end

  defp normalize_index_key(key), do: key

  defp mapset_fronts(nil), do: %{}

  defp mapset_fronts(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Map.new(fn {front, idx} -> {idx, normalize_front_value(front)} end)
  end

  defp mapset_fronts(values) when is_map(values) do
    Map.new(values, fn {key, front} ->
      {normalize_index_key(key), normalize_front_value(front)}
    end)
  end

  defp normalize_front_value(%MapSet{} = front), do: front
  defp normalize_front_value(front) when is_list(front), do: MapSet.new(front)
  defp normalize_front_value(front), do: MapSet.new([front])

  defp write_json_atomic(path, data) do
    path |> Path.dirname() |> File.mkdir_p!()
    tmp_path = path <> ".tmp"
    File.write!(tmp_path, Jason.encode!(json_safe(data), pretty: true))
    File.rename!(tmp_path, path)
  end

  defp json_safe(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, inner_value} -> {json_key(key), json_safe(inner_value)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key) or is_binary(key), do: key
  defp json_key(key), do: to_string(key)

  defp tag_front_keys(fronts, tag) do
    Map.new(fronts, fn {key, value} -> {{tag, key}, value} end)
  end

  # Private helper to update Pareto front for a single validation example
  defp objective_scores_by_val_id(%GEPA.EvaluationBatch{objective_scores: nil}, _valset_ids),
    do: nil

  defp objective_scores_by_val_id(%GEPA.EvaluationBatch{objective_scores: scores}, valset_ids)
       when is_list(scores) do
    valset_ids
    |> Enum.zip(scores)
    |> Map.new()
  end

  defp aggregate_objective_scores(nil), do: %{}

  defp aggregate_objective_scores(objective_scores_by_val_id)
       when objective_scores_by_val_id == %{},
       do: %{}

  defp aggregate_objective_scores(objective_scores_by_val_id)
       when is_map(objective_scores_by_val_id) do
    {totals, counts} =
      Enum.reduce(objective_scores_by_val_id, {%{}, %{}}, fn {_val_id, scores},
                                                             {totals, counts} ->
        Enum.reduce(scores, {totals, counts}, fn {objective, score}, {totals_acc, counts_acc} ->
          {
            Map.update(totals_acc, objective, score, &(&1 + score)),
            Map.update(counts_acc, objective, 1, &(&1 + 1))
          }
        end)
      end)

    Map.new(totals, fn {objective, total} -> {objective, total / counts[objective]} end)
  end

  defp validate_frontier_objective_scores!(frontier_type, objective_scores_by_val_id)
       when frontier_type in [:objective, :hybrid, :cartesian] do
    if objective_scores_by_val_id in [nil, %{}] do
      raise ArgumentError,
            "frontier_type=#{inspect(frontier_type)} requires objective_scores to be provided"
    end
  end

  defp validate_frontier_objective_scores!(_frontier_type, _objective_scores_by_val_id), do: :ok

  defp cartesian_frontier(objective_scores_by_val_id, :cartesian, program_idx)
       when is_map(objective_scores_by_val_id) do
    Enum.reduce(objective_scores_by_val_id, {%{}, %{}}, fn {val_id, scores}, {fronts, programs} ->
      Enum.reduce(scores, {fronts, programs}, fn {objective, score}, {fronts_acc, programs_acc} ->
        key = {val_id, objective}
        {Map.put(fronts_acc, key, score), Map.put(programs_acc, key, MapSet.new([program_idx]))}
      end)
    end)
  end

  defp cartesian_frontier(_objective_scores_by_val_id, _frontier_type, _program_idx),
    do: {%{}, %{}}

  defp update_pareto_front_for_val(
         fronts,
         programs,
         best_outputs,
         val_id,
         score,
         context
       ) do
    prev_score = Map.get(fronts, val_id, :neg_infinity)
    program_idx = context.program_idx
    output = Map.get(context.outputs_by_val_id, val_id)

    cond do
      score > prev_score ->
        # New best score - replace front
        maybe_write_best_output(
          best_outputs,
          context.run_dir,
          val_id,
          program_idx,
          output,
          context.iteration
        )

        {
          Map.put(fronts, val_id, score),
          Map.put(programs, val_id, MapSet.new([program_idx])),
          put_best_output(best_outputs, val_id, program_idx, output, :replace)
        }

      score == prev_score ->
        # Tie - add to front
        {
          fronts,
          Map.update(programs, val_id, MapSet.new([program_idx]), &MapSet.put(&1, program_idx)),
          put_best_output(best_outputs, val_id, program_idx, output, :append)
        }

      true ->
        # Worse score - no update
        {fronts, programs, best_outputs}
    end
  end

  defp put_best_output(nil, _val_id, _program_idx, _output, _mode), do: nil
  defp put_best_output(best_outputs, _val_id, _program_idx, nil, _mode), do: best_outputs

  defp put_best_output(best_outputs, val_id, program_idx, output, :replace) do
    Map.put(best_outputs, val_id, [{program_idx, output}])
  end

  defp put_best_output(best_outputs, val_id, program_idx, output, :append) do
    Map.update(best_outputs, val_id, [{program_idx, output}], &(&1 ++ [{program_idx, output}]))
  end

  defp maybe_write_best_output(nil, _run_dir, _val_id, _program_idx, _output, _iteration), do: :ok

  defp maybe_write_best_output(_best_outputs, _run_dir, _val_id, _program_idx, nil, _iteration),
    do: :ok

  defp maybe_write_best_output(_best_outputs, run_dir, val_id, program_idx, output, iteration) do
    write_valset_outputs(run_dir, [val_id], [output], iteration, program_idx)
  end

  defp update_objective_pareto_front(fronts, programs, objective_scores, program_idx) do
    Enum.reduce(objective_scores, {fronts, programs}, fn {objective, score},
                                                         {fronts_acc, programs_acc} ->
      prev_score = Map.get(fronts_acc, objective, :neg_infinity)

      cond do
        score > prev_score ->
          {Map.put(fronts_acc, objective, score),
           Map.put(programs_acc, objective, MapSet.new([program_idx]))}

        score == prev_score ->
          {fronts_acc,
           Map.update(
             programs_acc,
             objective,
             MapSet.new([program_idx]),
             &MapSet.put(&1, program_idx)
           )}

        true ->
          {fronts_acc, programs_acc}
      end
    end)
  end

  defp update_cartesian_pareto_front(
         fronts,
         programs,
         objective_scores_by_val_id,
         :cartesian,
         program_idx
       )
       when is_map(objective_scores_by_val_id) do
    Enum.reduce(objective_scores_by_val_id, {fronts, programs}, fn {val_id, objective_scores},
                                                                   acc ->
      Enum.reduce(objective_scores, acc, fn {objective, score}, inner_acc ->
        update_cartesian_objective(inner_acc, {val_id, objective}, score, program_idx)
      end)
    end)
  end

  defp update_cartesian_pareto_front(
         fronts,
         programs,
         _objective_scores_by_val_id,
         _frontier_type,
         _program_idx
       ) do
    {fronts, programs}
  end

  defp update_cartesian_objective({fronts, programs}, key, score, program_idx) do
    prev_score = Map.get(fronts, key, :neg_infinity)

    cond do
      score > prev_score ->
        {Map.put(fronts, key, score), Map.put(programs, key, MapSet.new([program_idx]))}

      score == prev_score ->
        {fronts,
         Map.update(programs, key, MapSet.new([program_idx]), &MapSet.put(&1, program_idx))}

      true ->
        {fronts, programs}
    end
  end
end
