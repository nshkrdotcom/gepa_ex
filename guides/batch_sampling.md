# Batch Sampling

Batch samplers choose the training examples used for each reflective proposal.

## Simple Sampler

`GEPA.Strategies.BatchSampler.Simple` takes examples in straightforward slices. It is useful for deterministic smoke tests and simple runs.

## Epoch-Shuffled Sampler

`GEPA.Strategies.BatchSampler.EpochShuffled` shuffles the dataset by epoch and advances through minibatches. It is the better default for longer runs because every item gets coverage before the next epoch reshuffle.

```elixir
sampler = GEPA.Strategies.BatchSampler.EpochShuffled.new(seed: 42)

GEPA.optimize(
  seed_candidate: seed,
  trainset: train,
  valset: val,
  adapter: adapter,
  batch_sampler: sampler,
  reflection_minibatch_size: 4,
  max_metric_calls: 100
)
```

## Batch Size

`reflection_minibatch_size` is the number of training examples used to build each reflective dataset. Larger batches give richer feedback and cost more metric calls. Smaller batches increase iteration speed but can make proposals noisy.

## Data Loaders

`GEPA.DataLoader` can wrap a list or custom loading behavior. Use it when the training set may grow, stream, or resume from external state. Dynamic validation is supported as long as data IDs remain stable enough to compare scores across runs.
