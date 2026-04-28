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

- ReqLLM and Agent Session Manager can both be used for answer generation
  through `GEPA.LLM.complete/3`.
- ASM structured output is not supported yet, so confidence tasks that need a
  strict JSON object should ask the prompt to return JSON text and let the
  adapter parse it.
- Direct logprob support depends on the selected provider and model. The adapter
  does not hide missing logprobs behind synthetic confidence values.

## Minimal Use

```elixir
llm = GEPA.LLM.agent(:gemini, provider_opts: [model: "gemini-3.1-flash-lite-preview"])

adapter =
  GEPA.Adapters.Confidence.new(
    model: llm,
    answer_field: "category",
    scoring_strategy: GEPA.Adapters.Confidence.Scoring.LinearBlend.new()
  )
```

Use this adapter with `GEPA.optimize/1` like any other `GEPA.Adapter`.
