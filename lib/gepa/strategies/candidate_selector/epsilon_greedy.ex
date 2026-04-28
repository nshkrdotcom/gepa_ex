defmodule GEPA.Strategies.CandidateSelector.EpsilonGreedy do
  @moduledoc """
  Epsilon-greedy candidate selector with optional decay.

  Picks the current best candidate with probability `1 - epsilon` and a random
  candidate with probability `epsilon`. The `epsilon` value can decay after each
  selection to gradually reduce exploration.
  """

  @behaviour GEPA.Strategies.CandidateSelector

  alias GEPA.Strategies.CandidateSelector.CurrentBest

  defstruct [:epsilon, :epsilon_decay, :epsilon_min, :current_epsilon]

  @type t :: %__MODULE__{
          epsilon: float(),
          epsilon_decay: float(),
          epsilon_min: float(),
          current_epsilon: float()
        }

  @doc """
  Create a new epsilon-greedy selector.

  ## Options

    * `:epsilon` - initial exploration probability (default: 0.1)
    * `:epsilon_decay` - multiplicative decay applied after each selection (default: 1.0)
    * `:epsilon_min` - lower bound for epsilon after decay (default: 0.01)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    epsilon = normalize_probability(Keyword.get(opts, :epsilon, 0.1), :epsilon)
    epsilon_decay = normalize_probability(Keyword.get(opts, :epsilon_decay, 1.0), :epsilon_decay)
    default_epsilon_min = min(0.01, epsilon)

    epsilon_min =
      normalize_probability(Keyword.get(opts, :epsilon_min, default_epsilon_min), :epsilon_min)

    %__MODULE__{
      epsilon: epsilon,
      epsilon_decay: epsilon_decay,
      epsilon_min: epsilon_min,
      current_epsilon: epsilon
    }
  end

  @doc """
  Select a candidate using epsilon-greedy strategy.

  Returns `{candidate_idx, updated_selector, new_rand_state}`.
  """
  @impl true
  @spec select(t(), GEPA.State.t(), :rand.state() | nil) ::
          {GEPA.Types.program_idx(), t(), :rand.state()}
  def select(%__MODULE__{} = selector, state, rand_state) do
    rand_state = rand_state || :rand.seed(:exsss, {0, 0, 0})
    {random_value, rand_state} = :rand.uniform_s(rand_state)

    num_candidates = length(state.program_candidates)

    if num_candidates == 0 do
      raise ArgumentError, "cannot select candidate from empty state"
    end

    best_idx = CurrentBest.best_candidate_idx(state)

    {candidate_idx, rand_state} =
      if random_value < selector.current_epsilon do
        select_random_candidate(num_candidates, rand_state)
      else
        {best_idx, rand_state}
      end

    updated_selector = decay(selector)

    {candidate_idx, updated_selector, rand_state}
  end

  @doc """
  Reset `current_epsilon` back to the initial value.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = selector) do
    %{selector | current_epsilon: selector.epsilon}
  end

  @doc """
  Return the current epsilon value.
  """
  @spec current_epsilon(t()) :: float()
  def current_epsilon(%__MODULE__{current_epsilon: eps}), do: eps

  defp select_random_candidate(num_candidates, rand_state) do
    {idx, new_rand} = :rand.uniform_s(num_candidates, rand_state)
    {idx - 1, new_rand}
  end

  defp decay(%__MODULE__{} = selector) do
    new_eps = max(selector.epsilon_min, selector.current_epsilon * selector.epsilon_decay)
    %{selector | current_epsilon: new_eps}
  end

  defp normalize_probability(value, field) when is_number(value) do
    if value < 0.0 or value > 1.0 do
      raise ArgumentError, "#{field} must be between 0.0 and 1.0, got: #{inspect(value)}"
    else
      value * 1.0
    end
  end

  defp normalize_probability(value, field) do
    raise ArgumentError, "#{field} must be a number, got: #{inspect(value)}"
  end
end
