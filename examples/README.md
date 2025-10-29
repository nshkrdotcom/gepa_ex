# GEPA Examples

This directory contains working examples demonstrating various GEPA features and use cases.

## Quick Reference

| Example | Description | Complexity | Run Time |
|---------|-------------|------------|----------|
| [01_quick_start.exs](01_quick_start.exs) | Simplest possible example (10 lines) | ⭐ Beginner | < 1 second |
| [02_math_problems.exs](02_math_problems.exs) | Math word problems with epoch sampling | ⭐⭐ Intermediate | 1-2 seconds (mock), 1-2 mins (real LLM) |
| [03_custom_adapter.exs](03_custom_adapter.exs) | Build your own adapter | ⭐⭐⭐ Advanced | < 1 second |
| [04_state_persistence.exs](04_state_persistence.exs) | Save/resume optimizations | ⭐⭐ Intermediate | < 1 second |

## Running Examples

### With Mock LLM (No API Key Needed)

All examples work with mock LLM by default:

```bash
mix run examples/01_quick_start.exs
mix run examples/02_math_problems.exs
mix run examples/03_custom_adapter.exs
mix run examples/04_state_persistence.exs
```

### With Real LLMs

#### OpenAI (GPT-4o-mini)

```bash
export OPENAI_API_KEY=sk-...
mix run examples/01_quick_start.exs
mix run examples/02_math_problems.exs
```

#### Google Gemini (Gemini-2.0-Flash-Exp)

```bash
export GEMINI_API_KEY=...
mix run examples/01_quick_start.exs
mix run examples/02_math_problems.exs
```

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
- Works with mock or real LLMs
- Demonstrates domain-specific optimization

**Key concepts:**
- Domain-specific prompts
- Advanced batch sampling
- LLM provider selection
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

### With Real LLM

```elixir
# OpenAI
llm = GEPA.LLM.ReqLLM.new(provider: :openai)

# Gemini
llm = GEPA.LLM.ReqLLM.new(provider: :gemini)

# Mock (testing)
llm = GEPA.LLM.Mock.new()

adapter = GEPA.Adapters.Basic.new(llm: llm)
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

This is expected! Mock LLM returns canned responses. For realistic optimization:

```bash
export OPENAI_API_KEY=sk-...
mix run examples/02_math_problems.exs
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
