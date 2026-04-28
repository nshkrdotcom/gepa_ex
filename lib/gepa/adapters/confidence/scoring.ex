defmodule GEPA.Adapters.Confidence.Scoring do
  @moduledoc """
  Confidence-aware scoring strategies for `GEPA.Adapters.Confidence`.

  Each strategy receives whether the prediction is correct and the **joint
  logprob** for the target field.  Logprobs are converted to probabilities via
  `exp(logprob)` before confidence penalties are applied.
  """

  @type strategy :: struct() | module()

  @spec score(strategy(), boolean(), number() | nil) :: float()
  def score(strategy, is_correct, logprob_score) do
    module = if is_atom(strategy), do: strategy, else: strategy.__struct__
    module.score(strategy, is_correct, logprob_score)
  end

  @spec describe(strategy()) :: String.t()
  def describe(strategy) do
    module = if is_atom(strategy), do: strategy, else: strategy.__struct__

    if function_exported?(module, :describe, 1) do
      module.describe(strategy)
    else
      inspect(strategy)
    end
  end

  @spec probability(number() | nil) :: float() | nil
  def probability(nil), do: nil
  def probability(logprob) when is_number(logprob), do: :math.exp(logprob)

  @spec clamp01(number()) :: float()
  def clamp01(value) when value < 0.0, do: 0.0
  def clamp01(value) when value > 1.0, do: 1.0
  def clamp01(value), do: value * 1.0
end

defmodule GEPA.Adapters.Confidence.Scoring.LinearBlend do
  @moduledoc """
  Scores correct answers as 1.0 above a probability threshold, otherwise blends
  linearly from `min_score_on_correct` to 1.0. Incorrect answers always score 0.
  """

  alias GEPA.Adapters.Confidence.Scoring

  defstruct low_confidence_threshold: 0.5, min_score_on_correct: 0.3

  @type t :: %__MODULE__{low_confidence_threshold: float(), min_score_on_correct: float()}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)
    threshold = Map.get(opts, :low_confidence_threshold, 0.5) * 1.0
    min_score = Map.get(opts, :min_score_on_correct, 0.3) * 1.0

    unless threshold > 0.0 and threshold <= 1.0 do
      raise ArgumentError, "low_confidence_threshold must be in (0, 1]"
    end

    unless min_score >= 0.0 and min_score < 1.0 do
      raise ArgumentError, "min_score_on_correct must be in [0, 1)"
    end

    %__MODULE__{low_confidence_threshold: threshold, min_score_on_correct: min_score}
  end

  @spec score(t() | module(), boolean(), number() | nil) :: float()
  def score(_strategy, false, _logprob), do: 0.0
  def score(_strategy, true, nil), do: 1.0

  def score(%__MODULE__{} = strategy, true, logprob) do
    probability = Scoring.probability(logprob)

    if probability >= strategy.low_confidence_threshold do
      1.0
    else
      score =
        strategy.min_score_on_correct +
          (1.0 - strategy.min_score_on_correct) *
            (probability / strategy.low_confidence_threshold)

      Scoring.clamp01(score)
    end
  end

  def score(__MODULE__, correct, logprob), do: score(new(), correct, logprob)

  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = strategy) do
    "LinearBlendScoring(threshold=#{strategy.low_confidence_threshold}, min_score=#{strategy.min_score_on_correct})"
  end
end

defmodule GEPA.Adapters.Confidence.Scoring.Threshold do
  @moduledoc """
  Scores a correct answer as 1.0 only when confidence probability is greater
  than or equal to `threshold`; otherwise 0.0.
  """

  alias GEPA.Adapters.Confidence.Scoring

  defstruct threshold: 0.7

  @type t :: %__MODULE__{threshold: float()}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    threshold = (Map.new(opts) |> Map.get(:threshold, 0.7)) * 1.0

    unless threshold > 0.0 and threshold <= 1.0 do
      raise ArgumentError, "threshold must be in (0, 1]"
    end

    %__MODULE__{threshold: threshold}
  end

  def score(_strategy, false, _logprob), do: 0.0
  def score(_strategy, true, nil), do: 1.0

  def score(%__MODULE__{} = strategy, true, logprob) do
    if Scoring.probability(logprob) >= strategy.threshold, do: 1.0, else: 0.0
  end

  def score(__MODULE__, correct, logprob), do: score(new(), correct, logprob)

  def describe(%__MODULE__{} = strategy), do: "ThresholdScoring(threshold=#{strategy.threshold})"
end

defmodule GEPA.Adapters.Confidence.Scoring.Sigmoid do
  @moduledoc """
  Scores a correct answer with a sigmoid over confidence probability:
  `1 / (1 + exp(-steepness * (probability - midpoint)))`.
  """

  alias GEPA.Adapters.Confidence.Scoring

  defstruct midpoint: 0.5, steepness: 10.0

  @type t :: %__MODULE__{midpoint: float(), steepness: float()}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)
    midpoint = Map.get(opts, :midpoint, 0.5) * 1.0
    steepness = Map.get(opts, :steepness, 10.0) * 1.0

    unless midpoint > 0.0 and midpoint < 1.0 do
      raise ArgumentError, "midpoint must be in (0, 1)"
    end

    unless steepness > 0.0 do
      raise ArgumentError, "steepness must be positive"
    end

    %__MODULE__{midpoint: midpoint, steepness: steepness}
  end

  def score(_strategy, false, _logprob), do: 0.0
  def score(_strategy, true, nil), do: 1.0

  def score(%__MODULE__{} = strategy, true, logprob) do
    probability = Scoring.probability(logprob)
    x = strategy.steepness * (probability - strategy.midpoint)
    1.0 / (1.0 + :math.exp(-x))
  end

  def score(__MODULE__, correct, logprob), do: score(new(), correct, logprob)

  def describe(%__MODULE__{} = strategy) do
    "SigmoidScoring(midpoint=#{strategy.midpoint}, steepness=#{strategy.steepness})"
  end
end

defmodule GEPA.Adapters.Confidence.Scoring.LinearBlendScoring do
  @moduledoc "Compatibility alias for `GEPA.Adapters.Confidence.Scoring.LinearBlend`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.Confidence.Scoring.LinearBlend

  defdelegate score(strategy, is_correct, logprob_score),
    to: GEPA.Adapters.Confidence.Scoring.LinearBlend

  defdelegate describe(strategy), to: GEPA.Adapters.Confidence.Scoring.LinearBlend
end

defmodule GEPA.Adapters.Confidence.Scoring.ThresholdScoring do
  @moduledoc "Compatibility alias for `GEPA.Adapters.Confidence.Scoring.Threshold`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.Confidence.Scoring.Threshold

  defdelegate score(strategy, is_correct, logprob_score),
    to: GEPA.Adapters.Confidence.Scoring.Threshold

  defdelegate describe(strategy), to: GEPA.Adapters.Confidence.Scoring.Threshold
end

defmodule GEPA.Adapters.Confidence.Scoring.SigmoidScoring do
  @moduledoc "Compatibility alias for `GEPA.Adapters.Confidence.Scoring.Sigmoid`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.Confidence.Scoring.Sigmoid

  defdelegate score(strategy, is_correct, logprob_score),
    to: GEPA.Adapters.Confidence.Scoring.Sigmoid

  defdelegate describe(strategy), to: GEPA.Adapters.Confidence.Scoring.Sigmoid
end
