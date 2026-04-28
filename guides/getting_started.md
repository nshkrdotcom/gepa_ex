# Getting Started

GEPA is a search loop for text-based system components. You provide:

- a seed candidate, usually a map of component names to text
- training and validation data
- an adapter that knows how to evaluate the candidate

The simplest way to get moving is with the shipped Q&A task adapter and a hosted LLM client.

```elixir
llm = GEPA.LLM.req_llm(:openai)
adapter = GEPA.Adapters.Basic.new(llm: llm)

{:ok, result} =
  GEPA.optimize(
    seed_candidate: %{"instruction" => "Answer exactly."},
    trainset: [
      %{input: "What is 2+2?", answer: "4"},
      %{input: "What is 3+3?", answer: "6"}
    ],
    valset: [
      %{input: "What is 5+5?", answer: "10"}
    ],
    adapter: adapter,
    max_metric_calls: 20
  )

IO.inspect(GEPA.Result.best_candidate(result))
```

If you do not want to write a custom adapter yet, use `GEPA.Adapters.Default`. It takes a task model callable and an optional evaluator, so you can optimize a single prompt before you move to a richer integration.

## Choosing A Backend

Hosted providers use `GEPA.LLM.req_llm/2`:

```elixir
GEPA.LLM.req_llm(:openai)
GEPA.LLM.req_llm(:gemini)
GEPA.LLM.req_llm(:anthropic)
```

Local CLI-backed providers use `GEPA.LLM.agent/2`:

```elixir
GEPA.LLM.agent(:codex, lane: :core, session: "gepa-run")
GEPA.LLM.agent(:claude, lane: :auto)
```

Those are LLM adapters. They are separate from task adapters such as `GEPA.Adapters.Basic`, `GEPA.Adapters.Default`, or your own `GEPA.Adapter` implementation.

## Installation

Add the package to `mix.exs`:

```elixir
def deps do
  [
    {:gepa_ex, "~> 0.3.0"}
  ]
end
```

GEPA targets Elixir 1.15+ and uses the normal Mix workflow.

## What Happens Next

`GEPA.optimize/1` will:

1. evaluate the seed candidate
2. select a candidate to mutate
3. sample a minibatch
4. build a reflective dataset
5. propose a new candidate
6. accept or reject the proposal
7. repeat until a stop condition fires

If you want the option surface before reading the rest of the guides, go to [Core API](core_api.md). If you want the complete provider and adapter matrix, go to [LLM and Adapters](llm_and_adapters.md).
