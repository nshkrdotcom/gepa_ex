defmodule GEPA.TrackingTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Adapters.Basic
  alias GEPA.Tracking.InMemory

  test "in-memory tracker records metrics, tables, and summaries with key prefix" do
    tracker = InMemory.new(key_prefix: "run")

    GEPA.Tracking.log_metrics(tracker, %{score: 0.5}, step: 1)
    GEPA.Tracking.log_table(tracker, "examples", [%{id: 1}], [])
    GEPA.Tracking.log_summary(tracker, %{best: 0.7})

    snapshot = InMemory.snapshot(tracker)

    assert [%{metrics: %{"run.score" => 0.5}, opts: [step: 1]}] = snapshot.metrics
    assert [%{name: "run.examples", rows: [%{id: 1}]}] = snapshot.tables
    assert [%{"run.best" => 0.7}] = snapshot.summaries
  end

  test "engine writes tracker metrics and summary" do
    tracker = InMemory.new()

    {:ok, _result} =
      GEPA.optimize(
        seed_candidate: %{"instruction" => "seed"},
        trainset: [%{input: "Q", answer: "A"}],
        valset: [%{input: "Q2", answer: "A2"}],
        adapter: Basic.new(),
        custom_candidate_proposer: custom_candidate_proposer(),
        max_metric_calls: 1,
        tracker: tracker
      )

    snapshot = InMemory.snapshot(tracker)
    assert snapshot.summaries != []
  end

  test "external tracker stubs fail explicitly when not configured" do
    wandb = GEPA.Tracking.WandB.new()
    mlflow = GEPA.Tracking.MLflow.new()

    assert {:error, {:not_configured, :wandb}} = GEPA.Tracking.WandB.start(wandb)
    assert {:error, {:not_configured, :mlflow}} = GEPA.Tracking.MLflow.start(mlflow)
    refute GEPA.Tracking.WandB.configured?(wandb)
    refute GEPA.Tracking.MLflow.configured?(mlflow)
  end

  test "external tracker stubs do not crash optimizer dispatch" do
    tracker = GEPA.Tracking.WandB.new()

    assert :ok = GEPA.Tracking.start(tracker)
    assert :ok = GEPA.Tracking.log_metrics(tracker, %{score: 1.0})
    assert :ok = GEPA.Tracking.finish(tracker)
  end

  defp custom_candidate_proposer do
    fn candidate, _reflective_dataset, components ->
      Map.new(components, fn component ->
        {component, Map.get(candidate, component, "") <> " updated"}
      end)
    end
  end
end
