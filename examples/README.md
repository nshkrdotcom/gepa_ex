# GEPA Examples

This directory contains working examples demonstrating various GEPA features and use cases.

## Quick Reference

| Example | Description | Complexity | Run Time |
|---------|-------------|------------|----------|
| [01_quick_start.exs](01_quick_start.exs) | Simplest possible example (10 lines) | ⭐ Beginner | < 1 second |
| [02_math_problems.exs](02_math_problems.exs) | Math word problems with epoch sampling | ⭐⭐ Intermediate | 1-2 seconds |
| [03_custom_adapter.exs](03_custom_adapter.exs) | Build your own adapter | ⭐⭐⭐ Advanced | < 1 second |
| [04_state_persistence.exs](04_state_persistence.exs) | Save/resume optimizations | ⭐⭐ Intermediate | < 1 second |
| [05_llm_adapters.exs](05_llm_adapters.exs) | GEPA LLM facade with ReqLLM and Agent Session Manager adapters | ⭐⭐ Intermediate | < 1 second, then exactly one live call |

## Running Examples

### Deterministic Examples

Examples 01-04 use deterministic mock/fake LLM paths and make no live provider calls:

```bash
mix run examples/01_quick_start.exs
mix run examples/02_math_problems.exs
mix run examples/03_custom_adapter.exs
mix run examples/04_state_persistence.exs
```

### Live Hosted Provider Smoke Test

`05_llm_adapters.exs` first demonstrates the GEPA LLM port with injected fake ReqLLM and ASM modules, then makes exactly one live hosted-provider call. It is not skipped automatically and it does not read shell variables. Pass credentials explicitly:

```bash
mix run examples/05_llm_adapters.exs -- --provider openai --api-key sk-...
mix run examples/05_llm_adapters.exs -- --provider gemini --api-key ...
mix run examples/05_llm_adapters.exs -- --provider anthropic --api-key ...
```

Use `--model` to override the adapter default:

```bash
mix run examples/05_llm_adapters.exs -- --provider openai --model gpt-4o-mini --api-key sk-...
```

### Run All Script

`examples/run_all.sh` runs examples 01-04, then runs example 05. The script prints that the last step is live and forwards explicit CLI credentials to example 05:

```bash
examples/run_all.sh --provider openai --api-key sk-...
```

This script is intentionally not silent about the live call. It does not inspect shell variables or skip the live section.

## Example Details

### 01_quick_start.exs

**What it does:**
- Optimizes a simple Q&A system
- Uses 3 training examples
- Runs for 10 iterations
- Perfect for understanding GEPA basics

**Key concepts:**
- `GEPA.optimize/1` - Main API
- `seed_candidate` - Initial instruction
- `trainset` and `valset` - Data
- `adapter` - System integration

**Expected output:**
```
🚀 GEPA Quick Start Example
===========================
...
✅ Optimization Complete!
Best score: 0.667
```

### 02_math_problems.exs

**What it does:**
- Optimizes math problem-solving
- Uses EpochShuffledBatchSampler
- Uses deterministic mock LLM output
- Demonstrates domain-specific optimization

**Key concepts:**
- Domain-specific prompts
- Advanced batch sampling
- Deterministic adapter wiring
- Performance measurement

**Expected output:**
```
🧮 GEPA Math Problems Example
==============================
...
Best validation score: 0.857
Improvement: +25.0 percentage points
```

### 03_custom_adapter.exs

**What it does:**
- Shows how to implement `GEPA.Adapter` behavior
- Custom evaluation for sentiment classification
- Component-specific feedback extraction
- Integration patterns

**Key concepts:**
- `evaluate/4` callback - Custom scoring
- `extract_component_context/6` - Feedback generation
- Domain-specific prompts
- Trace handling

**Expected output:**
```
💭 GEPA Custom Adapter Example
==============================
...
What you learned:
- How to implement the GEPA.Adapter behavior
- Custom evaluation logic for your domain
```

**Customization guide:**
1. Copy the `CustomSentimentAdapter` module
2. Modify `evaluate/4` for your task
3. Implement your scoring logic
4. Extract relevant feedback in `extract_component_context/6`
5. Test with your data

### 04_state_persistence.exs

**What it does:**
- Saves optimization state to disk
- Automatically resumes on restart
- Demonstrates incremental optimization
- Shows graceful stopping

**Key concepts:**
- `run_dir` option for persistence
- Automatic state save/load
- Incremental progress
- Graceful shutdown with `gepa.stop` file

**Expected output:**
```
💾 GEPA State Persistence Example
=================================
...
⏸️  Paused at iteration 5/15
To continue, run this script again
```

**Workflow:**
1. Run script → saves state to `./tmp/gepa_example_run/`
2. Run again → resumes from saved state
3. Repeat until target iterations reached
4. To stop early: `touch ./tmp/gepa_example_run/gepa.stop`

