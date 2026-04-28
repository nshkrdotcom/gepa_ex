defmodule GEPA.Adapters.Confidence.ScoringTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.Confidence.Scoring
  alias GEPA.Adapters.Confidence.Scoring.{LinearBlend, Sigmoid, Threshold}

  test "linear blend penalizes low-confidence correct answers" do
    strategy = LinearBlend.new(low_confidence_threshold: 0.5, min_score_on_correct: 0.3)

    assert Scoring.score(strategy, false, -0.01) == 0.0
    assert Scoring.score(strategy, true, nil) == 1.0
    assert Scoring.score(strategy, true, :math.log(0.5)) == 1.0

    expected = 0.3 + (1.0 - 0.3) * (0.25 / 0.5)
    assert_in_delta Scoring.score(strategy, true, :math.log(0.25)), expected, 1.0e-8
    assert LinearBlend.describe(strategy) =~ "0.5"
  end

  test "threshold scoring requires probability at or above threshold" do
    strategy = Threshold.new(threshold: 0.7)

    assert Scoring.score(strategy, false, nil) == 0.0
    assert Scoring.score(strategy, true, nil) == 1.0
    assert Scoring.score(strategy, true, :math.log(0.7)) == 1.0
    assert Scoring.score(strategy, true, :math.log(0.69)) == 0.0
  end

  test "sigmoid scoring matches the expected formula" do
    strategy = Sigmoid.new(midpoint: 0.6, steepness: 8.0)
    logprob = :math.log(0.75)
    expected = 1.0 / (1.0 + :math.exp(-8.0 * (0.75 - 0.6)))

    assert_in_delta Scoring.score(strategy, true, logprob), expected, 1.0e-8
    assert Scoring.score(strategy, false, logprob) == 0.0
  end
end
