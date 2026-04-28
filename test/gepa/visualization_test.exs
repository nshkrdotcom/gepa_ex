defmodule GEPA.VisualizationTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  describe "candidate_tree_dot_from_data/4" do
    test "renders candidate nodes and lineage edges" do
      dot =
        GEPA.Visualization.candidate_tree_dot_from_data(
          [%{"prompt" => "seed"}, %{"prompt" => "better"}],
          [[nil], [0]],
          [0.1, 0.9],
          %{0 => MapSet.new([1])}
        )

      assert dot =~ "digraph G"
      assert dot =~ "rankdir=TB"
      assert dot =~ "0 -> 1"
      assert dot =~ "Candidate 1"
      assert dot =~ "fillcolor=cyan"
    end
  end

  describe "candidate_tree_html_from_data/4" do
    test "renders self-contained HTML scaffold with graph data" do
      html =
        GEPA.Visualization.candidate_tree_html_from_data(
          [%{"prompt" => "seed"}, %{"prompt" => "better"}],
          [[nil], [0]],
          [0.1, 0.9],
          %{0 => MapSet.new([1])}
        )

      assert html =~ "GEPA Candidate Tree"
      assert html =~ "@viz-js/viz"
      assert html =~ "better"
      assert html =~ "DOT = `digraph G"
    end
  end
end
