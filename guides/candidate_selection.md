# Candidate Selection

Candidate selection chooses which existing program to mutate next. It is the main exploration/exploitation control in the optimizer.

## Built-In Selectors

| Selector | Module | Use when |
| --- | --- | --- |
| Pareto | `GEPA.Strategies.CandidateSelector.Pareto` | You want broad search over the current Pareto frontier. |
| Current best | `GEPA.Strategies.CandidateSelector.CurrentBest` | You want greedy local improvement. |
| Top-k Pareto | `GEPA.Strategies.CandidateSelector.TopKPareto` | You want Pareto search bounded to the strongest candidates. |
| Epsilon-greedy | `GEPA.Strategies.CandidateSelector.EpsilonGreedy` | You want decaying random exploration around the current best. |

## Choosing A Selector

```elixir
GEPA.optimize(
  seed_candidate: %{"instruction" => "Answer clearly."},
  trainset: train,
  valset: val,
  adapter: adapter,
  candidate_selection_strategy: :pareto,
  max_metric_calls: 50
)
```

You can also pass selector structs or modules directly when you need exact parameters.

```elixir
selector =
  GEPA.Strategies.CandidateSelector.EpsilonGreedy.new(
    initial_epsilon: 0.3,
    min_epsilon: 0.05,
    decay: 0.95
  )
```

## Statefulness

Most selectors are stateless. `EpsilonGreedy` is stateful because epsilon decays after selections. Keep the selector value returned by the engine state when you are inspecting or resuming advanced runs.

## Pareto Fronts

GEPA tracks per-validation-instance Pareto fronts and optional per-objective fronts. Pareto selectors sample from that frontier so candidates that are strong on different slices can continue to evolve.
