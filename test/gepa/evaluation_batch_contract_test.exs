defmodule GEPA.EvaluationBatchContractTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapter.Dispatch
  alias GEPA.EvaluationBatch

  defmodule TupleAdapter do
    def evaluate(batch, _candidate, _capture_traces) do
      {Enum.map(batch, &{:ok, &1}), Enum.map(batch, fn _ -> 1 end)}
    end
  end

  defmodule BadLengthAdapter do
    def evaluate(_batch, _candidate, _capture_traces) do
      {[:only_output], [1.0, 0.0]}
    end
  end

  test "capture_traces requires aligned trajectories" do
    batch = %EvaluationBatch{outputs: [:o], scores: [1.0]}

    assert {:error, :trajectories_required_when_capture_traces} =
             EvaluationBatch.validate(batch, capture_traces: true)
  end

  test "objective scores must align with outputs and contain numeric values" do
    assert {:error, {:invalid_evaluation_batch_length, :objective_scores, 2, 1}} =
             EvaluationBatch.validate(%EvaluationBatch{
               outputs: [:o],
               scores: [1.0],
               objective_scores: [%{"accuracy" => 1.0}, %{"accuracy" => 0.0}]
             })

    assert {:error, :objective_scores_must_be_maps_of_numeric_values} =
             EvaluationBatch.validate(%EvaluationBatch{
               outputs: [:o],
               scores: [1.0],
               objective_scores: [%{"accuracy" => "yes"}]
             })
  end

  test "dispatch normalizes official tuple results and rejects malformed batches" do
    assert {:ok, %EvaluationBatch{outputs: [ok: %{id: 1}], scores: [1.0]}} =
             Dispatch.evaluate(TupleAdapter, [%{id: 1}], %{"p" => "x"}, false)

    assert {:error, {:invalid_evaluation_batch_length, :scores, 2, 1}} =
             Dispatch.evaluate(BadLengthAdapter, [%{id: 1}], %{"p" => "x"}, false)
  end
end
