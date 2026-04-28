defmodule GEPA.VisualizationTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.{Result, Visualization}

  defp sample_data do
    candidates = [
      %{"system_prompt" => "You are a helpful assistant."},
      %{"system_prompt" => "You are an expert math tutor. Show step-by-step solutions."},
      %{"system_prompt" => "You are a precise math solver. Always verify your answer."}
    ]

    parents = [[nil], [0], [0]]
    val_scores = [0.5, 0.7, 0.65]

    pareto_front = %{
      "ex_0" => MapSet.new([1]),
      "ex_1" => MapSet.new([1, 2]),
      "ex_2" => MapSet.new([2])
    }

    {candidates, parents, val_scores, pareto_front}
  end

  describe "candidate_tree_dot_from_data/4" do
    test "returns valid dot" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      dot =
        Visualization.candidate_tree_dot_from_data(candidates, parents, val_scores, pareto_front)

      assert String.starts_with?(dot, "digraph G {")
      assert String.ends_with?(dot, "}")
    end

    test "contains all nodes" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      dot =
        Visualization.candidate_tree_dot_from_data(candidates, parents, val_scores, pareto_front)

      for idx <- 0..(length(candidates) - 1) do
        assert dot =~ ~s(    #{idx} [label=")
      end
    end

    test "contains edges" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      dot =
        Visualization.candidate_tree_dot_from_data(candidates, parents, val_scores, pareto_front)

      assert dot =~ "0 -> 1;"
      assert dot =~ "0 -> 2;"
    end

    test "best node is cyan" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      dot =
        Visualization.candidate_tree_dot_from_data(candidates, parents, val_scores, pareto_front)

      assert dot =~ "fillcolor=cyan"
    end

    test "suppresses native dot tooltip" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      dot =
        Visualization.candidate_tree_dot_from_data(candidates, parents, val_scores, pareto_front)

      refute dot =~ "helpful assistant"
      assert dot =~ ~s(tooltip=" ")
    end

    test "supports a single candidate" do
      dot =
        Visualization.candidate_tree_dot_from_data(
          [%{"prompt" => "test"}],
          [[nil]],
          [0.5],
          %{"ex_0" => MapSet.new([0])}
        )

      assert dot =~ "digraph G {"
      assert dot =~ ~s(0 [label=")
    end
  end

  describe "candidate_tree_html_from_data/4" do
    test "returns valid html" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      html =
        Visualization.candidate_tree_html_from_data(candidates, parents, val_scores, pareto_front)

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "</html>"
    end

    test "contains dot string" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      html =
        Visualization.candidate_tree_html_from_data(candidates, parents, val_scores, pareto_front)

      assert html =~ "digraph G"
    end

    test "contains node metadata" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      html =
        Visualization.candidate_tree_html_from_data(candidates, parents, val_scores, pareto_front)

      assert html =~ ~s("score")
      assert html =~ ~s("components")
      assert html =~ "helpful assistant"
    end

    test "contains viz js cdn" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      html =
        Visualization.candidate_tree_html_from_data(candidates, parents, val_scores, pareto_front)

      assert html =~ "viz-standalone.mjs"
    end

    test "contains tooltip elements" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      html =
        Visualization.candidate_tree_html_from_data(candidates, parents, val_scores, pareto_front)

      assert html =~ ~s(id="tooltip")
      assert html =~ "showTooltip"
    end
  end

  describe "result visualization helpers" do
    test "result candidate tree dot" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      result = %Result{
        candidates: candidates,
        parents: parents,
        val_aggregate_scores: val_scores,
        val_subscores: Enum.map(candidates, fn _ -> %{} end),
        per_val_instance_best_candidates: pareto_front,
        discovery_eval_counts: [0, 5, 5]
      }

      dot = Result.candidate_tree_dot(result)

      assert dot =~ "digraph G {"
      assert dot =~ "0 -> 1;"
    end

    test "result candidate tree html" do
      {candidates, parents, val_scores, pareto_front} = sample_data()

      result = %Result{
        candidates: candidates,
        parents: parents,
        val_aggregate_scores: val_scores,
        val_subscores: Enum.map(candidates, fn _ -> %{} end),
        per_val_instance_best_candidates: pareto_front,
        discovery_eval_counts: [0, 5, 5]
      }

      html = Result.candidate_tree_html(result)

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "math tutor"
    end
  end
end
