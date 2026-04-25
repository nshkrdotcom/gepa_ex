# Optimization Workflow

GEPA runs a tight optimization loop:

1. evaluate the seed candidate
2. choose a candidate to mutate
3. sample a minibatch from the training set
4. build a reflective dataset from traces
5. propose a new candidate
6. evaluate the proposal
7. accept or reject it
8. repeat until a stop condition triggers

## Candidate Selection

The selector is where exploration and exploitation are balanced.

- `GEPA.Strategies.CandidateSelector.Pareto` samples from the current Pareto front
- `GEPA.Strategies.CandidateSelector.CurrentBest` always selects the top candidate
- `GEPA.Strategies.CandidateSelector.TopKPareto` samples from the top-k front members
- `GEPA.Strategies.CandidateSelector.EpsilonGreedy` explores with a decaying epsilon

`EpsilonGreedy` is stateful: it carries the current epsilon forward across selections and can be reset back to its initial value.

## Proposals

GEPA can produce proposals in three ways:

- the adapter implements `propose_new_texts/3` or `/4`
- `GEPA.Proposer.InstructionProposal` calls an LLM with a reflective dataset
- `GEPA.Proposer.Merge` combines related parents when merge mode is enabled

Instruction proposal supports custom templates and structured output. For native structured output, pass a hosted ReqLLM client such as `GEPA.LLM.req_llm(:openai)`, `:gemini`, or `:anthropic` as `:reflection_llm`. Local ASM clients can be used for text proposals, but structured output is capability-gated off there.

Adapter-owned proposal callbacks are task-adapter callbacks. They are separate from the LLM adapter/provider selection used by `GEPA.LLM`. Merge mode is scheduled separately and can be turned off entirely.

## Acceptance

`GEPA.Strategies.Acceptance` controls when a proposal replaces the current candidate. The common modes are:

- strict improvement
- improvement or equal
- a custom function or module

The engine evaluates the proposal on the sampled minibatch first, then applies the configured acceptance rule.

## Stop Conditions

The built-in stop conditions cover:

- call budgets
- proposal budgets
- reflection-cost budgets
- timeouts
- score thresholds
- no-improvement patience
- tracked-candidate limits
- explicit signal or file stops

You can compose multiple conditions with `GEPA.StopCondition.Composite`.

## Persistence and Resume

When `:run_dir` is configured, GEPA persists state and can resume later. The state includes candidate history, Pareto fronts, adapter state, and the validation schema version needed to reload safely.

## Progress, Callbacks, Tracking

- `GEPA.Progress` prints a terminal progress line when enabled
- `GEPA.Callbacks` exposes synchronous lifecycle events
- `GEPA.Tracking` forwards scalar metrics and summary data to an external backend
- `GEPA.Telemetry` emits a stable event schema for handlers that prefer Telemetry over callbacks

These layers sit on top of the engine. They do not change candidate semantics, but they make long runs observable and restartable.
