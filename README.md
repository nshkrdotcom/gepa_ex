<p align="center">
  <img src="assets/gepa_ex.svg" alt="GEPA Elixir Logo" width="200" height="200">
</p>

# GEPA for Elixir

[![Hex.pm](https://img.shields.io/hexpm/v/gepa_ex.svg)](https://hex.pm/packages/gepa_ex)
[![Elixir](https://img.shields.io/badge/elixir-1.18.3-purple.svg)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/otp-27.3.3-blue.svg)](https://www.erlang.org)
[![Tests](https://img.shields.io/badge/tests-329%2F329%20passing-brightgreen)]()
[![Coverage](https://img.shields.io/badge/coverage-75.4%25-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/nshkrdotcom/gepa_ex/blob/main/LICENSE)

An Elixir implementation of GEPA (Genetic-Pareto), a framework for optimizing text-based system components using LLM-based reflection and Pareto-efficient evolutionary search.

## Installation

Add `gepa_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gepa_ex, "~> 0.1.2"}
  ]
end
```

## About GEPA

GEPA optimizes arbitrary systems composed of text components—like AI prompts, code snippets, or textual specs—against any evaluation metric. It employs LLMs to reflect on system behavior, using feedback from execution traces to drive targeted improvements.

This is an Elixir port of the [Python GEPA library](https://github.com/gepa-ai/gepa), designed to leverage:
- 🚀 **BEAM concurrency** for parallel evaluation
- 🛡️ **OTP supervision** for fault-tolerant external service integration
- 🔄 **Functional programming** for clean, testable code
 - 📊 **Telemetry** event schema for lifecycle, iteration, proposal, and evaluation metrics
- ✨ **Production LLMs** - OpenAI, Google Gemini, and Anthropic through ReqLLM
- 🧩 **Local agent facade** - Codex, Claude, Gemini, and Amp routing through Agent Session Manager

## Production Ready

### Core Features

**Optimization System:**
- ✅ `GEPA.optimize/1` - Public API (working!)
- ✅ `GEPA.Engine` - Full optimization loop with stop conditions
- ✅ `GEPA.Proposer.Reflective` - Mutation strategy
- ✅ LLM-based instruction proposal via `reflection_llm` and custom templates
- ✅ `GEPA.State` - State management with Pareto, objective-frontier, cache, and best-output tracking
- ✅ `GEPA.Utils.Pareto` - Multi-objective optimization (93.5% coverage, property-verified)
- ✅ `GEPA.Result` - Result analysis with objective metadata and round-trip serialization
- ✅ `GEPA.OptimizeAnything` - Universal optimizer API for arbitrary evaluators
- ✅ `GEPA.CodeExecution` - Elixir code execution helper for evaluator workflows
- ✅ `GEPA.Tracking` - Tracker behavior with in-memory and no-op backends
- ✅ `GEPA.Adapters.Basic` - Q&A adapter (92.1% coverage)
- ✅ `GEPA.Adapters.Default` - Official-style default adapter for simple chat-model tasks
- ✅ Stop conditions with budget, callback, run-dir file, timeout, score-threshold, tracked-candidate, reflection-cost, proposal-count, and explicit signal controls
- ✅ State persistence (save/load) with adapter-state snapshots and candidate JSON sidecars
- ✅ Acceptance criteria (`:strict_improvement`, `:improvement_or_equal`, or custom function/module)
- ✅ Synchronous observational callbacks for optimization and iteration lifecycle
- ✅ Evaluation cache for candidate/example validation results
- ✅ Telemetry event emitters for runs, iterations, proposals, and evaluation batches
- ✅ End-to-end integration tested

### LLM Integration

**Production LLM Integration:**
- ✅ `GEPA.LLM` - Unified LLM behavior
- ✅ `GEPA.LLM.req_llm/2` - Hosted provider facade via ReqLLM
  - OpenAI support (`gpt-5.4-mini` default)
  - Google Gemini support (gemini-3.1-flash-lite-preview)
  - Anthropic support through ReqLLM
  - Error handling, retries, timeouts
  - Configurable via explicit runtime options, application config, or provider key defaults
- ✅ `GEPA.LLM.agent/2` - Local CLI/agent facade via Agent Session Manager
- ✅ `GEPA.LLM.ReqLLM` - Backward-compatible ReqLLM wrapper

**Advanced Batch Sampling:**
- ✅ `GEPA.Strategies.BatchSampler.EpochShuffled` - Epoch-based training with shuffling
- ✅ Reproducible with seed control
- ✅ Better training dynamics than simple sampling

**Working Examples:**
- ✅ 12 live-only .exs script examples covering core optimization, LLM adapters, stop conditions, policies, optimize-anything, code execution, refiner, and tracking
- ✅ 3 Livebook notebooks (interactive learning)
- ✅ Comprehensive examples/README.md guide

**Additional Core Coverage:**

**Merge Proposer:**
- ✅ `GEPA.Proposer.Merge` - Genealogy-based candidate merging
- ✅ `GEPA.Utils` - Pareto dominator detection (93.3% coverage)
- ✅ `GEPA.Proposer.MergeUtils` - Ancestry tracking (92.3% coverage)
- ✅ Engine integration with merge scheduling
- ✅ 44 comprehensive tests (34 unit + 10 properties)

**Incremental Evaluation:**
- ✅ `GEPA.Strategies.EvaluationPolicy.Incremental` - Progressive validation
- ✅ Configurable sample sizes and thresholds
- ✅ Reduces computation on large validation sets
- ✅ 12 tests

**Advanced Stop Conditions:**
- ✅ `GEPA.StopCondition.Timeout` - Time-based stopping
- ✅ `GEPA.StopCondition.NoImprovement` - Early stopping
- ✅ `GEPA.StopCondition.FileStopper` - Run-dir stop-file checks
- ✅ `GEPA.StopCondition.ScoreThreshold` - Stop when target score is reached
- ✅ `GEPA.StopCondition.MaxTrackedCandidates` - Candidate-count budget
- ✅ `GEPA.StopCondition.MaxCandidateProposals` - Proposal-count budget
- ✅ `GEPA.StopCondition.MaxReflectionCost` - Reflection cost budget
- ✅ `GEPA.StopCondition.SignalStopper` - Explicit BEAM-safe stop request
- ✅ Flexible time units and patience settings

**Test Quality:**
- 385 tests + 16 properties + 1 doctest
- 100% passing ✅
- 75.4% coverage (excellent!)
- Property tests with 1,600+ runs
- Zero Dialyzer errors
- TDD methodology throughout

## Scope

This port focuses on the GEPA optimizer core. The Python project's task-specific adapter families and visualization/UI layer are intentionally out of scope here; use the project-owned adapters or implement `GEPA.Adapter` for task integration.

## Quick Start

### Live Examples

The scripts in `examples/` are live-only. They call real ReqLLM or Agent Session Manager backends and print a cost warning before any LLM call. They use sensible hosted-provider defaults from configured keys, while explicit CLI options always override the defaults.

Fastest live smoke:

```bash
mix run examples/05_llm_adapters.exs -- --simple
```

Run every example with small built-in demo prompts/data:

```bash
examples/run_all.sh --simple
```

Default hosted-provider key lookup:

- Gemini: `GEMINI_API_KEY`, then `GOOGLE_API_KEY`
- OpenAI: `OPENAI_API_KEY`
- Anthropic: `ANTHROPIC_API_KEY`

ReqLLM OpenAI:

```bash
mix run examples/01_quick_start.exs -- \
  --provider openai \
  --train-jsonl /path/to/qa_train.jsonl \
  --val-jsonl /path/to/qa_val.jsonl
```

ASM Codex:

```bash
mix run examples/01_quick_start.exs -- \
  --adapter asm \
  --provider codex \
  --lane core \
  --session gepa_quick_start \
  --train-jsonl /path/to/qa_train.jsonl \
  --val-jsonl /path/to/qa_val.jsonl
```

See [Examples overview](examples/README.md) for the full onboarding guide, data schemas, `run_all.sh`, cost warnings, and troubleshooting.

### With Production LLMs

```elixir
# OpenAI through the ReqLLM adapter. Uses OPENAI_API_KEY by default.
llm = GEPA.LLM.req_llm(:openai)
adapter = GEPA.Adapters.Basic.new(llm: llm)

# Gemini through the ReqLLM adapter. Uses GEMINI_API_KEY, then GOOGLE_API_KEY.
llm = GEPA.LLM.req_llm(:gemini)
adapter = GEPA.Adapters.Basic.new(llm: llm)

# Anthropic Claude through the ReqLLM adapter. Uses ANTHROPIC_API_KEY.
llm = GEPA.LLM.req_llm(:anthropic)
adapter = GEPA.Adapters.Basic.new(llm: llm)

# Then run optimization as above
{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "..."},
  trainset: trainset,
  valset: valset,
  adapter: adapter,
  max_metric_calls: 50
)
```

### With The Default Adapter

For simple prompt optimization, you can provide a task model callable and let GEPA build the default adapter:

```elixir
task_lm = fn messages ->
  user = Enum.find(messages, &(&1.role == "user"))
  "Answer for: #{user.content}"
end

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{"instruction" => "Answer exactly."},
    trainset: [%{input: "What is 2+2?", answer: "4"}],
    valset: [%{input: "What is 5+5?", answer: "10"}],
    max_metric_calls: 20,
    task_lm: task_lm
  )
```

Pass a custom `:evaluator` if answer containment is not the right metric.

### Local Agent Providers

When `../agent_session_manager` is available, GEPA can also route local agent calls through the same facade:

```elixir
client = GEPA.LLM.agent(:codex, lane: :core, session: "gepa_my_session")
{:ok, text} = GEPA.LLM.complete(client, "Summarize this GEPA run")
```

This adapter is intentionally a temporary migration-safe boundary. GEPA optimizer code depends on `GEPA.LLM.Client`, not on ReqLLM or Agent Session Manager directly, so the facade can move to a future shared inference package without changing GEPA internals.

`GEPA.LLM.req_llm/2` and `GEPA.LLM.agent/2` are constructor helpers for the GEPA port. They return `GEPA.LLM.Client` values; optimizer/proposer code should continue calling `GEPA.LLM.complete/3` and `GEPA.LLM.complete_structured/3` instead of calling ReqLLM, ASM, or CLI SDK modules directly.

### Candidate Selection Strategies (NEW)

GEPA includes multiple candidate selectors to balance exploration vs. exploitation:

- `:pareto` / `GEPA.Strategies.CandidateSelector.Pareto` (default): frequency-weighted sampling from Pareto front
- `:current_best` / `GEPA.Strategies.CandidateSelector.CurrentBest`: always pick the best-scoring program
- `:epsilon_greedy` / `GEPA.Strategies.CandidateSelector.EpsilonGreedy`: configurable exploration with optional epsilon decay
- `:top_k_pareto` / `GEPA.Strategies.CandidateSelector.TopKPareto`: sample from the top-scoring Pareto candidates

Stateful selectors (like epsilon-greedy) are carried forward automatically so decay persists across iterations.

To enable epsilon-greedy with decay:

```elixir
selector =
  GEPA.Strategies.CandidateSelector.EpsilonGreedy.new(
    epsilon: 0.3,
    epsilon_decay: 0.95,
    epsilon_min: 0.05
  )

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{"instruction" => "..."},
    trainset: trainset,
    valset: valset,
    adapter: adapter,
    max_metric_calls: 50,
    candidate_selection_strategy: selector
  )
```

`GEPA.optimize/1` also accepts upstream-style public options for strategy and
budget construction:

- `:valset` is optional and defaults to `:trainset`.
- At least one stopping path is required: `:max_metric_calls`,
  `:max_reflection_cost`, `:max_candidate_proposals`, `:stop_conditions`,
  `:stop_callbacks`, or `:run_dir`.
- `:batch_sampler` supports `:epoch_shuffled` or a custom sampler.
- `:module_selector` supports `:round_robin`, `:all`, or a custom selector.
- `:val_evaluation_policy` supports `:full_eval` or a custom policy.
- `:cache_evaluation` creates an evaluation cache for validation scoring.
- `:use_merge`, `:max_merge_invocations`, and `:merge_val_overlap_floor`
  construct the merge proposer.

### LLM-Based Instruction Proposal (NEW!)

Use an LLM to propose improved component instructions based on reflective feedback. You can also provide a custom proposal template.

```elixir
reflection_llm = GEPA.LLM.req_llm(:openai, api_key: "sk-...", model: "gpt-5.4-mini")

custom_template = """
Improve {component_name}:
Current: {current_instruction}
Feedback: {reflective_dataset}
New instruction:
"""

{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "You are a concise math tutor."},
  trainset: trainset,
  valset: valset,
  adapter: adapter,
  max_metric_calls: 50,
  reflection_llm: reflection_llm,
  proposal_template: custom_template
)
```

### Advanced Optimizer Controls

```elixir
cache = GEPA.EvaluationCache.new()

callback = fn event_name, event ->
  IO.inspect({event_name, Map.take(event, [:iteration, :proposal_accepted])})
end

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{"instruction" => "..."},
    trainset: trainset,
    valset: valset,
    adapter: adapter,
    max_metric_calls: 50,
    acceptance_criterion: :improvement_or_equal,
    callbacks: [callback],
    track_best_outputs: true,
    evaluation_cache: cache
  )
```

When `reflection_llm` is not provided, the adapter must implement `propose_new_texts/4` or `/3`, or you must pass `:custom_candidate_proposer`. GEPA does not use placeholder production mutations.

### Optimize Anything

`GEPA.OptimizeAnything.optimize_anything/1` wraps arbitrary evaluators in the normal GEPA engine. It supports single-task, dataset, and generalization modes; string and map candidates; evaluator log/stdout side information; memory/disk evaluation caching; top-K best eval injection through `GEPA.OptimizeAnything.OptimizationState`; optional per-evaluation refiner; code-execution evaluators; and `GEPA.Tracking`.

```elixir
evaluator = fn prompt ->
  score = if String.contains?(prompt, "concise"), do: 1.0, else: 0.0
  {score, %{Feedback: "Prefer concise answers.", scores: %{"quality" => score}}}
end

{:ok, result} =
  GEPA.OptimizeAnything.optimize_anything(
    seed_candidate: "Answer the question.",
    evaluator: evaluator,
    objective: "Improve answer quality.",
    engine: %{max_metric_calls: 10, cache_evaluation: :memory},
    reflection: %{reflection_lm: reflection_llm, skip_perfect_score: false}
  )
```

### Interactive Livebooks (NEW!)

For interactive learning and experimentation:

```bash
# Install Livebook
mix escript.install hex livebook

# Open a livebook
livebook server livebooks/01_quick_start.livemd
```

Available Livebooks:
- `01_quick_start.livemd` - Interactive introduction
- `02_advanced_optimization.livemd` - Parameter tuning
- `03_custom_adapter.livemd` - Build adapters interactively

See [livebooks/README.md](livebooks/README.md) for details!

### With State Persistence

```elixir
{:ok, result} = GEPA.optimize(
  seed_candidate: seed,
  trainset: trainset,
  valset: valset,
  adapter: GEPA.Adapters.Basic.new(),
  max_metric_calls: 100,
  run_dir: "./my_optimization"  # State saved here, can resume
)
```

## Development

```bash
# Get dependencies
mix deps.get

# Run tests
mix test

# Run with coverage
mix test --cover

# Run specific tests
mix test test/gepa/utils/pareto_test.exs

# Format code
mix format

# Type checking
mix dialyzer
```

## Architecture

Based on behavior-driven design with functional core:

```
GEPA.optimize/1
  ↓
GEPA.Engine ← Behaviors → User Implementations
  ├─→ Adapter (evaluate, reflect, propose)
  ├─→ Proposer (reflective, merge)
  ├─→ Strategies (selection, sampling, evaluation)
  └─→ StopCondition (budget, time, threshold)
```

## Documentation

### Technical Documentation
- [Technical Design](docs/TECHNICAL_DESIGN.md)
- [LLM Adapter Design](docs/llm_adapter_design.md) - Design for real LLM integration
- [Completing the Port (Plans)](docs/20251129/completing-the-port/README.md)

## Changelog

### v0.1.2 (2025-11-29)
- Epsilon-greedy candidate selector with decay/reset and stateful selector support in engine/proposer
- Telemetry event schema and LLM-backed instruction proposal with custom templates
- Reflective proposer requires adapter proposal, custom proposal, or reflection LLM; production placeholder mutation is not used
- Docs for completing the port and telemetry-first experiment tracking

### v0.1.1 (2025-11-29)
- Documentation cleanup and release tagging

### v0.1.0 (2025-10-29)
- Initial release with Phase 1 & 2 complete
- Production LLM integration (OpenAI `gpt-5.4-mini`, Google Gemini Flash Lite)
- Core optimization engine with reflective and merge proposers
- Incremental evaluation and advanced stop conditions
- 218 tests passing with 75.4% coverage

## Related Projects

- [GEPA Python](https://github.com/gepa-ai/gepa) - Original implementation
- [GEPA Paper](https://arxiv.org/abs/2507.19457) - Research paper

## License

[MIT License](LICENSE)
