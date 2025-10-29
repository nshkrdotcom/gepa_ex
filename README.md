# GEPA for Elixir

An Elixir implementation of GEPA (Genetic-Pareto), a framework for optimizing text-based system components using LLM-based reflection and Pareto-efficient evolutionary search.

**Status:** 🔨 Foundation Complete (65.1% coverage) | 🚧 MVP In Progress | v0.1.0-dev

[![Tests](https://img.shields.io/badge/tests-37%2F37%20passing-brightgreen)]()
[![Coverage](https://img.shields.io/badge/coverage-65.1%25-yellow)]()

## About GEPA

GEPA optimizes arbitrary systems composed of text components—like AI prompts, code snippets, or textual specs—against any evaluation metric. It employs LLMs to reflect on system behavior, using feedback from execution traces to drive targeted improvements.

This is an Elixir port of the [Python GEPA library](https://github.com/gepa-ai/gepa), designed to leverage:
- 🚀 **BEAM concurrency** for 5-10x evaluation speedup
- 🛡️ **OTP supervision** for fault-tolerant external service integration
- 🔄 **Functional programming** for clean, testable code
- 📊 **Telemetry** for comprehensive observability

## Implementation Status

### ✅ Completed (37/37 tests passing)

**Foundation (100% coverage):**
- Core data structures (EvaluationBatch, CandidateProposal, State)
- Pareto optimization utilities with property-based tests
- Core behaviors (Adapter, DataLoader, Proposer, StopCondition)
- Test infrastructure and helpers

**Pareto Utilities (100% coverage, 17 tests):**
- ✅ Domination checking
- ✅ Dominated program removal
- ✅ Frequency-weighted selection
- ✅ 6 property-based tests
- ✅ 11 unit tests

### 🚧 In Progress

- State management functions
- Strategies (CandidateSelector, BatchSampler, etc.)
- Reflective mutation proposer

### 📋 Planned (2-3 weeks)

- Optimization engine
- Public API
- Basic adapter
- End-to-end tests

## Quick Start (Planned API)

```elixir
# Define training data
trainset = [
  %{input: "What is 2+2?", answer: "4"},
  %{input: "What is 3+3?", answer: "6"}
]

# Run optimization
{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "You are a helpful assistant."},
  trainset: trainset,
  valset: [%{input: "What is 5+5?", answer: "10"}],
  adapter: GEPA.Adapters.Basic,
  max_metric_calls: 50
)

IO.inspect(result.best_candidate)
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

See `docs/` for comprehensive documentation:
- [Complete Integration Guide](docs/20250829/00_complete_integration_guide.md)
- [Technical Design](docs/TECHNICAL_DESIGN.md)
- [Implementation Status](docs/IMPLEMENTATION_STATUS.md)
- Component analysis (6 detailed documents)

## Related Projects

- [GEPA Python](https://github.com/gepa-ai/gepa) - Original implementation
- [GEPA Paper](https://arxiv.org/abs/2507.19457) - Research paper

## License

MIT License

