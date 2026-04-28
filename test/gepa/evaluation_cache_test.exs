defmodule GEPA.EvaluationCacheTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.EvaluationCache
  alias GEPA.LLM.Mock
  alias GEPA.Result

  defmodule DummyAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def evaluate(_adapter, batch, candidate, capture_traces) do
      weight = String.length(Map.get(candidate, "system_prompt", "")) |> rem(10)
      score = (weight + 1) / 10

      {:ok,
       %GEPA.EvaluationBatch{
         outputs: Enum.with_index(batch, fn _example, index -> %{id: index, weight: weight} end),
         scores: Enum.map(batch, fn _ -> score end),
         trajectories: if(capture_traces, do: Enum.map(batch, fn _ -> %{score: score} end)),
         objective_scores: Enum.map(batch, fn _ -> %{"quality" => score, "safety" => 1.0} end)
       }}
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, eval_batch, components) do
      {:ok,
       Map.new(components, fn component ->
         {component, Enum.map(eval_batch.scores, &%{"Feedback" => "score=#{&1}"})}
       end)}
    end

    @impl true
    def propose_new_texts(_adapter, candidate, _reflective_dataset, components) do
      {:ok, Map.new(components, &{&1, Map.get(candidate, &1, "") <> " v2"})}
    end
  end

  describe "cache operations" do
    test "upstream empty cache returns miss" do
      assert :miss =
               EvaluationCache.get(EvaluationCache.new(), %{"prompt" => "test"}, "example_1")
    end

    test "upstream put and get basic" do
      cache =
        EvaluationCache.new()
        |> EvaluationCache.put(%{"prompt" => "test"}, "example_1", "output1", 0.8)

      assert {:ok, entry} = EvaluationCache.get(cache, %{"prompt" => "test"}, "example_1")
      assert entry.output == "output1"
      assert entry.score == 0.8
    end

    test "upstream different examples separate entries" do
      candidate = %{"prompt" => "test"}

      cache =
        EvaluationCache.new()
        |> EvaluationCache.put(candidate, "ex1", "out1", 0.5)
        |> EvaluationCache.put(candidate, "ex2", "out2", 0.7)

      assert {:ok, %{output: "out1"}} = EvaluationCache.get(cache, candidate, "ex1")
      assert {:ok, %{output: "out2"}} = EvaluationCache.get(cache, candidate, "ex2")
    end

    test "upstream different candidates separate entries" do
      cache =
        EvaluationCache.new()
        |> EvaluationCache.put(%{"prompt" => "test1"}, "ex1", "out1", 0.5)
        |> EvaluationCache.put(%{"prompt" => "test2"}, "ex1", "out2", 0.7)

      assert {:ok, %{output: "out1"}} = EvaluationCache.get(cache, %{"prompt" => "test1"}, "ex1")
      assert {:ok, %{output: "out2"}} = EvaluationCache.get(cache, %{"prompt" => "test2"}, "ex1")
    end

    test "upstream get batch" do
      candidate = %{"prompt" => "test"}

      cache =
        EvaluationCache.new()
        |> EvaluationCache.put(candidate, "ex1", "out1", 0.5)
        |> EvaluationCache.put(candidate, "ex2", "out2", 0.6)

      {cached_results, uncached_ids} =
        EvaluationCache.get_batch(cache, candidate, ["ex1", "ex2", "ex3"])

      assert Map.has_key?(cached_results, "ex1")
      assert Map.has_key?(cached_results, "ex2")
      assert uncached_ids == ["ex3"]
    end

    test "upstream put batch" do
      candidate = %{"prompt" => "test"}

      cache =
        EvaluationCache.put_batch(
          EvaluationCache.new(),
          candidate,
          ["ex1", "ex2"],
          ["out1", "out2"],
          [0.5, 0.6],
          [%{"acc" => 0.9}, %{"acc" => 0.8}]
        )

      assert {:ok, %{score: 0.5}} = EvaluationCache.get(cache, candidate, "ex1")

      assert {:ok, %{objective_scores: %{"acc" => 0.8}}} =
               EvaluationCache.get(cache, candidate, "ex2")
    end

    test "stores and retrieves candidate/example evaluations" do
      cache = EvaluationCache.new()

      cache =
        EvaluationCache.put(cache, %{"instruction" => "seed"}, 10, "output", 0.8, %{
          "accuracy" => 0.8
        })

      assert {:ok, entry} = EvaluationCache.get(cache, %{"instruction" => "seed"}, 10)
      assert entry.output == "output"
      assert entry.score == 0.8
      assert entry.objective_scores == %{"accuracy" => 0.8}
      assert :miss = EvaluationCache.get(cache, %{"instruction" => "other"}, 10)
    end

    test "splits cached and uncached ids in requested order" do
      cache =
        EvaluationCache.new()
        |> EvaluationCache.put(%{"instruction" => "seed"}, :a, "a-out", 0.1)
        |> EvaluationCache.put(%{"instruction" => "seed"}, :c, "c-out", 0.3)

      assert {cached, uncached} =
               EvaluationCache.get_batch(cache, %{"instruction" => "seed"}, [:a, :b, :c])

      assert MapSet.new(Map.keys(cached)) == MapSet.new([:a, :c])
      assert uncached == [:b]
    end
  end

  describe "upstream cache integration parity" do
    test "optimize with caching enabled" do
      assert {:ok, result} =
               GEPA.optimize(
                 seed_candidate: %{"system_prompt" => "test"},
                 trainset: indexed_examples(5),
                 valset: indexed_examples(5),
                 adapter: DummyAdapter.new(),
                 max_metric_calls: 20,
                 cache_evaluation: true,
                 skip_perfect_score: false
               )

      assert result.total_num_evals > 0
    end

    test "caching does not break optimization" do
      trainset = indexed_examples(5)
      valset = indexed_examples(5)
      seed = %{"system_prompt" => "test"}

      assert {:ok, result_no_cache} =
               GEPA.optimize(
                 seed_candidate: seed,
                 trainset: trainset,
                 valset: valset,
                 adapter: DummyAdapter.new(),
                 max_metric_calls: 20,
                 cache_evaluation: false,
                 skip_perfect_score: false
               )

      assert {:ok, result_with_cache} =
               GEPA.optimize(
                 seed_candidate: seed,
                 trainset: trainset,
                 valset: valset,
                 adapter: DummyAdapter.new(),
                 max_metric_calls: 20,
                 cache_evaluation: true,
                 skip_perfect_score: false
               )

      assert result_no_cache.total_num_evals > 0
      assert result_with_cache.total_num_evals > 0
    end

    test "AIME-style prompt optimization with cache" do
      examples = aime_style_examples()
      trainset = Enum.take(examples, 6)
      valset = Enum.drop(examples, 6)
      answers_by_input = Map.new(examples, &{&1.input, &1.answer})

      optimized_prompt =
        "Check each arithmetic step twice and return only the final integer answer."

      reflection_lm = Mock.new(responses: ["```\n#{optimized_prompt}\n```"])

      task_lm = fn messages ->
        system_message = Enum.find(messages, &(&1.role == "system"))
        user_message = Enum.find(messages, &(&1.role == "user"))
        answer = Map.fetch!(answers_by_input, user_message.content)

        if String.contains?(system_message.content, "Check each arithmetic step twice") do
          "The final answer is #{answer}."
        else
          "The final answer is 999."
        end
      end

      assert {:ok, result} =
               GEPA.optimize(
                 seed_candidate: %{
                   "system_prompt" =>
                     "Solve the problem. The final answer must be an integer in the range 0-999."
                 },
                 trainset: trainset,
                 valset: valset,
                 task_lm: task_lm,
                 max_metric_calls: 12,
                 reflection_lm: reflection_lm,
                 reflection_minibatch_size: 2,
                 cache_evaluation: true,
                 score_threshold: 1.0
               )

      assert result.total_num_evals > 0
      assert is_binary(Result.best_candidate(result)["system_prompt"])
    end

    test "pareto frontier types with cache" do
      for frontier_type <- [:objective, :hybrid, :instance] do
        assert {:ok, result} =
                 GEPA.optimize(
                   seed_candidate: %{"system_prompt" => "test"},
                   trainset: indexed_examples(6),
                   valset: indexed_examples(6),
                   adapter: DummyAdapter.new(),
                   max_metric_calls: 12,
                   cache_evaluation: true,
                   frontier_type: frontier_type,
                   reflection_minibatch_size: 2,
                   skip_perfect_score: false
                 )

        assert result.total_num_evals > 0
        assert is_binary(Result.best_candidate(result)["system_prompt"])
      end
    end
  end

  defp indexed_examples(count), do: Enum.map(0..(count - 1), &%{id: &1})

  defp aime_style_examples do
    for n <- 1..12 do
      left = n + 11
      right = n * 4 + 7

      %{
        input:
          "AIME-style problem #{n}: Compute #{left} + #{right}. " <>
            "Return the final answer as an integer.",
        answer: Integer.to_string(left + right)
      }
    end
  end
end
