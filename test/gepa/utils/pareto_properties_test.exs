defmodule GEPA.Utils.ParetoPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GEPA.Utils.Pareto

  # Generators for property testing
  defp program_idx_generator do
    integer(0..20)
  end

  defp pareto_fronts_generator do
    gen all(
          num_val_examples <- integer(1..5),
          fronts <-
            list_of(
              tuple({
                string(:alphanumeric, min_length: 4, max_length: 8),
                uniq_list_of(program_idx_generator(), min_length: 1, max_length: 5)
              }),
              length: num_val_examples
            )
        ) do
      fronts
      |> Enum.into(%{}, fn {id, programs} -> {id, MapSet.new(programs)} end)
    end
  end

  defp scores_generator(fronts) do
    all_programs = Pareto.get_all_programs(fronts)

    gen all(scores <- list_of(float(min: 0.0, max: 1.0), length: length(all_programs))) do
      Enum.zip(all_programs, scores) |> Enum.into(%{})
    end
  end

  property "pareto fronts after removing dominated never contain dominated programs" do
    check all(
            fronts <- pareto_fronts_generator(),
            scores <- scores_generator(fronts),
            max_runs: 50
          ) do
      result = Pareto.remove_dominated_programs(fronts, scores)

      # For each front, no program should be dominated by others in same result
      for {_id, front} <- result do
        programs = MapSet.to_list(front)

        for prog <- programs do
          others = programs -- [prog]
          refute Pareto.is_dominated?(prog, others, result)
        end
      end
    end
  end

  property "removing dominated programs preserves at least one program per front" do
    check all(
            fronts <- pareto_fronts_generator(),
            scores <- scores_generator(fronts),
            max_runs: 50
          ) do
      result = Pareto.remove_dominated_programs(fronts, scores)

      # Every original front must have at least one program in result
      for {id, _original_front} <- fronts do
        assert MapSet.size(result[id]) >= 1,
               "Front #{id} was empty after removing dominated programs"
      end
    end
  end

  property "pareto selection always returns a program from some front" do
    check all(
            fronts <- pareto_fronts_generator(),
            scores <- scores_generator(fronts),
            seed_val <- integer(1..1000),
            max_runs: 50
          ) do
      rand_state = :rand.seed(:exsss, {seed_val, 2, 3})
      {selected, _new_rand} = Pareto.select_from_pareto_front(fronts, scores, rand_state)

      # Selected program must be in at least one front
      assert Enum.any?(fronts, fn {_id, front} ->
               MapSet.member?(front, selected)
             end),
             "Selected program #{selected} not in any Pareto front"
    end
  end

  property "is_dominated? is reflexive - program never dominates itself" do
    check all(
            fronts <- pareto_fronts_generator(),
            max_runs: 30
          ) do
      all_programs = Pareto.get_all_programs(fronts)

      for prog <- all_programs do
        # A program should never be dominated by itself
        refute Pareto.is_dominated?(prog, [prog], fronts)
      end
    end
  end

  property "removing dominated preserves programs on unique fronts" do
    check all(
            fronts <- pareto_fronts_generator(),
            scores <- scores_generator(fronts),
            max_runs: 30
          ) do
      result = Pareto.remove_dominated_programs(fronts, scores)

      # If a program was alone on a front, it must be preserved
      for {id, front} <- fronts do
        if MapSet.size(front) == 1 do
          [prog] = MapSet.to_list(front)

          assert MapSet.member?(result[id], prog),
                 "Program #{prog} was alone on front #{id} but was removed"
        end
      end
    end
  end

  property "find_dominator_programs returns only non-dominated programs" do
    check all(
            fronts <- pareto_fronts_generator(),
            scores <- scores_generator(fronts),
            max_runs: 50
          ) do
      dominators = Pareto.find_dominator_programs(fronts, scores)

      # No dominator should be dominated by the other dominators
      for prog <- dominators do
        others = dominators -- [prog]
        cleaned = Pareto.remove_dominated_programs(fronts, scores)
        refute Pareto.is_dominated?(prog, others, cleaned)
      end
    end
  end
end
