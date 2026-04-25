# Core API

`GEPA.optimize/1` is the adapter-based entrypoint. It wraps the engine, result conversion, progress display, callbacks, tracking, and persistence behavior around a normal optimization run.

## Required Inputs

- `:seed_candidate` - map of component name to text
- `:trainset` - list or `GEPA.DataLoader`
- `:adapter` - any module or struct that implements `GEPA.Adapter`

If `:adapter` is omitted, GEPA can build the default adapter when you provide `:task_lm` or `:model`. If `:valset` is omitted, the training set is reused.

`GEPA.Adapter` is the task adapter contract. LLM clients such as `GEPA.LLM.req_llm(:openai)` and `GEPA.LLM.agent(:codex)` are usually passed into a task adapter or into reflection options.

## Search Controls

- `:candidate_selection_strategy` or `:candidate_selector`
- `:batch_sampler`
- `:module_selector`
- `:val_evaluation_policy`
- `:reflection_minibatch_size`
- `:frontier_type`

The shipped selectors include `:pareto`, `:current_best`, `:epsilon_greedy`, and `:top_k_pareto`. The batch sampler defaults to epoch-shuffled minibatches.

## Reflection Controls

- `:reflection_llm`
- `:proposal_template`
- `:structured_output`
- `:custom_candidate_proposer`
- `:perfect_score`
- `:skip_perfect_score`

When `:reflection_llm` is present, GEPA asks the LLM to propose improved instruction text. Use a hosted ReqLLM client when you need native structured output:

```elixir
reflection_llm = GEPA.LLM.req_llm(:gemini)
```

Local ASM clients are valid text reflection LLMs, but they do not currently support native structured output. When `:reflection_llm` is absent, the task adapter may provide `propose_new_texts/3` or `/4`, or you can supply `:custom_candidate_proposer`.

## Stops and Persistence

- `:max_metric_calls`
- `:max_reflection_cost`
- `:max_candidate_proposals`
- `:stop_conditions`
- `:run_dir`
- `:raise_on_exception`

At least one stopping path is required. `:run_dir` adds file-based stopping and persistence support.

## Observability

- `:callbacks`
- `:tracker`
- `:progress`
- `:track_best_outputs`
- `:cache_evaluation`

These hooks are synchronous. Use them for logging, metrics, and side effects that belong to the run boundary rather than the adapter boundary.

## Result

`GEPA.optimize/1` returns `{:ok, result}` where `result` is a `GEPA.Result` struct. The main accessors are:

```elixir
GEPA.Result.best_score(result)
GEPA.Result.best_candidate(result)
GEPA.Result.to_dict(result)
GEPA.Result.from_dict(map)
```

`GEPA.State` carries the internal search history, Pareto fronts, and adapter state. `GEPA.Result` is the public, immutable summary that you should store or display.
