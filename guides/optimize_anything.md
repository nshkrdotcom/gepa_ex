# Optimize Anything

`GEPA.OptimizeAnything.optimize_anything/1` is the evaluator-first entrypoint. It is meant for tasks where you already have a scoring function and want GEPA to search candidate text around it.

## When To Use It

Use this path when:

- your task is not a standard question-answer adapter
- your evaluator works on arbitrary candidates, examples, or both
- you want to optimize a string candidate or a map candidate without writing a custom adapter first

## Configuration

The top-level config is split into nested structs:

- `GEPA.OptimizeAnything.Config`
- `GEPA.OptimizeAnything.EngineConfig`
- `GEPA.OptimizeAnything.ReflectionConfig`
- `GEPA.OptimizeAnything.MergeConfig`
- `GEPA.OptimizeAnything.RefinerConfig`
- `GEPA.OptimizeAnything.TrackingConfig`

`GEPA.OptimizeAnything.Config.new/1` accepts maps or keyword lists. Nested maps are normalized automatically.

`reflection.reflection_lm` and `refiner.refiner_lm` accept normal GEPA LLM clients. Use `GEPA.LLM.req_llm/2` for hosted providers and `GEPA.LLM.agent/2` for local agent sessions. If `reflection.structured_output` is true, prefer a ReqLLM-backed hosted provider because ASM does not currently expose structured output.

## Evaluator Shape

The evaluator wrapper accepts several return shapes and normalizes them into a result map:

- a bare score
- `{score, feedback}`
- `{score, feedback, objective_scores}`
- a map with `score`, `feedback`, and optional `objective_scores`

The wrapper also captures `stdout`, diagnostic logs, and optional `opt_state`.

## Example

```elixir
config =
  GEPA.OptimizeAnything.Config.new(
    seed_candidate: "Answer exactly.",
    dataset: [%{input: "What is 2+2?", answer: "4"}],
    evaluator: fn candidate, example ->
      if String.contains?(candidate, example.answer), do: 1.0, else: 0.0
    end,
    objective: "Answer the question correctly with the shortest useful response",
    engine: [max_metric_calls: 20],
    reflection: [
      reflection_lm: GEPA.LLM.req_llm(:gemini),
      structured_output: true
    ],
    tracking: [tracker: GEPA.Tracking.InMemory.new()]
  )

{:ok, result} = GEPA.OptimizeAnything.optimize_anything(config)
```

If the seed candidate is a string, GEPA keeps that shape through the run and unwraps the result back to a string candidate.

## Refiner and Caching

The optimize-anything path can also use:

- `GEPA.CodeExecution` for evaluator-side code snippets
- `GEPA.OptimizeAnything.LogContext` for process-local diagnostic logs
- evaluation caching
- a refiner LLM for post-evaluation candidate cleanup

Those pieces are optional, but they are what make the path useful for non-trivial evaluator workflows.

## Result

The return value is still `{:ok, result}` with a normal `GEPA.Result` struct. That keeps the analysis and persistence flow consistent with `GEPA.optimize/1`.
