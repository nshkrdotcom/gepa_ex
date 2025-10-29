defmodule GEPA.Utils do
  @moduledoc """
  Utility functions for GEPA optimization.

  Includes functions for:
  - Pareto front analysis
  - Program domination detection
  - Merge proposer utilities
  """

  @doc """
  Checks if a program is dominated by other programs across all Pareto fronts.

  A program is dominated if, on every validation front it appears on,
  there exists at least one program from the `dominating_programs` set.

  ## Parameters
    - `program` - Program ID to check
    - `dominating_programs` - Set of potentially dominating program IDs
    - `pareto_front` - Map of val_id => MapSet of program IDs on Pareto front

  ## Returns
    - `true` if program is dominated on all its fronts
    - `false` if program is alone on at least one front

  ## Examples

      pareto_front = %{
        0 => MapSet.new([0, 1]),
        1 => MapSet.new([0, 2])
      }

      # Program 0 appears on fronts 0 and 1
      # If programs 1 and 2 are considered dominating:
      # - On front 0: program 1 exists (dominated)
      # - On front 1: program 2 exists (dominated)
      # Result: program 0 is dominated

      GEPA.Utils.is_dominated?(0, MapSet.new([1, 2]), pareto_front)
      # => true
  """
  @spec is_dominated?(
          program :: non_neg_integer(),
          dominating_programs :: MapSet.t(non_neg_integer()),
          pareto_front :: %{term() => MapSet.t(non_neg_integer())}
        ) :: boolean()
  def is_dominated?(program, dominating_programs, pareto_front) do
    # Find all fronts this program appears on
    program_fronts =
      pareto_front
      |> Enum.reduce([], fn {val_id, front}, acc ->
        if is_struct(front, MapSet) and MapSet.member?(front, program) do
          [{val_id, front} | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    # If program doesn't appear on any front, consider it dominated
    if Enum.empty?(program_fronts) do
      true
    else
      # Check if on EVERY front this program appears, there's a dominating program
      Enum.all?(program_fronts, fn {_val_id, front} ->
        # Does this front contain at least one dominating program?
        MapSet.intersection(front, dominating_programs)
        |> MapSet.size() > 0
      end)
    end
  end

  @doc """
  Removes dominated programs from Pareto fronts.

  Iteratively removes programs that are dominated across all fronts they appear on.
  A program is dominated if better programs exist on every front.

  ## Parameters
    - `pareto_front` - Map of val_id => MapSet of program indices
    - `scores` - Map of program_idx => score (higher is better)

  ## Returns
    - New Pareto front map with dominated programs removed

  ## Algorithm
    1. Find all programs on any front
    2. Sort by score (ascending)
    3. Iteratively check if each can be dominated by higher-scoring programs
    4. Remove dominated programs from all fronts
  """
  @spec remove_dominated_programs(
          pareto_front :: %{term() => MapSet.t(non_neg_integer())},
          scores :: %{non_neg_integer() => float()}
        ) :: %{term() => MapSet.t(non_neg_integer())}
  def remove_dominated_programs(pareto_front, _scores) when pareto_front == %{} do
    %{}
  end

  def remove_dominated_programs(pareto_front, scores) do
    # Count frequency of each program across all fronts
    all_programs =
      pareto_front
      |> Map.values()
      |> Enum.reduce(MapSet.new(), fn front, acc ->
        if is_struct(front, MapSet) do
          MapSet.union(acc, front)
        else
          acc
        end
      end)
      |> MapSet.to_list()

    # Sort programs by score (ascending) - check weakest first
    sorted_programs = Enum.sort_by(all_programs, &Map.get(scores, &1, 0))

    # Iteratively find dominated programs
    dominated = find_dominated_programs(sorted_programs, pareto_front, scores, [])
    dominated_set = MapSet.new(dominated)

    new_pareto_front =
      pareto_front
      |> Enum.map(fn {val_id, front} ->
        new_front =
          if is_struct(front, MapSet) do
            MapSet.difference(front, dominated_set)
          else
            front
          end

        {val_id, new_front}
      end)
      |> Enum.into(%{})

    new_pareto_front
  end

  # Iteratively find dominated programs
  defp find_dominated_programs([], _pareto_front, _scores, dominated), do: dominated

  defp find_dominated_programs([program | rest], pareto_front, scores, dominated) do
    # Skip if already dominated
    if Enum.member?(dominated, program) do
      find_dominated_programs(rest, pareto_front, scores, dominated)
    else
      # Only consider programs with STRICTLY HIGHER scores as potential dominators
      program_score = Map.get(scores, program, 0)

      potential_dominators =
        rest
        |> Enum.filter(fn p ->
          not Enum.member?(dominated, p) and Map.get(scores, p, 0) > program_score
        end)
        |> MapSet.new()

      # A program is dominated only if better programs exist on ALL its fronts
      if MapSet.size(potential_dominators) > 0 and
           is_dominated?(program, potential_dominators, pareto_front) do
        # This program is dominated
        find_dominated_programs(rest, pareto_front, scores, [program | dominated])
      else
        # This program is NOT dominated - it's a dominator
        find_dominated_programs(rest, pareto_front, scores, dominated)
      end
    end
  end

  @doc """
  Finds programs that dominate others on the Pareto front.

  This is the main entry point used by the merge proposer.

  ## Parameters
    - `pareto_front_programs` - Map of val_id => set of program indices
    - `program_scores` - Map of program_idx => aggregate score

  ## Returns
    - List of program indices that are dominators (not dominated by others)

  ## Examples

      pareto_front = %{
        0 => MapSet.new([0, 1, 2]),
        1 => MapSet.new([1, 2])
      }

      scores = %{0 => 0.5, 1 => 0.7, 2 => 0.9}

      GEPA.Utils.find_dominator_programs(pareto_front, scores)
      # => [2, 1]  (sorted by score, descending)
  """
  @spec find_dominator_programs(
          pareto_front_programs :: %{term() => MapSet.t(non_neg_integer())},
          program_scores :: %{non_neg_integer() => float()}
        ) :: [non_neg_integer()]
  def find_dominator_programs(pareto_front_programs, _program_scores)
      when pareto_front_programs == %{} do
    []
  end

  def find_dominator_programs(pareto_front_programs, program_scores) do
    # Remove dominated programs from fronts
    cleaned_fronts = remove_dominated_programs(pareto_front_programs, program_scores)

    # Collect all unique programs from cleaned fronts
    dominators =
      cleaned_fronts
      |> Map.values()
      |> Enum.reduce(MapSet.new(), fn front, acc ->
        if is_struct(front, MapSet) do
          MapSet.union(acc, front)
        else
          acc
        end
      end)
      |> MapSet.to_list()

    # Return sorted by score (descending)
    Enum.sort_by(dominators, fn p -> -Map.get(program_scores, p, 0) end)
  end
end
