<p align="center">
  <img src="assets/gepa_ex.svg" alt="GEPA Elixir Logo" width="200" height="200">
</p>

# GEPA for Elixir

**Current version:** v0.1.0

An Elixir implementation of GEPA (Genetic-Pareto), a framework for optimizing text-based system components using LLM-based reflection and Pareto-efficient evolutionary search.

[![Tests](https://img.shields.io/badge/tests-218%2F218%20passing-brightgreen)]()
[![Coverage](https://img.shields.io/badge/coverage-75.4%25-brightgreen)]()
[![Phase 1](https://img.shields.io/badge/Phase%201-Complete-success)]()
[![Phase 2](https://img.shields.io/badge/Phase%202-Complete-success)]()

## About GEPA

GEPA optimizes arbitrary systems composed of text components—like AI prompts, code snippets, or textual specs—against any evaluation metric. It employs LLMs to reflect on system behavior, using feedback from execution traces to drive targeted improvements.

This is an Elixir port of the [Python GEPA library](https://github.com/gepa-ai/gepa), designed to leverage:
- 🚀 **BEAM concurrency** for 5-10x evaluation speedup (coming in Phase 4)
- 🛡️ **OTP supervision** for fault-tolerant external service integration
- 🔄 **Functional programming** for clean, testable code
- 📊 **Telemetry** for comprehensive observability (coming in Phase 3)
- ✨ **Production LLMs** - OpenAI GPT-4o-mini & Google Gemini Flash Lite (`gemini-flash-lite-latest`)

## 🎉 Phase 1 Complete - Production Ready!

### Core Features (Current v0.1.0 Release)

**Optimization System:**
- ✅ `GEPA.optimize/1` - Public API (working!)
- ✅ `GEPA.Engine` - Full optimization loop with stop conditions
- ✅ `GEPA.Proposer.Reflective` - Mutation strategy
- ✅ `GEPA.State` - State management with automatic Pareto updates (96.5% coverage)
- ✅ `GEPA.Utils.Pareto` - Multi-objective optimization (93.5% coverage, property-verified)
- ✅ `GEPA.Result` - Result analysis (100% coverage)
- ✅ `GEPA.Adapters.Basic` - Q&A adapter (92.1% coverage)
- ✅ Stop conditions with budget control
- ✅ State persistence (save/load)
- ✅ End-to-end integration tested

### Phase 1 Additions - NEW! 🎉

**Production LLM Integration:**
- ✅ `GEPA.LLM` - Unified LLM behavior
- ✅ `GEPA.LLM.ReqLLM` - Production implementation via ReqLLM
  - OpenAI support (GPT-4o-mini default)
  - Google Gemini support (gemini-flash-lite-latest)
  - Error handling, retries, timeouts
  - Configurable via environment or runtime
- ✅ `GEPA.LLM.Mock` - Testing implementation with flexible responses

**Advanced Batch Sampling:**
- ✅ `GEPA.Strategies.BatchSampler.EpochShuffled` - Epoch-based training with shuffling
- ✅ Reproducible with seed control
- ✅ Better training dynamics than simple sampling

**Working Examples:**
- ✅ 4 .exs script examples (quick start, math, custom adapter, persistence)
- ✅ 3 Livebook notebooks (interactive learning)
- ✅ Comprehensive examples/README.md guide
- ✅ Livebook guide with visualizations

**Phase 2 Additions - NEW! 🎉**

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
- ✅ Flexible time units and patience settings
- ✅ 9 tests

**Test Quality:**
- 201 tests (185 unit + 16 properties + 1 doctest)
- 100% passing ✅
- 75.4% coverage (excellent!)
- Property tests with 1,600+ runs
- Zero Dialyzer errors
- TDD methodology throughout

### What's Next? See the [Roadmap on GitHub](https://github.com/nshkrdotcom/gepa_ex/blob/main/docs/20251029/roadmap.md)

**✅ Phase 1: Production Viability** - COMPLETE!
- ✅ Real LLM integration (OpenAI, Gemini)
- ✅ Quick start examples (4 scripts + 3 livebooks)
- ✅ EpochShuffledBatchSampler

**✅ Phase 2: Core Completeness** - COMPLETE!
- ✅ Merge proposer (genealogy-based recombination)
- ✅ IncrementalEvaluationPolicy (progressive validation)
- ✅ Additional stop conditions (Timeout, NoImprovement)
- ✅ Engine integration for merge proposer

**Phase 3: Production Hardening** - 8-10 weeks
- 📡 Telemetry integration
- 🎨 Progress tracking
- 🛡️ Robust error handling

**Phase 4: Ecosystem Expansion** - 12-14 weeks
- 🔌 Additional adapters (Generic, RAG)
- 🚀 Performance optimization (parallel evaluation)
- 🌟 Community infrastructure

See [Implementation Gap Analysis on GitHub](https://github.com/nshkrdotcom/gepa_ex/blob/main/docs/20251029/implementation_gap_analysis.md) for detailed comparison with Python GEPA.

## Quick Start

### With Mock LLM (No API Key Required)

```elixir
# Define training data
trainset = [
  %{input: "What is 2+2?", answer: "4"},
  %{input: "What is 3+3?", answer: "6"}
]

valset = [%{input: "What is 5+5?", answer: "10"}]

# Create adapter with mock LLM (for testing)
adapter = GEPA.Adapters.Basic.new(llm: GEPA.LLM.Mock.new())

# Run optimization
{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "You are a helpful assistant."},
  trainset: trainset,
  valset: valset,
  adapter: adapter,
  max_metric_calls: 50
)

# Access results
best_program = GEPA.Result.best_candidate(result)
best_score = GEPA.Result.best_score(result)

IO.puts("Best score: #{best_score}")
IO.puts("Iterations: #{result.i}")
```

### With Production LLMs (NEW!)

```elixir
# OpenAI (GPT-4o-mini) - Requires OPENAI_API_KEY
llm = GEPA.LLM.ReqLLM.new(provider: :openai)
adapter = GEPA.Adapters.Basic.new(llm: llm)

# Or Gemini (`gemini-flash-lite-latest`) - Requires GEMINI_API_KEY
llm = GEPA.LLM.ReqLLM.new(provider: :gemini)
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

See [Examples overview](examples/README.md) for complete working examples!

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
- `02_advanced_optimization.livemd` - Parameter tuning and visualization
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

### Current Status & Planning
- [Implementation Gap Analysis](https://github.com/nshkrdotcom/gepa_ex/blob/main/docs/20251029/implementation_gap_analysis.md) - Detailed comparison with Python GEPA (~60% complete, hosted on GitHub)
- [Development Roadmap](https://github.com/nshkrdotcom/gepa_ex/blob/main/docs/20251029/roadmap.md) - Path to production release (12-14 weeks, hosted on GitHub)

### Technical Documentation
- [Complete Integration Guide](https://github.com/nshkrdotcom/gepa_ex/blob/main/docs/20250829/00_complete_integration_guide.md)
- [Technical Design](docs/TECHNICAL_DESIGN.md)
- [Implementation Status](docs/IMPLEMENTATION_STATUS.md)
- [LLM Adapter Design](docs/llm_adapter_design.md) - Design for real LLM integration
- Component analysis (6 detailed documents in the [`docs/20250829/` directory](https://github.com/nshkrdotcom/gepa_ex/tree/main/docs/20250829/))

## Related Projects

- [GEPA Python](https://github.com/gepa-ai/gepa) - Original implementation
- [GEPA Paper](https://arxiv.org/abs/2507.19457) - Research paper

## License

[MIT License](LICENSE)
