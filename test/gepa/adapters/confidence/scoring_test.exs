defmodule GEPA.Adapters.Confidence.ScoringTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.Confidence.Scoring
  alias GEPA.Adapters.Confidence.Scoring.{LinearBlend, Sigmoid, Threshold}

  describe "upstream scoring strategy protocol parity" do
    test "linear blend is scoring strategy" do
      strategy = LinearBlend.new()

      assert %LinearBlend{} = strategy
      assert function_exported?(LinearBlend, :score, 3)
      assert Scoring.score(strategy, true, nil) == 1.0
    end

    test "threshold is scoring strategy" do
      strategy = Threshold.new()

      assert %Threshold{} = strategy
      assert function_exported?(Threshold, :score, 3)
      assert Scoring.score(strategy, true, nil) == 1.0
    end

    test "sigmoid is scoring strategy" do
      strategy = Sigmoid.new()

      assert %Sigmoid{} = strategy
      assert function_exported?(Sigmoid, :score, 3)
      assert Scoring.score(strategy, true, nil) == 1.0
    end
  end

  describe "upstream LinearBlendScoring parity" do
    test "incorrect always zero" do
      strategy = LinearBlend.new()

      assert Scoring.score(strategy, false, -0.01) == 0.0
      assert Scoring.score(strategy, false, -5.0) == 0.0
      assert Scoring.score(strategy, false, nil) == 0.0
    end

    test "correct none logprob returns one" do
      assert Scoring.score(LinearBlend.new(), true, nil) == 1.0
    end

    test "correct high confidence returns one" do
      strategy = LinearBlend.new(low_confidence_threshold: 0.5)

      assert Scoring.score(strategy, true, -0.01) == 1.0
      assert Scoring.score(strategy, true, -0.1) == 1.0
      assert Scoring.score(strategy, true, 0.0) == 1.0
    end

    test "correct at threshold returns one" do
      strategy = LinearBlend.new(low_confidence_threshold: 0.5)

      assert Scoring.score(strategy, true, :math.log(0.5)) == 1.0
    end

    test "correct below threshold interpolates" do
      strategy = LinearBlend.new(low_confidence_threshold: 0.5, min_score_on_correct: 0.3)
      expected = 0.3 + (1.0 - 0.3) * (0.25 / 0.5)

      assert_in_delta Scoring.score(strategy, true, :math.log(0.25)), expected, 1.0e-8
    end

    test "correct very low logprob returns near min score" do
      strategy = LinearBlend.new(low_confidence_threshold: 0.5, min_score_on_correct: 0.3)

      assert_in_delta Scoring.score(strategy, true, -10.0), 0.3, 0.01
    end

    test "score range is zero to one" do
      strategy = LinearBlend.new()

      for logprob <- [-10.0, -5.0, -2.0, -1.0, -0.5, -0.1, 0.0],
          correct <- [true, false] do
        score = Scoring.score(strategy, correct, logprob)

        assert score >= 0.0
        assert score <= 1.0
      end
    end

    test "describe includes params" do
      strategy = LinearBlend.new(low_confidence_threshold: 0.6, min_score_on_correct: 0.2)
      description = LinearBlend.describe(strategy)

      assert description =~ "0.6"
      assert description =~ "0.2"
    end

    test "invalid threshold raises" do
      assert_raise ArgumentError, fn -> LinearBlend.new(low_confidence_threshold: 0.0) end
      assert_raise ArgumentError, fn -> LinearBlend.new(low_confidence_threshold: 1.5) end
    end

    test "invalid min score raises" do
      assert_raise ArgumentError, fn -> LinearBlend.new(min_score_on_correct: -0.1) end
      assert_raise ArgumentError, fn -> LinearBlend.new(min_score_on_correct: 1.0) end
    end

    test "monotonically increasing with logprob" do
      strategy = LinearBlend.new(low_confidence_threshold: 0.8, min_score_on_correct: 0.1)

      Enum.reduce([-10.0, -5.0, -3.0, -2.0, -1.5, -1.0, -0.5, -0.2], -1.0, fn logprob, previous ->
        score = Scoring.score(strategy, true, logprob)

        assert score >= previous
        score
      end)
    end
  end

  describe "upstream ThresholdScoring parity" do
    test "incorrect always zero" do
      strategy = Threshold.new(threshold: 0.7)

      assert Scoring.score(strategy, false, -0.01) == 0.0
      assert Scoring.score(strategy, false, nil) == 0.0
    end

    test "correct none logprob returns one" do
      assert Scoring.score(Threshold.new(), true, nil) == 1.0
    end

    test "correct above threshold returns one" do
      strategy = Threshold.new(threshold: 0.7)

      assert Scoring.score(strategy, true, :math.log(0.7)) == 1.0
      assert Scoring.score(strategy, true, -0.01) == 1.0
    end

    test "correct below threshold returns zero" do
      strategy = Threshold.new(threshold: 0.7)

      assert Scoring.score(strategy, true, :math.log(0.69)) == 0.0
      assert Scoring.score(strategy, true, -5.0) == 0.0
    end

    test "describe includes threshold" do
      assert Threshold.new(threshold: 0.8) |> Threshold.describe() =~ "0.8"
    end

    test "invalid threshold raises" do
      assert_raise ArgumentError, fn -> Threshold.new(threshold: 0.0) end
      assert_raise ArgumentError, fn -> Threshold.new(threshold: 1.5) end
    end
  end

  describe "upstream SigmoidScoring parity" do
    test "incorrect always zero" do
      strategy = Sigmoid.new()

      assert Scoring.score(strategy, false, -0.01) == 0.0
      assert Scoring.score(strategy, false, nil) == 0.0
    end

    test "correct none logprob returns one" do
      assert Scoring.score(Sigmoid.new(), true, nil) == 1.0
    end

    test "at midpoint probability returns half" do
      strategy = Sigmoid.new(midpoint: 0.5, steepness: 10.0)

      assert_in_delta Scoring.score(strategy, true, :math.log(0.5)), 0.5, 1.0e-6
    end

    test "high confidence approaches one" do
      assert Scoring.score(Sigmoid.new(midpoint: 0.5, steepness: 10.0), true, -0.05) > 0.98
    end

    test "low confidence approaches zero" do
      assert Scoring.score(Sigmoid.new(midpoint: 0.5, steepness: 10.0), true, -5.0) < 0.02
    end

    test "monotonically increasing for correct" do
      strategy = Sigmoid.new()

      Enum.reduce([-10.0, -5.0, -3.0, -2.0, -1.0, -0.5, -0.2, -0.05], -1.0, fn logprob,
                                                                               previous ->
        score = Scoring.score(strategy, true, logprob)

        assert score > previous
        score
      end)
    end

    test "describe includes params" do
      description = Sigmoid.new(midpoint: 0.4, steepness: 12.0) |> Sigmoid.describe()

      assert description =~ "0.4"
      assert description =~ "12.0"
    end

    test "invalid midpoint raises" do
      assert_raise ArgumentError, fn -> Sigmoid.new(midpoint: 0.0) end
      assert_raise ArgumentError, fn -> Sigmoid.new(midpoint: 1.0) end
    end

    test "invalid steepness raises" do
      assert_raise ArgumentError, fn -> Sigmoid.new(steepness: 0) end
      assert_raise ArgumentError, fn -> Sigmoid.new(steepness: -1) end
    end

    test "manual sigmoid computation" do
      midpoint = 0.6
      steepness = 8.0
      strategy = Sigmoid.new(midpoint: midpoint, steepness: steepness)
      logprob = :math.log(0.75)
      probability = :math.exp(logprob)
      expected = 1.0 / (1.0 + :math.exp(-steepness * (probability - midpoint)))

      assert_in_delta Scoring.score(strategy, true, logprob), expected, 1.0e-8
    end
  end
end
