defmodule GEPA.Utils.OfficialParetoSemanticsTest do
  use ExUnit.Case, async: true

  alias GEPA.Utils.Pareto

  test "a program absent from all fronts is dominated" do
    fronts = %{0 => MapSet.new([0, 1]), 1 => MapSet.new([0])}

    assert Pareto.is_dominated?(99, [0, 1], fronts)
  end

  test "dominated-front cleanup never empties a non-empty validation front" do
    fronts = %{0 => MapSet.new([0, 1]), 1 => MapSet.new([0, 1])}
    scores = %{0 => 0.8, 1 => 0.8}

    cleaned = Pareto.remove_dominated_programs(fronts, scores)

    assert MapSet.size(cleaned[0]) >= 1
    assert MapSet.size(cleaned[1]) >= 1
  end
end
