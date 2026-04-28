# Component Selection

Component selection decides which candidate text fields are eligible for a proposal.

Candidates are maps:

```elixir
%{
  "system_prompt" => "Classify the message.",
  "retrieval_prompt" => "Find relevant documents.",
  "answer_prompt" => "Answer from context."
}
```

The component selector returns keys from that map.

## Round Robin

`GEPA.Strategies.ComponentSelector.RoundRobin` cycles through component names. Use it when components should receive balanced attention.

```elixir
selector = GEPA.Strategies.ComponentSelector.RoundRobin.new()
```

## All Components

`GEPA.Strategies.ComponentSelector.All` updates every component each time. Use it when components are tightly coupled or the reflection prompt should reason over the whole candidate.

```elixir
selector = GEPA.Strategies.ComponentSelector.All
```

## Naming

Use stable, descriptive component names. Reflection records and result maps use these names directly, so changing them mid-project makes traces harder to compare.

Good component names:

- `"instruction"`
- `"system_prompt"`
- `"retrieval_prompt"`
- `"answer_prompt"`
- `"grading_rubric"`

Avoid names that encode runtime details such as provider, model, or version. Put those in config instead.
