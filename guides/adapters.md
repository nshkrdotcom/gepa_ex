# Adapters

GEPA has two adapter layers.

- `GEPA.LLM` adapters call model providers.
- `GEPA.Adapter` task adapters evaluate candidates and build feedback for reflection.

Keep those layers separate. A task adapter may call an LLM, a vector store, a database, or a tool, but the optimizer only depends on the `GEPA.Adapter` behavior.

## Task Adapter Contract

A task adapter implements:

```elixir
@callback evaluate(adapter, batch, candidate, capture_traces) ::
            {:ok, GEPA.EvaluationBatch.t()} | {:error, term()}

@callback make_reflective_dataset(adapter, candidate, eval_batch, components) ::
            {:ok, map()} | {:error, term()}
```

Optional callbacks support adapter-owned proposals and persistence:

- `propose_new_texts/3`
- `propose_new_texts/4`
- `get_adapter_state/1`
- `set_adapter_state/2`

Use adapter state for external cursor state, conversation state, or task-local caches that must survive `run_dir` resume.

## Evaluation Batch

`evaluate/4` returns a `GEPA.EvaluationBatch` with aligned lists:

- `outputs`
- `scores`
- `objective_scores`
- `trajectories`
- `num_metric_calls`

Set `trajectories` when `capture_traces` is true. Reflection depends on those traces.

## Shipped Task Adapters

- `GEPA.Adapters.Basic` handles common question/answer scoring.
- `GEPA.Adapters.Default` handles prompt-plus-callable tasks.
- `GEPA.Adapters.Confidence` handles structured classification with optional logprob-aware scoring.
- `GEPA.Adapters.GenericRAG` handles retrieval plus generation over a vector store.

`GEPA.Adapter.Dispatch` normalizes module, struct, and legacy callback forms. New code should implement the behavior directly.

## Custom Adapter Pattern

```elixir
defmodule MyAdapter do
  @behaviour GEPA.Adapter

  @impl true
  def evaluate(_adapter, batch, candidate, capture_traces) do
    instruction = Map.fetch!(candidate, "instruction")

    rows =
      Enum.map(batch, fn example ->
        prediction = run_task(instruction, example)
        score = if prediction == example.answer, do: 1.0, else: 0.0

        %{
          output: prediction,
          score: score,
          trace: %{input: example.input, output: prediction, expected: example.answer}
        }
      end)

    {:ok,
     %GEPA.EvaluationBatch{
       outputs: Enum.map(rows, & &1.output),
       scores: Enum.map(rows, & &1.score),
       trajectories: if(capture_traces, do: Enum.map(rows, & &1.trace)),
       num_metric_calls: length(batch)
     }}
  end

  @impl true
  def make_reflective_dataset(_adapter, _candidate, eval_batch, components) do
    rows =
      Enum.map(eval_batch.trajectories || [], fn trace ->
        %{
          "Inputs" => %{input: trace.input},
          "Generated Outputs" => trace.output,
          "Feedback" => "Expected #{inspect(trace.expected)}"
        }
      end)

    {:ok, Map.new(components, &{&1, rows})}
  end

  defp run_task(_instruction, example), do: example.answer
end
```

Tests may use deterministic helpers. Public examples must use real providers.
