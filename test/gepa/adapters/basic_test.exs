defmodule GEPA.Adapters.BasicTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.Basic

  describe "evaluate/3" do
    test "scores correctly when answer found in response" do
      adapter = Basic.new()

      batch = [
        %{input: "What is 2+2?", answer: "Answer"}
      ]

      candidate = %{"instruction" => "Be helpful"}

      {:ok, result} = Basic.evaluate(adapter, batch, candidate, false)

      assert length(result.scores) == 1
      assert hd(result.scores) >= 0.0
    end

    test "captures trajectories when requested" do
      adapter = Basic.new()

      batch = [%{input: "Test", answer: "Test"}]
      candidate = %{"instruction" => "Help"}

      {:ok, result} = Basic.evaluate(adapter, batch, candidate, true)

      assert is_list(result.trajectories)
      assert length(result.trajectories) == 1
      assert hd(result.trajectories).input == "Test"
    end

    test "returns nil trajectories when not capturing" do
      adapter = Basic.new()

      {:ok, result} = Basic.evaluate(adapter, [%{input: "Q", answer: "A"}], %{"i" => "x"}, false)

      assert result.trajectories == nil
    end
  end

  describe "make_reflective_dataset/3" do
    test "creates feedback for incorrect answers" do
      adapter = Basic.new()

      candidate = %{"instruction" => "old"}

      eval_batch = %GEPA.EvaluationBatch{
        outputs: ["wrong answer"],
        scores: [0.0],
        trajectories: [
          %{input: "Q1", expected: "A1", response: "wrong answer", score: 0.0}
        ]
      }

      {:ok, dataset} =
        Basic.make_reflective_dataset(adapter, candidate, eval_batch, ["instruction"])

      assert Map.has_key?(dataset, "instruction")
      assert length(dataset["instruction"]) == 1

      item = hd(dataset["instruction"])
      assert item["Feedback"] =~ "Expected answer"
    end

    test "creates feedback for correct answers" do
      adapter = Basic.new()

      eval_batch = %GEPA.EvaluationBatch{
        outputs: ["A1"],
        scores: [1.0],
        trajectories: [
          %{input: "Q1", expected: "A1", response: "The answer is A1", score: 1.0}
        ]
      }

      {:ok, dataset} = Basic.make_reflective_dataset(adapter, %{"i" => "x"}, eval_batch, ["i"])

      item = hd(dataset["i"])
      assert item["Feedback"] =~ "Correct"
    end
  end
end
