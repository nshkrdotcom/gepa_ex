defmodule GEPA.Strategies.EvaluationPolicy do
  @moduledoc """
  Behavior for validation evaluation policies.

  Determines which validation examples to evaluate and how to score programs.
  """

  @doc """
  Get validation batch IDs to evaluate for a program.
  """
  @callback get_eval_batch(GEPA.DataLoader.t(), GEPA.State.t(), non_neg_integer() | nil) ::
              [term()]

  @doc """
  Get the index of the best program given current evaluations.
  """
  @callback get_best_program(GEPA.State.t()) :: non_neg_integer()

  @doc """
  Get the validation score for a specific program.
  """
  @callback get_valset_score(non_neg_integer(), GEPA.State.t()) :: float()
end

defmodule GEPA.Strategies.EvaluationPolicy.Full do
  @moduledoc """
  Always evaluates all validation examples.

  Simple and thorough, but can be expensive for large validation sets.
  """

  @behaviour GEPA.Strategies.EvaluationPolicy

  @impl true
  @spec get_eval_batch(GEPA.DataLoader.t(), GEPA.State.t(), non_neg_integer() | nil) :: [term()]
  def get_eval_batch(valset_loader, _state, _target_program_idx) do
    GEPA.DataLoader.all_ids(valset_loader)
  end

  @impl true
  @spec get_best_program(GEPA.State.t()) :: non_neg_integer()
  def get_best_program(state) do
    # Find program with highest average score, with coverage tie-breaking
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {scores, idx} ->
      {avg, coverage} = calculate_avg_and_coverage(scores)
      {idx, avg, coverage}
    end)
    |> Enum.max_by(fn {_idx, avg, coverage} -> {avg, coverage} end)
    |> elem(0)
  end

  @impl true
  @spec get_valset_score(non_neg_integer(), GEPA.State.t()) :: float()
  def get_valset_score(program_idx, state) do
    {avg, _count} = GEPA.State.get_program_score(state, program_idx)
    avg
  end

  @doc """
  Calculate average score and coverage from a scores map.

  Returns a tuple of `{average, count}` where average is the mean of all scores
  and count is the number of scores evaluated.

  ## Examples

      iex> calculate_avg_and_coverage(%{})
      {0.0, 0}

      iex> calculate_avg_and_coverage(%{1 => 0.8, 2 => 0.9, 3 => 0.7})
      {0.8, 3}
  """
  @spec calculate_avg_and_coverage(%{optional(term()) => number()}) ::
          {float(), non_neg_integer()}
  def calculate_avg_and_coverage(scores) when map_size(scores) == 0 do
    {0.0, 0}
  end

  def calculate_avg_and_coverage(scores) do
    values = Map.values(scores)
    avg = Enum.sum(values) / length(values)
    {avg, length(values)}
  end
end