### 05_llm_adapters.exs

**What it does:**
- Builds GEPA LLM clients with `GEPA.LLM.req_llm/2` and `GEPA.LLM.agent/2`
- Proves the public value is a `GEPA.LLM.Client`, not a raw ReqLLM or ASM object
- Demonstrates structured output support through the ReqLLM adapter
- Demonstrates ASM structured output failing closed
- Runs exactly one live hosted-provider completion with explicit `--api-key`

**Key concepts:**
- Adapter injection for deterministic tests/examples
- Hosted vs. local agent provider routing
- Migration-safe `GEPA.LLM.Client` boundary
- Capability checks for unsupported features

## Common Patterns

### Basic Optimization

```elixir
{:ok, result} = GEPA.optimize(
  seed_candidate: %{"instruction" => "..."},
  trainset: trainset,
  valset: valset,
  adapter: adapter,
  max_metric_calls: 50
)

best = GEPA.Result.best_candidate(result)
score = GEPA.Result.best_score(result)
```

### With GEPA LLM Port Adapters

```elixir
# Hosted providers through the ReqLLM adapter.
llm = GEPA.LLM.req_llm(:openai, api_key: "sk-...")
llm = GEPA.LLM.req_llm(:gemini, api_key: "...")
llm = GEPA.LLM.req_llm(:anthropic, api_key: "...")

# Local Codex/Claude/Gemini/Amp through the Agent Session Manager adapter.
llm = GEPA.LLM.agent(:codex, lane: :core, session: :my_session)

# Mock for tests and deterministic examples.
llm = GEPA.LLM.Mock.new()

adapter = GEPA.Adapters.Basic.new(llm: llm)
```

`GEPA.LLM.req_llm/2` is a GEPA facade constructor. It returns `GEPA.LLM.Client` with `GEPA.LLM.Adapters.ReqLLM` stored behind the port. Optimizer/proposer code should call `GEPA.LLM.complete/3` or `GEPA.LLM.complete_structured/3`, not `ReqLLM.*`.

### With The Default Adapter

For a simple single-prompt task, pass `:task_lm` and GEPA will build `GEPA.Adapters.Default`:

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

Use an explicit adapter when your task needs custom execution, tracing, tools, or non-chat inputs.

### With Acceptance Criteria, Callbacks, And Cache

```elixir
cache = GEPA.EvaluationCache.new()

callback = fn event_name, event ->
  IO.inspect({event_name, event[:iteration]})
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

### With Epoch Shuffling

```elixir
batch_sampler = GEPA.Strategies.BatchSampler.EpochShuffled.new(
  minibatch_size: 5,
  seed: 42
)

{:ok, result} = GEPA.optimize(
  # ...
  batch_sampler: batch_sampler
)
```

### With State Persistence

```elixir
{:ok, result} = GEPA.optimize(
  # ...
  run_dir: "./my_optimization"
)

# Run again to resume:
# mix run my_script.exs
# State automatically loaded from ./my_optimization/
```

## Troubleshooting

### "Module GEPA not found"

Make sure you're running from the project root:

```bash
cd gepa_ex
mix run examples/01_quick_start.exs
```

### Mock LLM gives strange results

This is expected. Mock LLM returns deterministic responses. For a live hosted-provider smoke test:

```bash
mix run examples/05_llm_adapters.exs -- --provider openai --api-key sk-...
```

### State file corrupted

Delete the state directory and start fresh:

```bash
rm -rf ./tmp/gepa_example_run
mix run examples/04_state_persistence.exs
```

### LLM API rate limits

If you hit rate limits with real LLMs:
1. Reduce `max_metric_calls`
2. Use smaller training sets
3. Add delays between calls
4. Use mock LLM for testing

## Next Steps

After trying these examples:

1. **Read the docs**: See `docs/` for detailed guides
2. **Create your adapter**: Based on `03_custom_adapter.exs`
3. **Run real optimizations**: With your own data and tasks
4. **Experiment with parameters**: Try different batch sizes, iterations, etc.
5. **Share your results**: Open an issue or discussion!

## Need Help?

- **Documentation**: See `../docs/` directory
- **Issues**: https://github.com/yourorg/gepa_ex/issues
- **Discussions**: https://github.com/yourorg/gepa_ex/discussions

## Contributing Examples

Have a cool use case? We'd love to add more examples!

1. Fork the repo
2. Add your example to `examples/`
3. Follow the naming convention: `NN_description.exs`
4. Include documentation and expected output
5. Submit a PR

Good example ideas:
- Code generation optimization
- Multi-turn conversation
- Retrieval-augmented generation (RAG)
- Domain-specific tasks (legal, medical, etc.)
- Integration with Phoenix/LiveView
- Batch processing pipelines
