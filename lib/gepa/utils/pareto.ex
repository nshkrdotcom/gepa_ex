defmodule GEPA.Utils.Pareto do
  @moduledoc """
  Pareto-front utilities used for candidate selection and merge parent choice.

  The domination algorithm follows the official Python GEPA utility: a program
  is dominated when, for every Pareto front that contains it, another active
  program also appears on that front. Programs absent from every front are
  considered dominated/irrelevant.
  """

  alias GEPA.Types

  @spec is_dominated?(
          Types.program_idx(),
          [Types.program_idx()] | MapSet.t(),
          Types.pareto_fronts()
        ) ::
          boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_dominated?(program, other_programs, fronts) do
    other_programs = MapSet.new(other_programs)

    fronts_with_program =
      fronts
      |> Enum.flat_map(fn {_id, front} ->
        if mapset_member?(front, program), do: [front], else: []
      end)

    case fronts_with_program do
      [] ->
        true

      program_fronts ->
        Enum.all?(program_fronts, fn front ->
          front
          |> MapSet.delete(program)
          |> MapSet.intersection(other_programs)
          |> MapSet.size() > 0
        end)
    end
  end

  @spec remove_dominated_programs(Types.pareto_fronts(), %{Types.program_idx() => float()}) ::
          Types.pareto_fronts()
  def remove_dominated_programs(fronts, scores) when map_size(fronts) == 0 do
    _ = scores
    %{}
  end

  def remove_dominated_programs(fronts, scores) do
    all_programs = get_all_programs(fronts)
    sorted_programs = Enum.sort_by(all_programs, &Map.get(scores, &1, 0.0))
    dominated = do_eliminate(fronts, sorted_programs, [], scores)
    dominated_set = MapSet.new(dominated)

    Map.new(fronts, fn {id, front} ->
      {id, prune_front(front, dominated_set, scores)}
    end)
  end

  defp prune_front(front, dominated_set, scores) do
    if is_struct(front, MapSet) do
      pruned = MapSet.difference(front, dominated_set)

      if MapSet.size(pruned) == 0 and MapSet.size(front) > 0 do
        [best_program] =
          front
          |> MapSet.to_list()
          |> Enum.sort_by(&{-Map.get(scores, &1, 0.0), &1})
          |> Enum.take(1)

        MapSet.new([best_program])
      else
        pruned
      end
    else
      front
    end
  end

  @spec do_eliminate(
          Types.pareto_fronts(),
          [Types.program_idx()],
          [Types.program_idx()],
          %{Types.program_idx() => float()}
        ) ::
          [Types.program_idx()]
  defp do_eliminate(fronts, programs, dominated, scores) do
    active_programs = Enum.reject(programs, &(&1 in dominated))

    case find_next_dominated(fronts, active_programs, scores) do
      {:ok, program} -> do_eliminate(fronts, programs, [program | dominated], scores)
      :none -> dominated
    end
  end

  defp find_next_dominated(_fronts, [], _scores), do: :none

  defp find_next_dominated(fronts, active_programs, _scores) do
    Enum.find_value(active_programs, :none, fn program ->
      others = active_programs -- [program]

      if is_dominated?(program, others, fronts) do
        {:ok, program}
      else
        nil
      end
    end)
  end

  @spec select_from_pareto_front(
          Types.pareto_fronts(),
          %{Types.program_idx() => float()},
          :rand.state()
        ) ::
          {Types.program_idx(), :rand.state()}
  def select_from_pareto_front(fronts, scores, rand_state) do
    cleaned_fronts = remove_dominated_programs(fronts, scores)

    frequencies =
      Enum.reduce(cleaned_fronts, %{}, fn {_id, front}, acc ->
        calculate_frequencies(front, acc)
      end)

    if map_size(frequencies) == 0 do
      fallback_prog =
        scores
        |> Enum.max_by(fn {_prog, score} -> score end, fn -> {0, 0.0} end)
        |> elem(0)

      {fallback_prog, rand_state}
    else
      sampling_list =
        frequencies
        |> Enum.sort_by(fn {prog, _count} -> prog end)
        |> Enum.flat_map(fn {prog, count} -> List.duplicate(prog, count) end)

      {idx, new_state} = :rand.uniform_s(length(sampling_list), rand_state)
      {Enum.at(sampling_list, idx - 1), new_state}
    end
  end

  defp calculate_frequencies(%MapSet{} = front, acc) do
    Enum.reduce(front, acc, fn item, inner_acc ->
      Map.update(inner_acc, item, 1, &(&1 + 1))
    end)
  end

  defp calculate_frequencies(_, acc), do: acc

  @spec find_dominator_programs(Types.pareto_fronts(), %{Types.program_idx() => float()}) ::
          [Types.program_idx()]
  def find_dominator_programs(fronts, scores) do
    fronts
    |> remove_dominated_programs(scores)
    |> get_all_programs()
    |> Enum.sort_by(&{-Map.get(scores, &1, 0.0), &1})
  end

  @spec get_all_programs(Types.pareto_fronts()) :: [Types.program_idx()]
  def get_all_programs(fronts) do
    fronts
    |> Map.values()
    |> Enum.reduce(MapSet.new(), fn
      front, acc ->
        if is_struct(front, MapSet) do
          MapSet.union(acc, front)
        else
          acc
        end
    end)
    |> MapSet.to_list()
  end

  defp mapset_member?(front, program) do
    if is_struct(front, MapSet), do: MapSet.member?(front, program), else: false
  end
end