defmodule GEPA.Strategies.EvaluationPolicy.Incremental do
  @moduledoc """
  Incremental evaluation policy - progressively evaluates validation set.

  Starts with a small sample and expands for promising candidates.
  Reduces computation by avoiding full evaluation for poor candidates.

  ## Options

    - `:initial_sample_size` - Starting sample size (default: 10)
    - `:increment_size` - Samples to add each time (default: 5)
    - `:max_sample_size` - Max before full eval (default: 50)
    - `:full_eval_threshold` - Score threshold for full eval (default: 0.7)
    - `:seed` - Random seed (default: 0)
  """

  @behaviour GEPA.Strategies.EvaluationPolicy

  defstruct [
    :initial_sample_size,
    :increment_size,
    :max_sample_size,
    :full_eval_threshold,
    :seed,
    :evaluated_samples
  ]

  @type t :: %__MODULE__{
          initial_sample_size: pos_integer(),
          increment_size: pos_integer(),
          max_sample_size: pos_integer(),
          full_eval_threshold: float(),
          seed: integer(),
          evaluated_samples: %{non_neg_integer() => MapSet.t()}
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      initial_sample_size: Keyword.get(opts, :initial_sample_size, 10),
      increment_size: Keyword.get(opts, :increment_size, 5),
      max_sample_size: Keyword.get(opts, :max_sample_size, 50),
      full_eval_threshold: Keyword.get(opts, :full_eval_threshold, 0.7),
      seed: Keyword.get(opts, :seed, 0),
      evaluated_samples: %{}
    }
  end

  @spec select_samples(t(), non_neg_integer(), [term()]) :: {[term()], t()}
  def select_samples(%__MODULE__{} = policy, candidate_idx, available_samples) do
    previously_evaluated = Map.get(policy.evaluated_samples, candidate_idx, MapSet.new())
    num_previously = MapSet.size(previously_evaluated)

    sample_size =
      if num_previously == 0 do
        policy.initial_sample_size
      else
        min(num_previously + policy.increment_size, policy.max_sample_size)
      end

    selected =
      if num_previously == 0 do
        :rand.seed(:exsss, {policy.seed, candidate_idx, 0})
        Enum.take_random(available_samples, min(sample_size, length(available_samples)))
      else
        num_new = sample_size - num_previously

        available_new =
          Enum.filter(available_samples, &(!MapSet.member?(previously_evaluated, &1)))

        previous_list = MapSet.to_list(previously_evaluated)

        if num_new > 0 and length(available_new) > 0 do
          :rand.seed(:exsss, {policy.seed, candidate_idx, num_previously})
          new_samples = Enum.take_random(available_new, min(num_new, length(available_new)))
          previous_list ++ new_samples
        else
          previous_list
        end
      end

    {selected, policy}
  end

  @spec should_do_full_eval?(t(), non_neg_integer(), float()) :: boolean()
  def should_do_full_eval?(%__MODULE__{} = policy, candidate_idx, partial_score) do
    evaluated_count =
      Map.get(policy.evaluated_samples, candidate_idx, MapSet.new()) |> MapSet.size()

    evaluated_count >= policy.max_sample_size or partial_score >= policy.full_eval_threshold
  end

  @spec update_evaluated(t(), non_neg_integer(), [term()]) :: t()
  def update_evaluated(%__MODULE__{} = policy, candidate_idx, samples) do
    current = Map.get(policy.evaluated_samples, candidate_idx, MapSet.new())
    updated = MapSet.union(current, MapSet.new(samples))
    %{policy | evaluated_samples: Map.put(policy.evaluated_samples, candidate_idx, updated)}
  end

  @impl true
  @spec get_eval_batch(GEPA.DataLoader.t(), GEPA.State.t(), non_neg_integer() | nil) :: [term()]
  def get_eval_batch(_valset_loader, _state, _target_program_idx) do
    # For now, return all IDs (full implementation would use incremental logic)
    # This can be enhanced when integrated with Engine
    []
  end

  @impl true
  @spec get_best_program(GEPA.State.t()) :: non_neg_integer()
  def get_best_program(state) do
    # Same as Full policy
    state.prog_candidate_val_subscores
    |> Enum.with_index()
    |> Enum.map(fn {scores, idx} ->
      {avg, coverage} = GEPA.Strategies.EvaluationPolicy.Full.calculate_avg_and_coverage(scores)
      {idx, avg, coverage}
    end)
    |> Enum.max_by(fn {_idx, avg, coverage} -> {avg, coverage} end)
    |> elem(0)
  rescue
    _ -> 0
  end

  @impl true
  @spec get_valset_score(non_neg_integer(), GEPA.State.t()) :: float()
  def get_valset_score(program_idx, state) do
    {avg, _count} = GEPA.State.get_program_score(state, program_idx)
    avg
  end

  # Make calculate_avg_and_coverage public for reuse
  defdelegate calculate_avg_and_coverage(scores), to: GEPA.Strategies.EvaluationPolicy.Full
end
