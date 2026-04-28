# Confidence Adapter

`GEPA.Adapters.Confidence` ports the upstream confidence-aware task adapter
without coupling it to a provider-specific SDK.

## Boundary

The adapter accepts a model through the common `GEPA.LLM` facade or any callable
that returns model text. The model should return JSON containing the configured
answer field.

Confidence is extracted from metadata when the provided model can supply it. If
provider logprobs are unavailable, the adapter keeps the confidence probability
unknown instead of inventing one.

## Scoring

The scoring strategies live under `GEPA.Adapters.Confidence.Scoring`:

- `LinearBlend`
- `Threshold`
- `Sigmoid`

They all receive correctness plus optional joint logprob-derived confidence and
return a scalar objective score.

## Provider Notes

- ReqLLM is the preferred live path when the task needs provider-enforced
  structured output.
- Agent Session Manager can be used for plain text generation, but ASM
  structured output is not supported yet and fails closed through the facade.
- Direct logprob support depends on the selected provider and model. The adapter
  does not hide missing logprobs behind synthetic confidence values.

## Minimal Use

```elixir
llm = GEPA.LLM.req_llm(:gemini)

adapter =
  GEPA.Adapters.Confidence.new(
    model: llm,
    field_path: "category",
    schema: [category: [type: :string, required: true]],
    scoring_strategy: GEPA.Adapters.Confidence.Scoring.LinearBlend.new()
  )
```

Use this adapter with `GEPA.optimize/1` like any other `GEPA.Adapter`.

The live example is:

```bash
mix run examples/18_confidence_adapter.exs -- --simple
```
