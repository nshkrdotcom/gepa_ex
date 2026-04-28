defmodule GEPA.OptimizeAnythingRefinerParityTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.OptimizeAnything
  alias GEPA.OptimizeAnything.{Adapter, RefinerConfig}

  @golden_number 42
  @dataset [%{golden: 40}, %{golden: 60}]
  @frontier_types [:instance, :objective, :hybrid, :cartesian]

  describe "upstream refiner parity" do
    test "refiner works without caching and defaults its LM from reflection_lm" do
      {:ok, counter} = start_counter()

      assert {:ok, result} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: %{"number" => "50"},
                 evaluator: single_number_evaluator(counter),
                 objective: "Guess the golden integer.",
                 engine: %{max_metric_calls: 1, cache_evaluation: false},
                 reflection: %{reflection_lm: number_refiner_lm(), skip_perfect_score: false},
                 refiner: %{max_refinements: 1}
               )

      assert Map.has_key?(GEPA.Result.best_candidate(result), "refiner_prompt")
      assert counter_value(counter) >= 2
      assert GEPA.Result.best_score(result) == 0.0
    end

    test "refiner works with memory cache" do
      {:ok, counter} = start_counter()

      adapter =
        refiner_adapter(
          evaluator: adapter_number_evaluator(counter),
          cache_mode: :memory,
          refiner_lm: static_refiner_lm(%{"number" => "50"})
        )

      candidate = %{"number" => "50", "refiner_prompt" => "Improve the guess."}

      assert {:ok, first} = Adapter.evaluate(adapter, [%{}], candidate, true)
      assert {:ok, second} = Adapter.evaluate(adapter, [%{}], candidate, true)

      assert first.num_metric_calls == 1
      assert second.num_metric_calls == 0
      assert counter_value(counter) == 1
    end

    test "refiner works with disk cache" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "gepa-refiner-cache-#{System.unique_integer([:positive])}")

      cache_dir = Path.join(tmp_dir, "fitness_cache")
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      {:ok, counter} = start_counter()

      adapter =
        refiner_adapter(
          evaluator: adapter_number_evaluator(counter),
          cache_mode: :disk,
          cache_dir: cache_dir,
          refiner_lm: static_refiner_lm(%{"number" => "50"})
        )

      assert {:ok, eval_batch} =
               Adapter.evaluate(
                 adapter,
                 [%{}],
                 %{"number" => "50", "refiner_prompt" => "Improve the guess."},
                 true
               )

      assert eval_batch.num_metric_calls == 1
      assert File.dir?(cache_dir)
      assert cache_dir |> File.ls!() |> Enum.any?(&String.ends_with?(&1, ".etf"))
    end

    test "refiner cache reduces actual evaluator calls" do
      {:ok, no_cache_counter} = start_counter()
      {:ok, memory_cache_counter} = start_counter()

      candidate = %{"number" => "50", "refiner_prompt" => "Improve the guess."}

      no_cache =
        refiner_adapter(
          evaluator: adapter_number_evaluator(no_cache_counter),
          cache_mode: :off,
          refiner_lm: static_refiner_lm(%{"number" => "50"})
        )

      memory_cache =
        refiner_adapter(
          evaluator: adapter_number_evaluator(memory_cache_counter),
          cache_mode: :memory,
          refiner_lm: static_refiner_lm(%{"number" => "50"})
        )

      assert {:ok, _eval_batch} = Adapter.evaluate(no_cache, [%{}], candidate, true)
      assert {:ok, _eval_batch} = Adapter.evaluate(memory_cache, [%{}], candidate, true)

      assert counter_value(memory_cache_counter) <= counter_value(no_cache_counter)
      assert counter_value(no_cache_counter) == 2
      assert counter_value(memory_cache_counter) == 1
    end

    test "custom refiner prompt is preserved and sent to the refiner LM" do
      {:ok, prompt_agent} = Agent.start_link(fn -> [] end)
      custom_prompt = "My custom refiner instructions: always guess 42."

      refiner_lm = fn prompt ->
        Agent.update(prompt_agent, &[prompt | &1])
        ~s({"number":"42"})
      end

      adapter =
        refiner_adapter(
          evaluator: adapter_number_evaluator(),
          cache_mode: :off,
          refiner_lm: refiner_lm
        )

      assert {:ok, _eval_batch} =
               Adapter.evaluate(
                 adapter,
                 [%{}],
                 %{"number" => "50", "refiner_prompt" => custom_prompt},
                 true
               )

      prompts = Agent.get(prompt_agent, & &1)
      assert Enum.any?(prompts, &String.contains?(&1, custom_prompt))
    end

    test "multi-parameter refiner evaluates all non-refiner params together" do
      adapter =
        refiner_adapter(
          evaluator: multi_param_evaluator(),
          cache_mode: :off,
          refiner_lm: static_refiner_lm(%{"param_a" => "70", "param_b" => "30"})
        )

      candidate = %{
        "param_a" => "30",
        "param_b" => "20",
        "refiner_prompt" => "Find two integers that sum to 100."
      }

      assert {:ok, eval_batch} = Adapter.evaluate(adapter, [%{}], candidate, true)

      assert eval_batch.scores == [0.0]
      assert [{score, best_candidate, _side_info}] = eval_batch.outputs
      assert score == 0.0
      assert best_candidate["param_a"] == "70"
      assert best_candidate["param_b"] == "30"
      assert Map.has_key?(best_candidate, "refiner_prompt")
    end

    test "side info preserves user fields and adds refiner prompt details" do
      adapter =
        refiner_adapter(
          evaluator: adapter_number_evaluator(),
          cache_mode: :off,
          refiner_lm: number_refiner_lm()
        )

      assert {:ok, eval_batch} =
               Adapter.evaluate(
                 adapter,
                 [%{}],
                 %{"number" => "50", "refiner_prompt" => "Improve the guess."},
                 true
               )

      assert [side_info] = eval_batch.trajectories
      assert side_info["guess"] == 50
      assert side_info["golden"] == @golden_number
      assert side_info["off_by"] == 8
      assert %{"accuracy" => 0.92} = side_info["scores"]

      assert %{"Attempts" => attempts, "scores" => %{"accuracy" => 1.0}} =
               side_info["refiner_prompt_specific_info"]

      assert [%{"iteration" => 0} | _] = attempts
    end

    test "refiner can improve score and final score is at least the original" do
      adapter =
        refiner_adapter(
          evaluator: adapter_number_evaluator(),
          cache_mode: :off,
          refiner_lm: number_refiner_lm()
        )

      assert {:ok, eval_batch} =
               Adapter.evaluate(
                 adapter,
                 [%{}],
                 %{"number" => "0", "refiner_prompt" => "Use feedback to improve."},
                 true
               )

      assert [score] = eval_batch.scores
      attempts = get_in(hd(eval_batch.trajectories), ["refiner_prompt_specific_info", "Attempts"])
      original_score = hd(attempts)["score"]
      best_attempt_score = attempts |> Enum.map(& &1["score"]) |> Enum.max()

      assert score >= original_score
      assert best_attempt_score > original_score
      assert score == best_attempt_score
    end

    test "refiner score is never worse than the original score" do
      adapter =
        refiner_adapter(
          evaluator: adapter_number_evaluator(),
          cache_mode: :off,
          refiner_lm: static_refiner_lm(%{"number" => "0"})
        )

      assert {:ok, eval_batch} =
               Adapter.evaluate(
                 adapter,
                 [%{}],
                 %{"number" => "41", "refiner_prompt" => "Improve the guess."},
                 true
               )

      attempts = get_in(hd(eval_batch.trajectories), ["refiner_prompt_specific_info", "Attempts"])
      original_score = hd(attempts)["score"]

      assert eval_batch.scores == [original_score]
      assert original_score == -1.0
    end

    test "refiner scores fall back to original scores when all refinements fail" do
      adapter =
        refiner_adapter(
          evaluator: adapter_number_evaluator(),
          cache_mode: :off,
          refiner_lm: fn _prompt -> "this is not valid json at all" end,
          max_refinements: 3
        )

      assert {:ok, eval_batch} =
               Adapter.evaluate(
                 adapter,
                 [%{}],
                 %{"number" => "50", "refiner_prompt" => "Improve the guess."},
                 true
               )

      refiner_info = get_in(hd(eval_batch.trajectories), ["refiner_prompt_specific_info"])
      evaluated = Enum.filter(refiner_info["Attempts"], &Map.has_key?(&1, "side_info"))
      failed = Enum.filter(refiner_info["Attempts"], &Map.has_key?(&1, "error"))

      assert length(evaluated) == 1
      assert failed != []
      assert refiner_info["scores"] == %{"accuracy" => 0.92}
      assert eval_batch.scores == [-8.0]
    end

    test "single-instance optimize_anything baseline injects refiner prompt" do
      {:ok, counter} = start_counter()

      assert {:ok, result} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: %{"number" => "50"},
                 evaluator: single_number_evaluator(counter),
                 objective: "Guess the golden integer.",
                 engine: %{max_metric_calls: 1, cache_evaluation: false},
                 reflection: %{reflection_lm: number_refiner_lm(), skip_perfect_score: false},
                 refiner: %{max_refinements: 1}
               )

      assert Map.has_key?(GEPA.Result.best_candidate(result), "refiner_prompt")
      assert is_number(GEPA.Result.best_score(result))
      assert counter_value(counter) >= 2
    end

    test "dataset optimize_anything mode runs with refiner enabled" do
      {:ok, counter} = start_counter()

      assert {:ok, result} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: %{"number" => "50"},
                 dataset: @dataset,
                 evaluator: dataset_number_evaluator(counter),
                 objective: "Guess a number close to each example's golden number.",
                 engine: %{max_metric_calls: 2, cache_evaluation: false},
                 reflection: %{reflection_lm: static_refiner_lm(%{"number" => "50"})},
                 refiner: %{max_refinements: 1}
               )

      assert Map.has_key?(GEPA.Result.best_candidate(result), "refiner_prompt")
      assert is_number(GEPA.Result.best_score(result))
      assert counter_value(counter) >= length(@dataset)
    end

    test "refiner works with each frontier type in dataset mode" do
      Enum.each(@frontier_types, fn frontier_type ->
        {:ok, counter} = start_counter()

        assert {:ok, result} =
                 OptimizeAnything.optimize_anything(
                   seed_candidate: %{"number" => "50"},
                   dataset: @dataset,
                   evaluator: dataset_number_evaluator(counter),
                   objective: "Guess a number close to each example's golden number.",
                   engine: %{
                     max_metric_calls: 2,
                     cache_evaluation: false,
                     frontier_type: frontier_type
                   },
                   reflection: %{reflection_lm: static_refiner_lm(%{"number" => "50"})},
                   refiner: %{max_refinements: 1}
                 )

        assert Map.has_key?(GEPA.Result.best_candidate(result), "refiner_prompt")
        assert is_number(GEPA.Result.best_score(result))
      end)
    end

    test "dataset side info contains user fields and refiner objective scores" do
      Enum.each(@frontier_types, fn _frontier_type ->
        adapter =
          refiner_adapter(
            evaluator: adapter_dataset_evaluator(),
            cache_mode: :off,
            refiner_lm: static_refiner_lm(%{"number" => "50"})
          )

        candidate = %{"number" => "50", "refiner_prompt" => "Improve each example."}

        assert {:ok, eval_batch} = Adapter.evaluate(adapter, @dataset, candidate, true)
        assert length(eval_batch.scores) == length(@dataset)
        assert length(eval_batch.objective_scores) == length(@dataset)

        Enum.each(Enum.zip(eval_batch.trajectories, eval_batch.objective_scores), fn {side_info,
                                                                                      scores} ->
          assert Map.has_key?(side_info, "guess")
          assert Map.has_key?(side_info, "golden")
          assert Map.has_key?(side_info, "off_by")
          assert %{"accuracy" => _} = side_info["scores"]

          assert %{"Attempts" => [_ | _], "scores" => %{"accuracy" => _}} =
                   side_info["refiner_prompt_specific_info"]

          assert Map.has_key?(scores, "accuracy")
          assert Map.has_key?(scores, "refiner_prompt::accuracy")
        end)
      end)
    end
  end

  defp start_counter, do: Agent.start_link(fn -> 0 end)

  defp counter_value(counter), do: Agent.get(counter, & &1)

  defp single_number_evaluator(counter) do
    fn candidate ->
      Agent.update(counter, &(&1 + 1))
      score_candidate(candidate, @golden_number)
    end
  end

  defp adapter_number_evaluator(counter \\ nil) do
    fn candidate, _example ->
      if counter, do: Agent.update(counter, &(&1 + 1))
      score_candidate(candidate, @golden_number)
    end
  end

  defp dataset_number_evaluator(counter) do
    fn candidate, example ->
      Agent.update(counter, &(&1 + 1))
      score_candidate(candidate, example.golden)
    end
  end

  defp adapter_dataset_evaluator do
    fn candidate, example ->
      score_candidate(candidate, example.golden)
    end
  end

  defp multi_param_evaluator do
    fn candidate, _example ->
      a = parse_int(candidate["param_a"])
      b = parse_int(candidate["param_b"])
      off_by = abs(a + b - 100)

      {-off_by * 1.0,
       %{
         param_a_value: a,
         param_b_value: b,
         sum: a + b,
         target_sum: 100,
         off_by: off_by,
         scores: %{accuracy: max(0.0, 1.0 - off_by / 100.0)}
       }}
    end
  end

  defp score_candidate(candidate, golden) do
    guess = parse_int(candidate["number"])
    off_by = abs(guess - golden)

    {-off_by * 1.0,
     %{
       guess: guess,
       golden: golden,
       off_by: off_by,
       scores: %{accuracy: max(0.0, 1.0 - off_by / 100.0)}
     }}
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> 0
    end
  end

  defp parse_int(_value), do: 0

  defp refiner_adapter(opts) do
    refiner_lm = Keyword.fetch!(opts, :refiner_lm)
    max_refinements = Keyword.get(opts, :max_refinements, 1)

    Adapter.new(
      evaluator: Keyword.fetch!(opts, :evaluator),
      cache_mode: Keyword.get(opts, :cache_mode, :off),
      cache_dir: Keyword.get(opts, :cache_dir),
      parallelism: 1,
      refiner_config:
        RefinerConfig.new(
          enabled: true,
          refiner_lm: refiner_lm,
          max_refinements: max_refinements
        )
    )
  end

  defp number_refiner_lm, do: static_refiner_lm(%{"number" => "42"})

  defp static_refiner_lm(params) do
    response = Jason.encode!(params)
    fn _prompt -> response end
  end
end
