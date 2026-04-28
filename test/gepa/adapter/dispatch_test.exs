defmodule GEPA.Adapter.DispatchTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapter.Dispatch
  alias GEPA.EvaluationBatch

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

  defmodule FunctionStructAdapter do
    defstruct [:evaluate, :make_reflective_dataset, :propose_new_texts]
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

  test "dispatch falls back to function fields on struct adapters" do
    adapter = %FunctionStructAdapter{
      evaluate: fn _adapter, batch, _candidate, capture_traces ->
        %EvaluationBatch{
          outputs: batch,
          scores: Enum.map(batch, fn _ -> 1.0 end),
          trajectories: if(capture_traces, do: [:trace])
        }
      end,
      make_reflective_dataset: fn _adapter, _candidate, eval_batch, components ->
        Map.new(components, &{&1, eval_batch.trajectories})
      end,
      propose_new_texts: fn _adapter, candidate, _reflective_dataset, components ->
        Map.take(candidate, components)
      end
    }

    assert Dispatch.has_propose_new_texts?(adapter)

    assert {:ok, eval_batch} =
             Dispatch.evaluate(adapter, [%{id: 1}], %{"p" => "x"}, true)

    assert eval_batch.trajectories == [:trace]

    assert {:ok, %{"p" => [:trace]}} =
             Dispatch.make_reflective_dataset(adapter, %{"p" => "x"}, eval_batch, ["p"])

    assert {:ok, %{"p" => "x"}, %{}, %{}} =
             Dispatch.propose_new_texts(adapter, %{"p" => "x", "q" => "y"}, %{}, ["p"])
  end
end
