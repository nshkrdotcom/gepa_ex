defmodule GEPA.OptimizeAnythingTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.LLM.Mock
  alias GEPA.OptimizeAnything

  alias GEPA.OptimizeAnything.{
    Config,
    EngineConfig,
    EvaluatorWrapper,
    OptimizationState,
    ReflectionConfig
  }

  test "config structs normalize nested maps" do
    config =
      Config.new(
        seed_candidate: "seed",
        evaluator: fn _candidate -> 1.0 end,
        engine: %{max_metric_calls: 3},
        reflection: %{skip_perfect_score: false}
      )

    assert %EngineConfig{max_metric_calls: 3} = config.engine
    assert %ReflectionConfig{skip_perfect_score: false} = config.reflection
  end

  test "process-local logs are captured by evaluator wrapper" do
    evaluator = fn candidate, example ->
      OptimizeAnything.log("candidate=#{candidate}")
      IO.puts("example=#{example.id}")
      %{score: 0.7, output: :ok, scores: %{"accuracy" => 0.7}}
    end

    result = EvaluatorWrapper.evaluate(evaluator, "seed", %{id: 1})

    assert result.score == 0.7
    assert result.output == :ok
    assert result.scores == %{"accuracy" => 0.7}
    assert result.logs == ["candidate=seed"]
    assert result.stdout =~ "example=1"
  end

  test "single-task string candidate optimizes and unwraps result candidates" do
    proposer = fn candidate, _dataset, components ->
      Map.new(components, &{&1, candidate[&1] <> " better"})
    end

    {:ok, result} =
      OptimizeAnything.optimize_anything(
        seed_candidate: "seed",
        evaluator: fn candidate ->
          if String.contains?(candidate, "better"), do: 1.0, else: 0.1
        end,
        engine: %{max_metric_calls: 4, reflection_minibatch_size: 1},
        reflection: %{custom_candidate_proposer: proposer, skip_perfect_score: false}
      )

    assert is_binary(GEPA.Result.best_candidate(result))
    assert Enum.all?(result.candidates, &is_binary/1)
  end

  test "dataset mode passes examples and preserves ordered evaluation" do
    proposer = fn candidate, _dataset, components ->
      Map.new(components, &{&1, candidate[&1] <> "!"})
    end

    {:ok, result} =
      OptimizeAnything.optimize_anything(
        seed_candidate: %{prompt: "seed"},
        dataset: [%{id: 1}, %{id: 2}],
        evaluator: fn candidate, example ->
          %{score: if(String.contains?(candidate.prompt, "!"), do: 1.0, else: example.id / 10)}
        end,
        engine: %{max_metric_calls: 8, reflection_minibatch_size: 2},
        reflection: %{custom_candidate_proposer: proposer, skip_perfect_score: false}
      )

    assert %GEPA.Result{} = result
    assert result.total_num_evals > 0
  end

  test "internal adapter injects per-example best evals into opt_state" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    proposer = fn candidate, _dataset, components ->
      Map.new(components, &{&1, candidate[&1] <> "!"})
    end

    evaluator = fn candidate, example, %OptimizationState{} = opt_state ->
      Agent.update(calls, fn entries ->
        [{example.id, Enum.map(opt_state.best_example_evals, & &1.score)} | entries]
      end)

      score = if String.contains?(candidate.prompt, "!"), do: 0.9, else: example.id / 10
      {score, %{scores: %{"quality" => score}, Feedback: "score=#{score}"}}
    end

    {:ok, result} =
      OptimizeAnything.optimize_anything(
        seed_candidate: %{prompt: "seed"},
        dataset: [%{id: 1}],
        evaluator: evaluator,
        engine: %{
          max_metric_calls: 5,
          reflection_minibatch_size: 1,
          best_example_evals_k: 2
        },
        reflection: %{custom_candidate_proposer: proposer, skip_perfect_score: false}
      )

    assert %GEPA.Result{} = result

    calls_seen = Agent.get(calls, &Enum.reverse/1)
    assert {1, []} = hd(calls_seen)
    assert Enum.any?(calls_seen, fn {1, scores} -> scores == [0.1] end)
  end

  test "best_example_evals accumulate top scored entries with side_info" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    proposer = fn candidate, _dataset, components ->
      next_guess =
        candidate
        |> Map.fetch!("number")
        |> String.to_integer()
        |> then(&(&1 - 4))
        |> Integer.to_string()

      Map.new(components, &{&1, next_guess})
    end

    evaluator = fn candidate, _example, %OptimizationState{} = opt_state ->
      guess = String.to_integer(candidate["number"])
      off_by = abs(guess - 42)
      score = -off_by * 1.0

      Agent.update(calls, fn entries ->
        entries ++
          [
            %{
              guess: guess,
              score: score,
              best_example_evals: opt_state.best_example_evals
            }
          ]
      end)

      {score, %{guess: guess, off_by: off_by, scores: %{"distance" => score}}}
    end

    {:ok, _result} =
      OptimizeAnything.optimize_anything(
        seed_candidate: %{"number" => "50"},
        evaluator: evaluator,
        objective: "Guess the golden integer.",
        engine: %{
          max_metric_calls: 8,
          reflection_minibatch_size: 1,
          best_example_evals_k: 3
        },
        reflection: %{custom_candidate_proposer: proposer, skip_perfect_score: false}
      )

    calls_seen = Agent.get(calls, & &1)
    assert hd(calls_seen).best_example_evals == []

    calls_with_best_evals =
      Enum.filter(calls_seen, &(&1.best_example_evals != []))

    assert calls_with_best_evals != []

    Enum.each(calls_with_best_evals, fn call ->
      assert length(call.best_example_evals) <= 3
      assert call.best_example_evals == Enum.sort_by(call.best_example_evals, & &1.score, :desc)

      Enum.each(call.best_example_evals, fn entry ->
        assert is_number(entry.score)
        assert is_map(entry.side_info)
        assert Map.has_key?(entry.side_info, "guess")
      end)
    end)
  end

  test "memory cache avoids repeated evaluator calls for identical candidate/example pairs" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    adapter =
      OptimizeAnything.Adapter.new(
        evaluator: fn _candidate, _example ->
          Agent.update(counter, &(&1 + 1))
          {0.5, %{Feedback: "cached"}}
        end,
        cache_mode: :memory,
        parallelism: 1
      )

    batch = [%{id: 1}]
    candidate = %{"candidate" => "seed"}

    assert {:ok, first} = OptimizeAnything.Adapter.evaluate(adapter, batch, candidate, true)
    assert {:ok, second} = OptimizeAnything.Adapter.evaluate(adapter, batch, candidate, true)

    assert first.num_metric_calls == 1
    assert second.num_metric_calls == 0
    assert Agent.get(counter, & &1) == 1
  end

  test "refiner evaluates JSON refinements and records attempt history" do
    refiner =
      Mock.new(responses: [~s({"prompt":"better","refiner_prompt":"keep refining"})])

    adapter =
      OptimizeAnything.Adapter.new(
        evaluator: fn candidate, _example ->
          score = if candidate["prompt"] == "better", do: 0.9, else: 0.1
          {score, %{scores: %{"quality" => score}, Feedback: candidate["prompt"]}}
        end,
        cache_mode: :off,
        parallelism: 1,
        refiner_config: OptimizeAnything.RefinerConfig.new(enabled: true, refiner_lm: refiner)
      )

    candidate = %{"prompt" => "seed", "refiner_prompt" => "improve"}

    assert {:ok, eval_batch} =
             OptimizeAnything.Adapter.evaluate(adapter, [%{id: 1}], candidate, true)

    assert eval_batch.scores == [0.9]
    assert eval_batch.num_metric_calls == 2
    assert [{0.9, best_candidate, side_info}] = eval_batch.outputs
    assert best_candidate["prompt"] == "better"

    assert [%{"quality" => 0.1, "refiner_prompt::quality" => 0.9}] =
             eval_batch.objective_scores

    assert get_in(side_info, ["refiner_prompt_specific_info", "Attempts"]) |> length() == 2
  end

  test "string candidates unwrap even when refiner prompt is injected" do
    proposer = fn candidate, _dataset, components ->
      Map.new(components, &{&1, candidate[&1] <> "!"})
    end

    {:ok, result} =
      OptimizeAnything.optimize_anything(
        seed_candidate: "seed",
        evaluator: fn candidate ->
          if String.contains?(candidate, "seed"), do: 0.5, else: 0.0
        end,
        engine: %{max_metric_calls: 1},
        reflection: %{custom_candidate_proposer: proposer, skip_perfect_score: false},
        refiner: %{
          enabled: true,
          refiner_lm: Mock.new(responses: [~s({"current_candidate":"seed"})])
        }
      )

    assert is_binary(GEPA.Result.best_candidate(result))
    assert Enum.all?(result.candidates, &is_binary/1)
  end

  test "seedless mode generates seed candidate from reflection LM" do
    proposer = fn candidate, _dataset, components ->
      Map.new(components, &{&1, candidate[&1] <> " improved"})
    end

    {:ok, result} =
      OptimizeAnything.optimize_anything(
        evaluator: fn candidate ->
          if String.contains?(candidate, "generated"), do: 0.5, else: 0.0
        end,
        objective: "Find a useful string",
        reflection: %{
          reflection_lm: Mock.new(responses: ["generated seed"]),
          custom_candidate_proposer: proposer,
          skip_perfect_score: false
        },
        engine: %{max_metric_calls: 1}
      )

    assert GEPA.Result.best_candidate(result) == "generated seed"
  end
end
