defmodule GEPA.ResultTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.{EvaluationBatch, Result, State}

  describe "from_state/1" do
    test "exposes upstream metadata fields" do
      state =
        State.new(
          %{"instruction" => "seed"},
          %EvaluationBatch{
            outputs: ["seed-a"],
            scores: [0.7],
            objective_scores: [%{"accuracy" => 0.7}],
            num_metric_calls: 2
          },
          [0],
          track_best_outputs: true
        )

      {state, _idx} =
        State.add_program(
          state,
          %{"instruction" => "new"},
          [0],
          %{0 => 0.9},
          outputs_by_val_id: %{0 => "new-a"},
          objective_scores_by_val_id: %{0 => %{"accuracy" => 0.9}},
          metric_calls: 1
        )

      result = Result.from_state(state)

      assert result.best_outputs_valset == %{0 => [{1, "new-a"}]}
      assert result.val_aggregate_subscores == [%{"accuracy" => 0.7}, %{"accuracy" => 0.9}]
      assert result.objective_pareto_front == %{"accuracy" => 0.9}
      assert result.per_objective_best_candidates == %{"accuracy" => MapSet.new([1])}
      assert result.discovery_eval_counts == [0, 2]
    end
  end

  describe "to_dict/1 and from_dict/1" do
    test "from_dict upcasts legacy version 0 list-shaped fields" do
      legacy_payload = %{
        "candidates" => [%{"system_prompt" => "weight=0"}, %{"system_prompt" => "weight=1"}],
        "parents" => [[nil], [0]],
        "val_aggregate_scores" => [0.15, 0.35],
        "val_subscores" => [[0.1, 0.2], [0.3, 0.4]],
        "per_val_instance_best_candidates" => [[0], [1]],
        "discovery_eval_counts" => [0, 2],
        "best_outputs_valset" => [
          [{0, %{"value" => 0.1}}],
          [{1, %{"value" => 0.4}}]
        ],
        "total_metric_calls" => 5,
        "num_full_val_evals" => 2,
        "run_dir" => "/tmp/gepa",
        "seed" => 42
      }

      result = Result.from_dict(legacy_payload)

      assert result.val_subscores == [%{0 => 0.1, 1 => 0.2}, %{0 => 0.3, 1 => 0.4}]

      assert result.per_val_instance_best_candidates == %{
               0 => MapSet.new([0]),
               1 => MapSet.new([1])
             }

      assert result.best_outputs_valset == %{
               0 => [{0, %{"value" => 0.1}}],
               1 => [{1, %{"value" => 0.4}}]
             }

      serialized = Result.to_dict(result)
      assert serialized["validation_schema_version"] == 2
    end

    test "round-trips result metadata" do
      result = %Result{
        candidates: [%{"instruction" => "seed"}, %{"instruction" => "new"}],
        val_aggregate_scores: [0.7, 0.9],
        val_subscores: [%{0 => 0.7}, %{0 => 0.9}],
        per_val_instance_best_candidates: %{0 => MapSet.new([1])},
        parents: [[nil], [0]],
        total_num_evals: 3,
        num_full_ds_evals: 1,
        i: 1,
        discovery_eval_counts: [3],
        best_outputs_valset: %{0 => [{1, "new-a"}]},
        val_aggregate_subscores: [%{"accuracy" => 0.7}, %{"accuracy" => 0.9}],
        per_objective_best_candidates: %{"accuracy" => MapSet.new([1])},
        objective_pareto_front: %{"accuracy" => 0.9}
      }

      round_trip =
        result
        |> Result.to_dict()
        |> Result.from_dict()

      assert round_trip == result
    end
  end
end
