defmodule GEPA.Adapter.DispatchTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapter.Dispatch

  defmodule OfficialStyleAdapter do
    def evaluate(batch, _candidate, capture_traces) do
      %GEPA.EvaluationBatch{
        outputs: batch,
        scores: Enum.map(batch, fn _ -> 1.0 end),
        trajectories: if(capture_traces, do: batch)
      }
    end

    def make_reflective_dataset(_candidate, eval_batch, components) do
      Map.new(
        components,
        &{&1, Enum.map(eval_batch.outputs, fn output -> %{"Output" => output} end)}
      )
    end
  end

  test "dispatch supports official-style evaluate/3 adapters" do
    assert {:ok, eval_batch} =
             Dispatch.evaluate(OfficialStyleAdapter, [%{id: 1}], %{"p" => "x"}, true)

    assert eval_batch.scores == [1.0]

    assert {:ok, dataset} =
             Dispatch.make_reflective_dataset(OfficialStyleAdapter, %{"p" => "x"}, eval_batch, [
               "p"
             ])

    assert [%{"Output" => %{id: 1}}] = dataset["p"]
  end
end
