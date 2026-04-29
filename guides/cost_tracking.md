# Cost Tracking

GEPA tracks LLM usage at the model facade and stop-condition level where provider metadata is available.

## Reflection Cost

Reflection calls can be budgeted with `:max_reflection_cost`:

```elixir
GEPA.optimize(
  seed_candidate: seed,
  trainset: train,
  valset: val,
  adapter: adapter,
  reflection_llm: GEPA.LLM.req_llm(:gemini),
  max_reflection_cost: 1.00,
  max_metric_calls: 100
)
```

`GEPA.StopCondition.MaxReflectionCost` reads normalized cost counters from the configured reflection LLM when available.

## ReqLLM

ReqLLM-backed clients expose usage, provider-reported cost, and tool-call fields
when the hosted provider returns them through the shared `:inference` response
contract. Availability still depends on the provider response and model registry
metadata.

Use `GEPA.LLM.complete/3` through the facade so cost metadata stays normalized on `GEPA.LLM.Response`.

## Agent Session Manager

ASM clients expose cost metadata when the selected local provider and lane report it. GEPA does not invent cost values when ASM cannot provide them.

## Unknown Cost

Unknown model cost is treated as zero for budget accounting. That keeps local callables and unsupported provider metadata from failing runs, but it also means cost stops are only meaningful when the selected provider reports cost.

For production budgets, verify the provider's usage metadata with a live smoke before relying on a cost stop.
