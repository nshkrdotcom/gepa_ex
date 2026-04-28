defmodule GEPA.Utils do
  @moduledoc """
  Compatibility facade for GEPA utility functions.
  """

  alias GEPA.Utils.Pareto

  @spec is_dominated?(non_neg_integer(), MapSet.t(non_neg_integer()) | [non_neg_integer()], map()) ::
          boolean()
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_dominated?(program, dominating_programs, pareto_front) do
    Pareto.is_dominated?(program, dominating_programs, pareto_front)
  end

  @spec remove_dominated_programs(map(), map()) :: map()
  def remove_dominated_programs(pareto_front, scores) do
    Pareto.remove_dominated_programs(pareto_front, scores)
  end

  @spec find_dominator_programs(map(), map()) :: [non_neg_integer()]
  def find_dominator_programs(pareto_front_programs, program_scores) do
    Pareto.find_dominator_programs(pareto_front_programs, program_scores)
  end
end
