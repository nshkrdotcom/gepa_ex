defmodule GEPA.Adapters.ConfidenceTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.Confidence
  alias GEPA.Adapters.Confidence.Scoring.LinearBlend

  test "evaluate parses structured model output and records confidence objectives" do
    model = fn _prompt -> Jason.encode!(%{category_name: "Food & Drinks/Restaurants"}) end

    adapter =
      Confidence.new(
        model: model,
        field_path: "category_name",
        scoring_strategy: LinearBlend.new(low_confidence_threshold: 0.5),
        logprob_extractor: fn _decoded -> %{joint_logprob: -0.001, top_logprobs: []} end
      )

    batch = [%{input: "UBER EATS payment", answer: "Food & Drinks/Restaurants"}]

    assert {:ok, result} =
             Confidence.evaluate(adapter, batch, %{"system_prompt" => "Classify."}, true)

    assert result.scores == [1.0]
    assert [%{"accuracy" => 1.0, "probability" => probability}] = result.objective_scores
    assert_in_delta probability, :math.exp(-0.001), 1.0e-8
    assert [%{prediction: "Food & Drinks/Restaurants"}] = result.trajectories
  end

  test "make_reflective_dataset includes actionable feedback" do
    eval_batch = %GEPA.EvaluationBatch{
      outputs: [%{prediction: "wrong"}],
      scores: [0.0],
      trajectories: [
        %{
          input: "x",
          additional_context: %{},
          output: %{prediction: "wrong"},
          prediction: "wrong",
          expected: "right",
          correct?: false,
          probability: 0.2,
          objective_scores: %{"accuracy" => 0.0}
        }
      ]
    }

    assert {:ok, dataset} =
             Confidence.make_reflective_dataset(
               %Confidence{model: fn _ -> "{}" end},
               %{},
               eval_batch,
               ["system_prompt"]
             )

    assert [%{"Feedback" => feedback}] = dataset["system_prompt"]
    assert feedback =~ "Incorrect"
    assert feedback =~ "right"
  end
end
