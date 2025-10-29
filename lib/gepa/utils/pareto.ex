defmodule GEPA.Utils.Pareto do
  @moduledoc """
  Pareto optimization utilities for multi-objective candidate selection.

  These functions implement the core Pareto frontier logic that enables
  GEPA to maintain diverse solutions that excel on different validation examples.
  """

  alias GEPA.Types

  @doc """
  Check if a program is dominated by other programs.

  A program is dominated if, for every Pareto front it appears in,
  at least one of the candidate programs also appears in that front.

  ## Parameters

  - `program`: The program index to check
  - `other_programs`: List of candidate program indices
  - `fronts`: Pareto fronts mapping (data_id => set of program indices)

  ## Returns

  `true` if program is dominated, `false` otherwise

  ## Examples

      iex> fronts = %{"val1" => MapSet.new([0, 1]), "val2" => MapSet.new([0, 1])}
      iex> GEPA.Utils.Pareto.is_dominated?(1, [0], fronts)
      true

      iex> fronts = %{"val1" => MapSet.new([0, 1]), "val2" => MapSet.new([1])}
      iex> GEPA.Utils.Pareto.is_dominated?(1, [0], fronts)
      false
  """
  @spec is_dominated?(
          Types.program_idx(),
          [Types.program_idx()],
          Types.pareto_fronts()
        ) :: boolean()
  def is_dominated?(program, other_programs, program_at_pareto_front_valset) do
    # Find all fronts containing this program
    fronts_with_program =
      for {_id, front} <- program_at_pareto_front_valset,
          MapSet.member?(front, program),
          do: front

    # If program is not in any front, it's not dominated
    if fronts_with_program == [] do
      false
    else
      # Check if for every front, at least one other program is also in that front
      Enum.all?(fronts_with_program, fn front ->
        Enum.any?(other_programs, fn other ->
          other != program and MapSet.member?(front, other)
        end)
      end)
    end
  end

  @doc """
  Removes dominated programs from Pareto fronts.

  Iteratively eliminates programs that are dominated by others,
  returning cleaned Pareto fronts with only non-dominated programs.

  ## Parameters

  - `fronts`: Pareto fronts mapping
  - `scores`: Map of program_idx => aggregate score

  ## Returns

  Cleaned Pareto fronts with dominated programs removed

  ## Examples

      iex> fronts = %{"val1" => MapSet.new([0, 1]), "val2" => MapSet.new([1, 2])}
      iex> scores = %{0 => 0.9, 1 => 0.8, 2 => 0.85}
      iex> result = GEPA.Utils.Pareto.remove_dominated_programs(fronts, scores)
      iex> MapSet.member?(result["val1"], 0)
      true
  """
  @spec remove_dominated_programs(Types.pareto_fronts(), %{Types.program_idx() => float()}) ::
          Types.pareto_fronts()
  def remove_dominated_programs(program_at_pareto_front_valset, scores) do
    # Get all programs in any front
    all_programs =
      program_at_pareto_front_valset
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      |> MapSet.to_list()

    # Sort by score (ascending) - remove lower-scoring dominated first
    sorted_programs = Enum.sort_by(all_programs, &Map.get(scores, &1, 0.0))

    # Iteratively find and remove dominated programs
    dominated = do_eliminate(program_at_pareto_front_valset, sorted_programs, MapSet.new())

    # Build new fronts without dominated programs
    for {id, front} <- program_at_pareto_front_valset, into: %{} do
      {id, MapSet.difference(front, dominated)}
    end
  end

  # Recursive elimination of dominated programs
  defp do_eliminate(fronts, programs, dominated) do
    active_programs = Enum.reject(programs, &MapSet.member?(dominated, &1))

    case find_next_dominated(fronts, active_programs, dominated) do
      {:ok, prog} ->
        do_eliminate(fronts, programs, MapSet.put(dominated, prog))

      :none ->
        dominated
    end
  end

  defp find_next_dominated(fronts, active_programs, _dominated) do
    # Try to find a program that is dominated by the others
    Enum.find_value(active_programs, :none, fn prog ->
      others = active_programs -- [prog]

      if is_dominated?(prog, others, fronts) do
        {:ok, prog}
      else
        nil
      end
    end)
  end

  @doc """
  Selects a program from Pareto fronts using frequency-weighted sampling.

  Programs appearing in more Pareto fronts have higher probability of selection.

  ## Parameters

  - `fronts`: Pareto fronts mapping
  - `scores`: Map of program_idx => aggregate score
  - `rand_state`: Erlang random state

  ## Returns

  `{selected_program_idx, new_rand_state}`

  ## Examples

      iex> fronts = %{"val1" => MapSet.new([0, 1])}
      iex> scores = %{0 => 0.9, 1 => 0.8}
      iex> {selected, _} = GEPA.Utils.Pareto.select_from_pareto_front(fronts, scores, :rand.seed(:exsss, {1, 2, 3}))
      iex> selected in [0, 1]
      true
  """
  @spec select_from_pareto_front(
          Types.pareto_fronts(),
          %{Types.program_idx() => float()},
          :rand.state()
        ) :: {Types.program_idx(), :rand.state()}
  def select_from_pareto_front(program_at_pareto_front_valset, scores, rand_state) do
    # Remove dominated programs
    cleaned_fronts = remove_dominated_programs(program_at_pareto_front_valset, scores)

    # Count frequency of each program in cleaned fronts
    freq =
      Enum.reduce(cleaned_fronts, %{}, fn {_id, front}, acc ->
        Enum.reduce(front, acc, fn prog, acc2 ->
          Map.update(acc2, prog, 1, &(&1 + 1))
        end)
      end)

    # Handle edge case: if no programs in fronts, return program 0
    if map_size(freq) == 0 do
      # Fallback: return highest scoring program
      fallback_prog =
        scores
        |> Enum.max_by(fn {_prog, score} -> score end, fn -> {0, 0.0} end)
        |> elem(0)

      {fallback_prog, rand_state}
    else
      # Build weighted sampling list (programs repeated by frequency)
      sampling_list =
        for {prog, count} <- freq,
            _ <- 1..count,
            do: prog

      # Random selection
      {idx, new_rand} = :rand.uniform_s(length(sampling_list), rand_state)
      {Enum.at(sampling_list, idx - 1), new_rand}
    end
  end

  @doc """
  Returns the set of non-dominated programs.

  ## Parameters

  - `fronts`: Pareto fronts mapping
  - `scores`: Map of program_idx => aggregate score

  ## Returns

  List of program indices that are not dominated

  ## Examples

      iex> fronts = %{"val1" => MapSet.new([0]), "val2" => MapSet.new([1])}
      iex> scores = %{0 => 0.9, 1 => 0.8}
      iex> dominators = GEPA.Utils.Pareto.find_dominator_programs(fronts, scores)
      iex> Enum.sort(dominators)
      [0, 1]
  """
  @spec find_dominator_programs(Types.pareto_fronts(), %{Types.program_idx() => float()}) ::
          [Types.program_idx()]
  def find_dominator_programs(program_at_pareto_front_valset, scores) do
    cleaned_fronts = remove_dominated_programs(program_at_pareto_front_valset, scores)

    cleaned_fronts
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.to_list()
  end

  @doc """
  Helper to get all programs from fronts.
  """
  @spec get_all_programs(Types.pareto_fronts()) :: [Types.program_idx()]
  def get_all_programs(fronts) do
    fronts
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.to_list()
  end
end
