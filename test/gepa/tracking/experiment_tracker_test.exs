defmodule GEPA.Tracking.ExperimentTrackerTest do
  use ExUnit.Case, async: true

  alias GEPA.Tracking.ExperimentTracker

  test "stores metrics tables config and summary with key prefix" do
    tracker = ExperimentTracker.new(key_prefix: "gepa/")

    assert :ok = ExperimentTracker.start(tracker)
    assert :ok = ExperimentTracker.log_config(tracker, %{model: "m"})
    assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 0.5}, step: 1)

    assert :ok =
             ExperimentTracker.log_table(tracker, "scores", [[1, 0.5]], columns: ["id", "score"])

    assert :ok = ExperimentTracker.log_summary(tracker, %{best: 0.5})

    snapshot = ExperimentTracker.snapshot(tracker)
    assert snapshot.started?
    assert snapshot.config["gepa/model"] == "m"
    assert [%{step: 1, metrics: %{"gepa/score" => 0.5}}] = snapshot.metrics
    assert snapshot.summary["gepa/best"] == 0.5
    assert snapshot.tables["gepa/scores"].rows == [[1, 0.5]]
  end
end
