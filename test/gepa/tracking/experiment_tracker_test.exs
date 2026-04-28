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

  describe "upstream log_table parity" do
    test "log_table wandb" do
      tracker = ExperimentTracker.new(use_wandb: true)
      columns = ["name", "score"]
      data = [["alice", 0.9], ["bob", 0.8]]

      assert :ok = ExperimentTracker.log_table(tracker, "test_table", data, columns: columns)

      assert %{columns: ^columns, rows: ^data} =
               ExperimentTracker.snapshot(tracker).tables["test_table"]
    end

    test "log_table mlflow" do
      tracker = ExperimentTracker.new(use_mlflow: true)
      columns = ["name", "score"]
      data = [["alice", 0.9], ["bob", 0.8]]

      assert :ok = ExperimentTracker.log_table(tracker, "test_table", data, columns: columns)

      table = ExperimentTracker.snapshot(tracker).tables["test_table"]
      assert table_to_columns(table) == %{"name" => ["alice", "bob"], "score" => [0.9, 0.8]}
    end

    test "log_table no backends" do
      tracker = ExperimentTracker.new(use_wandb: false, use_mlflow: false)

      assert :ok = ExperimentTracker.log_table(tracker, "test", [[1]], columns: ["a"])
      assert ExperimentTracker.snapshot(tracker).tables["test"].rows == [[1]]
    end

    test "log_table wandb error handled by dependency-free backend" do
      tracker = ExperimentTracker.new(use_wandb: true)
      assert :ok = ExperimentTracker.log_table(tracker, "test", [[1]], columns: ["a"])
    end

    test "log_table mlflow error handled by dependency-free backend" do
      tracker = ExperimentTracker.new(use_mlflow: true)
      assert :ok = ExperimentTracker.log_table(tracker, "test", [[1]], columns: ["a"])
    end
  end

  describe "upstream log_metrics numeric filtering parity" do
    test "wandb filters strings" do
      tracker = ExperimentTracker.new(use_wandb: true)

      assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 0.9, name: "test", count: 5})

      assert [%{metrics: metrics}] = ExperimentTracker.snapshot(tracker).metrics
      assert metrics == %{"score" => 0.9, "count" => 5}
    end

    test "mlflow filters strings" do
      tracker = ExperimentTracker.new(use_mlflow: true)

      assert :ok = ExperimentTracker.log_metrics(tracker, %{score: 0.9, label: "test", count: 5})

      assert [%{metrics: metrics}] = ExperimentTracker.snapshot(tracker).metrics
      assert metrics == %{"score" => 0.9, "count" => 5}
    end
  end

  describe "upstream log_config parity" do
    test "wandb config update" do
      tracker = ExperimentTracker.new(use_wandb: true)
      config = %{seed: 42, lr: 0.01, name: "test"}

      assert :ok = ExperimentTracker.log_config(tracker, config)

      assert ExperimentTracker.snapshot(tracker).config == %{
               "seed" => 42,
               "lr" => 0.01,
               "name" => "test"
             }
    end

    test "non serializable values stringified" do
      tracker = ExperimentTracker.new(use_wandb: true)

      assert :ok =
               ExperimentTracker.log_config(tracker, %{
                 seed: 42,
                 components: ["a", "b"],
                 obj: make_ref()
               })

      logged = ExperimentTracker.snapshot(tracker).config
      assert logged["seed"] == 42
      assert is_binary(logged["components"])
      assert is_binary(logged["obj"])
    end

    test "mlflow params as strings" do
      tracker = ExperimentTracker.new(use_mlflow: true)

      assert :ok = ExperimentTracker.log_config(tracker, %{seed: 42, lr: 0.01, name: "test"})

      logged = ExperimentTracker.snapshot(tracker).config
      assert Enum.all?(logged, fn {_key, value} -> is_binary(value) end)
      assert logged["seed"] == "42"
    end

    test "log_config no backends no error" do
      tracker = ExperimentTracker.new(use_wandb: false, use_mlflow: false)
      assert :ok = ExperimentTracker.log_config(tracker, %{key: "value"})
    end

    test "log_config wandb error handled by dependency-free backend" do
      tracker = ExperimentTracker.new(use_wandb: true)
      assert :ok = ExperimentTracker.log_config(tracker, %{key: "value"})
    end
  end

  describe "upstream log_summary parity" do
    test "wandb summary set" do
      tracker = ExperimentTracker.new(use_wandb: true)

      assert :ok =
               ExperimentTracker.log_summary(tracker, %{
                 best_score: 0.95,
                 best_idx: 3,
                 best_prompt: "Do X"
               })

      assert ExperimentTracker.snapshot(tracker).summary == %{
               "best_score" => 0.95,
               "best_idx" => 3,
               "best_prompt" => "Do X"
             }
    end

    test "mlflow splits numeric and text" do
      tracker = ExperimentTracker.new(use_mlflow: true)

      assert :ok =
               ExperimentTracker.log_summary(tracker, %{
                 best_score: 0.95,
                 best_prompt: "Do X",
                 count: 10
               })

      snapshot = ExperimentTracker.snapshot(tracker)
      assert snapshot.summary_metrics == %{"best_score" => 0.95, "count" => 10}
      assert snapshot.summary_params == %{"summary/best_prompt" => "Do X"}
    end

    test "log_summary no backends no error" do
      tracker = ExperimentTracker.new(use_wandb: false, use_mlflow: false)
      assert :ok = ExperimentTracker.log_summary(tracker, %{key: "value"})
    end

    test "log_summary wandb error handled by dependency-free backend" do
      tracker = ExperimentTracker.new(use_wandb: true)
      assert :ok = ExperimentTracker.log_summary(tracker, %{key: "value"})
    end
  end

  defp table_to_columns(%{columns: columns, rows: rows}) do
    columns
    |> Enum.with_index()
    |> Map.new(fn {column, index} ->
      {column, Enum.map(rows, &Enum.at(&1, index))}
    end)
  end
end
