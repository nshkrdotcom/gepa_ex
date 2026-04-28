# Acceptance Criteria

Acceptance criteria decide whether a proposed candidate becomes part of the search frontier.

## Built-In Criteria

`GEPA.Strategies.Acceptance.StrictImprovement` accepts only when the proposal score is strictly better than the previous score.

`GEPA.Strategies.Acceptance.ImprovementOrEqual` accepts improvements and ties.

```elixir
GEPA.optimize(
  seed_candidate: seed,
  trainset: train,
  valset: val,
  adapter: adapter,
  acceptance_strategy: GEPA.Strategies.Acceptance.StrictImprovement,
  max_metric_calls: 50
)
```

## Custom Criteria

A custom criterion can be a module or function matching the acceptance callback shape. Use this when scalar score is not enough and you need trajectories, objective scores, or state.

Keep custom criteria deterministic. The engine may retry or resume runs, and non-deterministic acceptance makes result analysis difficult.

## Ties

Use strict improvement when evaluation noise is low and you want conservative frontier growth. Use improvement-or-equal when score plateaus still produce useful diversity or when later validation can separate candidates.
