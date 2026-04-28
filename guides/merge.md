# Merge

`GEPA.Proposer.Merge` combines related candidate lineages. It is useful when two descendants improved different validation slices and share a common ancestor.

## What Merge Does

The merge proposer:

1. finds viable candidate triplets with a common ancestor
2. checks overlap and support gates
3. builds a merge prompt from ancestor and descendant text
4. asks the configured reflection LLM for a combined candidate
5. records the triplet so it is not merged repeatedly

## Configuration

Merge is controlled by optimizer options and the merge proposer state. Use it when your task has multiple components or validation slices where separate candidates can specialize.

```elixir
GEPA.optimize(
  seed_candidate: seed,
  trainset: train,
  valset: val,
  adapter: adapter,
  reflection_llm: GEPA.LLM.req_llm(:gemini),
  merge: true,
  max_metric_calls: 100
)
```

## Validation Support

Merge is gated by validation support. A pair must have enough non-overlapping or complementary support to justify a merge. This avoids burning reflection calls on nearly identical descendants.

## When To Avoid Merge

Avoid merge for very small runs, single-component tasks with tiny validation sets, or when every proposal should be easy to attribute to one previous parent. Merge adds useful search power but also increases lineage complexity.
