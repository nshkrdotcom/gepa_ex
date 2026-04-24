defmodule GEPA.Examples.ReplacedExampleScenariosTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  defmodule SentimentAdapter do
    @behaviour GEPA.Adapter

    defstruct [:llm]

    @impl true
    def evaluate(%__MODULE__{llm: llm}, batch, candidate, capture_traces) do
      results =
        Enum.map(batch, fn example ->
          prompt = "#{candidate["instruction"]}\n\nText: #{example.text}"
          {:ok, response} = GEPA.LLM.complete(llm, prompt)
          predicted = sentiment(response)
          score = if predicted == example.sentiment, do: 1.0, else: 0.0

          %{
            output: %{predicted: predicted, response: response},
            score: score,
            trace: %{prompt: prompt, response: response, expected: example.sentiment}
          }
        end)

      {:ok,
       %GEPA.EvaluationBatch{
         outputs: Enum.map(results, & &1.output),
         scores: Enum.map(results, & &1.score),
         trajectories: if(capture_traces, do: Enum.map(results, & &1.trace))
       }}
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, eval_batch, components) do
      dataset =
        for component <- components, into: %{} do
          items =
            Enum.map(eval_batch.trajectories, fn trace ->
              %{
                "Inputs" => %{"prompt" => trace.prompt},
                "Generated Outputs" => trace.response,
                "Feedback" => "Expected #{trace.expected}"
              }
            end)

          {component, items}
        end

      {:ok, dataset}
    end

    defp sentiment(response) do
      response = String.downcase(response)

      cond do
        String.contains?(response, "positive") -> "positive"
        String.contains?(response, "negative") -> "negative"
        true -> "neutral"
      end
    end
  end

  describe "scenarios removed from live-only examples" do
    test "quick-start style optimization remains covered by tests" do
      llm = GEPA.LLM.Mock.new(response_fn: fn _prompt -> "The answer is 4." end)
      adapter = GEPA.Adapters.Basic.new(llm: llm)

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Answer directly."},
          trainset: [%{input: "What is 2+2?", answer: "4"}],
          valset: [%{input: "What is 2+2?", answer: "4"}],
          adapter: adapter,
          max_metric_calls: 3
        )

      assert GEPA.Result.best_score(result) == 1.0
    end

    test "state persistence flow remains covered by tests" do
      run_dir =
        Path.join(
          System.tmp_dir!(),
          "gepa-example-persistence-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(run_dir) end)

      llm = GEPA.LLM.Mock.new(response_fn: fn _prompt -> "The answer is Paris." end)
      adapter = GEPA.Adapters.Basic.new(llm: llm)

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Answer directly."},
          trainset: [%{input: "Capital of France?", answer: "Paris"}],
          valset: [%{input: "Capital of France?", answer: "Paris"}],
          adapter: adapter,
          run_dir: run_dir,
          max_metric_calls: 3
        )

      assert File.exists?(Path.join(run_dir, "gepa_state.etf"))
      assert File.exists?(Path.join(run_dir, "candidates.json"))
    end

    test "custom adapter sentiment flow remains covered by tests" do
      llm =
        GEPA.LLM.Mock.new(
          response_fn: fn prompt ->
            if String.contains?(prompt, "excellent"), do: "positive", else: "negative"
          end
        )

      adapter = %SentimentAdapter{llm: llm}

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Classify sentiment."},
          trainset: [%{text: "excellent service", sentiment: "positive"}],
          valset: [%{text: "bad service", sentiment: "negative"}],
          adapter: adapter,
          max_metric_calls: 3
        )

      assert is_float(GEPA.Result.best_score(result))
    end
  end
end
