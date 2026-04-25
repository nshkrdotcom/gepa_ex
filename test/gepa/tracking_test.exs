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
        max_metric_calls: 1,
        tracker: tracker
      )

    snapshot = InMemory.snapshot(tracker)
    assert snapshot.summaries != []
  end
end
