defmodule GEPA.Tracking.ExperimentTrackerUpstreamParityTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Adapters.Basic
  alias GEPA.OptimizeAnything
  alias GEPA.OptimizeAnything.TrackingConfig
  alias GEPA.Tracking
  alias GEPA.Tracking.ExperimentTracker

  describe "attach-existing lifecycle" do
    test "wandb-style attach skips local lifecycle but still logs metrics" do
      tracker =
        Tracking.create_experiment_tracker(use_wandb: true, wandb_attach_existing: true)

      assert :ok = Tracking.start(tracker)
      assert :ok = Tracking.log_metrics(tracker, %{score: 0.8}, step: 1)
      assert :ok = Tracking.finish(tracker)

      snapshot = ExperimentTracker.snapshot(tracker)
      assert snapshot.attached?
      assert snapshot.start_count == 0
      assert snapshot.finish_count == 0
      assert [%{step: 1, metrics: %{"score" => 0.8}}] = snapshot.metrics
    end

    test "mlflow-style attach skips local lifecycle but still logs metrics" do
      tracker =
        Tracking.create_experiment_tracker(use_mlflow: true, mlflow_attach_existing: true)

      assert :ok = Tracking.start(tracker)
      assert :ok = Tracking.log_metrics(tracker, %{val_score: 0.9}, step: 2)
      assert :ok = Tracking.finish(tracker)

      snapshot = ExperimentTracker.snapshot(tracker)
      assert snapshot.attached?
      assert snapshot.start_count == 0
      assert snapshot.finish_count == 0
      assert [%{step: 2, metrics: %{"val_score" => 0.9}}] = snapshot.metrics
    end

    test "normal mode records lifecycle start and finish" do
      tracker = Tracking.create_experiment_tracker(use_wandb: true)

      assert :ok = Tracking.start(tracker)
      assert :ok = Tracking.finish(tracker)

      snapshot = ExperimentTracker.snapshot(tracker)
      assert snapshot.started?
      assert snapshot.finished?
      assert snapshot.start_count == 1
      assert snapshot.finish_count == 1
    end
  end

  describe "factory and config wiring" do
    test "factory preserves attach-existing defaults and flags" do
      default = Tracking.create_experiment_tracker()
      assert default.wandb_attach_existing == false
      assert default.mlflow_attach_existing == false

      wandb =
        Tracking.create_experiment_tracker(use_wandb: true, wandb_attach_existing: true)

      mlflow =
        Tracking.create_experiment_tracker(use_mlflow: true, mlflow_attach_existing: true)

      assert wandb.wandb_attach_existing
      assert mlflow.mlflow_attach_existing
    end

    test "tracking config exposes upstream-style attach fields" do
      assert %TrackingConfig{wandb_attach_existing: false, mlflow_attach_existing: false} =
               TrackingConfig.new()

      config =
        TrackingConfig.new(
          use_wandb: true,
          wandb_attach_existing: true,
          use_mlflow: true,
          mlflow_attach_existing: true
        )

      assert config.wandb_attach_existing
      assert config.mlflow_attach_existing
    end

    test "optimize_anything uses a tracker supplied by tracking config" do
      tracker = ExperimentTracker.new(key_prefix: "oa/")

      {:ok, _result} =
        OptimizeAnything.optimize_anything(
          seed_candidate: "x",
          evaluator: fn _candidate -> 0.5 end,
          engine: %{max_metric_calls: 1},
          reflection: %{custom_candidate_proposer: passthrough_proposer()},
          tracking: %{tracker: tracker}
        )

      snapshot = ExperimentTracker.snapshot(tracker)
      assert snapshot.summary["oa/best_score"] == 0.5
    end

    test "flat optimize API builds a dependency-free tracker from upstream-style flags" do
      test_pid = self()

      callback = fn
        :optimization_start, %{config: %{tracker: tracker}} ->
          send(test_pid, {:tracker, tracker})

        _event, _payload ->
          :ok
      end

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "seed"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          custom_candidate_proposer: passthrough_proposer(),
          max_metric_calls: 1,
          callbacks: [callback],
          use_wandb: true,
          wandb_attach_existing: true
        )

      assert_receive {:tracker, %ExperimentTracker{} = tracker}
      assert tracker.use_wandb
      assert tracker.wandb_attach_existing
    end
  end

  describe "key prefix" do
    test "prefixes metrics tables html summary and config keys" do
      tracker = ExperimentTracker.new(key_prefix: "gepa/")

      assert :ok = ExperimentTracker.log_metrics(tracker, %{val_score: 0.8}, step: 1)
      assert :ok = ExperimentTracker.log_table(tracker, "candidates", [["v0"]])
      assert :ok = ExperimentTracker.log_html(tracker, "<html/>", "candidate_tree")
      assert :ok = ExperimentTracker.log_summary(tracker, %{best_score: 0.9})
      assert :ok = ExperimentTracker.log_config(tracker, %{model: "gpt-test"})

      snapshot = ExperimentTracker.snapshot(tracker)
      assert [%{metrics: %{"gepa/val_score" => 0.8}}] = snapshot.metrics
      assert Map.has_key?(snapshot.tables, "gepa/candidates")
      assert snapshot.html["gepa/candidate_tree"] == "<html/>"
      assert snapshot.summary["gepa/best_score"] == 0.9
      assert snapshot.config["gepa/model"] == "gpt-test"
    end

    test "empty prefix leaves metric keys unchanged" do
      tracker = ExperimentTracker.new(key_prefix: "")

      assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 1.0}, step: 1)

      assert [%{metrics: %{"score" => 1.0}}] = ExperimentTracker.snapshot(tracker).metrics
    end
  end

  describe "wandb step metric" do
    test "defines the step metric lazily only once and injects step as a metric value" do
      tracker = ExperimentTracker.new(use_wandb: true, wandb_step_metric: "gepa/iteration")

      assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 0.5}, step: 1)
      assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 0.6}, step: 2)

      snapshot = ExperimentTracker.snapshot(tracker)
      assert snapshot.defined_metrics == ["gepa/iteration", "*"]

      assert [
               %{step: nil, metrics: %{"gepa/iteration" => 1, "score" => 0.5}},
               %{step: nil, metrics: %{"gepa/iteration" => 2, "score" => 0.6}}
             ] = snapshot.metrics
    end

    test "without a step metric it stores the global step separately" do
      tracker = ExperimentTracker.new(use_wandb: true)

      assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 0.5}, step: 3)

      assert [%{step: 3, metrics: %{"score" => 0.5}}] =
               ExperimentTracker.snapshot(tracker).metrics
    end

    test "step metric works with key prefix and nil step is not injected" do
      tracker =
        ExperimentTracker.new(
          use_wandb: true,
          wandb_step_metric: "gepa/iteration",
          key_prefix: "round1/"
        )

      assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 0.5}, step: 2)
      assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 0.6}, step: nil)

      assert [
               %{metrics: %{"gepa/iteration" => 2, "round1/score" => 0.5}},
               %{metrics: %{"round1/score" => 0.6}}
             ] = ExperimentTracker.snapshot(tracker).metrics
    end

    test "factory passes wandb_step_metric through" do
      tracker =
        Tracking.create_experiment_tracker(use_wandb: true, wandb_step_metric: "gepa/step")

      assert tracker.wandb_step_metric == "gepa/step"
    end
  end

  defp passthrough_proposer do
    fn candidate, _dataset, components ->
      Map.new(components, &{&1, Map.fetch!(candidate, &1)})
    end
  end
end
