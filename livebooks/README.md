# GEPA Livebook Examples

Interactive notebooks for learning and experimenting with GEPA.

## What are Livebooks?

[Livebook](https://livebook.dev/) is an interactive notebook environment for Elixir. These notebooks let you:
- Run code interactively
- See results immediately
- Visualize data with Kino
- Experiment with parameters
- Learn by doing

## Available Livebooks

### 1. Quick Start (`01_quick_start.livemd`)
**Perfect for:** First-time users
**Duration:** 5-10 minutes
**Prerequisites:** None (works with mock LLM)

**What you'll learn:**
- Basic GEPA concepts
- Running your first optimization
- Understanding results
- Switching between LLM providers

**Interactive features:**
- Choose LLM provider (Mock/OpenAI/Gemini)
- See results immediately
- Visualize score progression

### 2. Advanced Optimization (`02_advanced_optimization.livemd`)
**Perfect for:** Intermediate users
**Duration:** 15-20 minutes
**Prerequisites:** Basic GEPA understanding

**What you'll learn:**
- EpochShuffledBatchSampler
- State persistence
- Pareto frontier analysis
- Result visualization

**Interactive features:**
- Adjustable parameters (iterations, batch size, seed)
- LLM provider selection with Kino inputs
- Data tables for results
- Score progression charts
- Pareto frontier visualization

### 3. Custom Adapter (`03_custom_adapter.livemd`)
**Perfect for:** Advanced users building their own adapters
**Duration:** 20-30 minutes
**Prerequisites:** Understanding of GEPA adapters

**What you'll learn:**
- Implementing GEPA.Adapter behavior
- Custom evaluation logic
- Component feedback extraction
- Common adapter patterns

**Interactive features:**
- Complete working example (sentiment classification)
- Modifiable adapter code
- Pattern templates for common use cases
- Step-by-step customization guide

## How to Use Livebooks

### Option 1: Livebook Desktop App

1. Install Livebook: https://livebook.dev/
2. Open Livebook
3. Navigate to `gepa_ex/livebooks/`
4. Click on any `.livemd` file
5. Click "Run all cells"

### Option 2: Local Livebook Server

```bash
# Install Livebook
mix escript.install hex livebook

# Start server
livebook server

# Open in browser (usually http://localhost:8080)
# Navigate to gepa_ex/livebooks/
```

### Option 3: From Project

```bash
# From gepa_ex directory
cd gepa_ex

# Start Livebook
livebook server livebooks/01_quick_start.livemd
```

## Requirements

### All Livebooks
- Elixir 1.14+
- gepa_ex project (installed automatically by Mix.install)

### For Real LLM Usage
- OpenAI API key (set OPENAI_API_KEY environment variable)
  OR
- Gemini API key (set GEMINI_API_KEY environment variable)

### For Interactive Features (Advanced/Custom notebooks)
- Kino library (installed automatically)

## Livebook Features Demonstrated

### Data Visualization
```elixir
# Tables
Kino.DataTable.new(results)

# Markdown
Kino.Markdown.new("# Results")

# Layouts
Kino.Layout.grid([...])
```

### User Inputs
```elixir
# Select boxes
provider = Kino.Input.select("Provider", options)

# Numbers
iterations = Kino.Input.number("Iterations", default: 20)

# Read values
Kino.Input.read(provider)
```

### Interactive Exploration
- Modify parameters and re-run cells
- See results update in real-time
- Experiment without writing code files

## Learning Path

### Beginner
1. Start with `01_quick_start.livemd`
2. Run with mock LLM
3. Understand basic concepts
4. Try with real LLM (optional)

### Intermediate
1. Open `02_advanced_optimization.livemd`
2. Experiment with parameters
3. Understand batch sampling
4. Visualize Pareto frontier

### Advanced
1. Study `03_custom_adapter.livemd`
2. Modify the adapter for your domain
3. Create your own dataset
4. Build production adapter

## Tips & Tricks

### Running Cells
- `Ctrl+Enter` or `Cmd+Enter`: Run current cell
- `Shift+Enter`: Run cell and move to next
- `Alt+Enter`: Run all cells

### Modifying Code
- Click "Edit" on any code cell
- Make changes
- Re-run to see results

### Saving Work
- Livebooks auto-save
- Output is preserved
- Can export to markdown or Elixir script

### Sharing Results
- Export to .livemd file
- Share via GitHub
- Include in documentation
- Present in meetings!

## Common Issues

### "Module GEPA not found"

Make sure the Mix.install path is correct:
```elixir
Mix.install([
  {:gepa_ex, path: Path.join(__DIR__, "..")}
])
```

### Mock LLM gives unexpected results

This is expected! Mock LLM is for testing. For real optimization:
1. Set OPENAI_API_KEY or GEMINI_API_KEY
2. Change provider to :openai or :gemini
3. Re-run cells

### Slow execution with real LLM

This is normal! LLM API calls take time:
- Reduce max_metric_calls
- Use smaller trainset
- Be patient (2-5 minutes typical)

### Kino visualizations not showing

Make sure Kino is installed:
```elixir
Mix.install([
  {:kino, "~> 0.14.0"}
])
```

## Examples vs Livebooks

### When to use Examples (.exs files)
- Quick scripts
- CI/CD integration
- Automated testing
- Batch processing

### When to use Livebooks (.livemd files)
- Learning and exploration
- Interactive development
- Parameter tuning
- Presentations and demos
- Teaching others

**Both are valuable!** Use examples for automation, Livebooks for exploration.

## Contributing Livebooks

Want to add more Livebooks? Great!

### Guidelines
1. Start with clear learning objective
2. Include step-by-step explanations
3. Use interactive inputs (Kino)
4. Provide visualizations
5. Add "Next Steps" section
6. Test thoroughly

### Good Topics
- RAG optimization (when adapter available)
- Multi-turn conversations
- Code generation
- Domain-specific tasks
- Performance benchmarking
- Comparing strategies

### Submit
1. Create livebook in this directory
2. Follow naming: `NN_description.livemd`
3. Update this README
4. Submit PR

## Resources

- **Livebook Docs**: https://livebook.dev/
- **Kino Docs**: https://hexdocs.pm/kino/
- **GEPA Docs**: ../docs/
- **Examples**: ../examples/

## Next Steps

1. Open `01_quick_start.livemd` and run all cells
2. Experiment with parameters in `02_advanced_optimization.livemd`
3. Build your own adapter with `03_custom_adapter.livemd`
4. Create your own livebook for your use case!

Happy exploring! 🚀
