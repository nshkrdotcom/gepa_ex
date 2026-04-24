defmodule GEPA.OptimizeTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Adapters.Basic
  alias GEPA.LLM.Mock
  alias GEPA.Result

  defmodule EqualScoreAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    def new, do: %__MODULE__{}

    def evaluate(_adapter, batch, _candidate, capture_traces) do
      trajectories =
        if capture_traces do
          Enum.map(batch, fn item -> %{item: item, feedback: "same score"} end)
        else
          nil
        end

      {:ok,
       %GEPA.EvaluationBatch{
         outputs: Enum.map(batch, fn _ -> "same" end),
         scores: Enum.map(batch, fn _ -> 0.5 end),
         trajectories: trajectories
       }}
    end

    def make_reflective_dataset(_adapter, candidate, eval_batch, components) do
      dataset =
        for component <- components, into: %{} do
          rows =
            Enum.map(eval_batch.scores, fn score ->
              %{
                "Inputs" => %{},
                "Generated Outputs" => candidate[component],
                "Feedback" => "score=#{score}"
              }
            end)

          {component, rows}
        end

      {:ok, dataset}
    end
  end

  describe "GEPA.optimize/1 with reflection_llm" do
    test "accepts reflection_llm option" do
      llm = Mock.new(responses: ["LLM-improved instruction"])

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10,
          reflection_llm: llm
        )

      assert %GEPA.Result{} = result
    end

    test "uses LLM to generate improved candidates when reflection_llm provided" do
      call_count = :counters.new(1, [:atomics])

      llm =
        Mock.new(
          response_fn: fn _prompt ->
            :counters.add(call_count, 1, 1)
            "LLM-generated improvement"
          end
        )

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 15,
          reflection_llm: llm,
          skip_perfect_score: false
        )

      assert :counters.get(call_count, 1) > 0
      assert result.candidates != []
    end

    test "accepts custom proposal_template with reflection_llm" do
      captured_prompts = :ets.new(:captured_prompts, [:set, :public])

      llm =
        Mock.new(
          response_fn: fn prompt ->
            :ets.insert(captured_prompts, {System.unique_integer(), prompt})
            "improved"
          end
        )

      custom_template = """
      CUSTOM_MARKER: Improve {component_name}
      Current: {current_instruction}
      Feedback: {reflective_dataset}
      """

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10,
          reflection_llm: llm,
          proposal_template: custom_template,
          skip_perfect_score: false
        )

      prompts = :ets.tab2list(captured_prompts) |> Enum.map(&elem(&1, 1))
      :ets.delete(captured_prompts)

      if prompts != [] do
        assert Enum.any?(prompts, &String.contains?(&1, "CUSTOM_MARKER"))
      end
    end

    test "falls back to simple improvement without reflection_llm" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10
        )

      assert %GEPA.Result{} = result
    end
  end

  describe "GEPA.optimize/1 option validation" do
    test "raises when seed_candidate not provided" do
      assert_raise ArgumentError, ~r/must provide :seed_candidate/, fn ->
        GEPA.optimize(
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10
        )
      end
    end

    test "raises when adapter not provided" do
      assert_raise ArgumentError, ~r/must provide :adapter/, fn ->
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          max_metric_calls: 10
        )
      end
    end

    test "raises when max_metric_calls not provided" do
      assert_raise ArgumentError, ~r/must provide :max_metric_calls/, fn ->
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new()
        )
      end
    end
  end

  describe "GEPA.optimize/1 default adapter" do
    test "builds a default adapter when task_lm is provided without adapter" do
      task_lm = fn messages ->
        user_message = Enum.find(messages, &(&1.role == "user"))

        if String.contains?(user_message.content, "2+2") do
          "The answer is 4"
        else
          "The answer is 10"
        end
      end

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Answer exactly."},
          trainset: [%{input: "What is 2+2?", answer: "4"}],
          valset: [%{input: "What is 5+5?", answer: "10"}],
          max_metric_calls: 2,
          task_lm: task_lm
        )

      assert %GEPA.Result{} = result
      assert Result.best_score(result) == 1.0
    end
  end

  describe "GEPA.optimize/1 acceptance criteria" do
    test "strict improvement rejects equal-score proposals by default" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: EqualScoreAdapter.new(),
          max_metric_calls: 6,
          skip_perfect_score: false
        )

      assert length(result.candidates) == 1
    end

    test "improvement_or_equal accepts equal-score proposals" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: EqualScoreAdapter.new(),
          max_metric_calls: 6,
          skip_perfect_score: false,
          acceptance_criterion: :improvement_or_equal
        )

      assert length(result.candidates) > 1
    end
  end

  describe "GEPA.optimize/1 callbacks" do
    test "notifies lifecycle, iteration, and candidate decision callbacks" do
      test_pid = self()

      callback = fn event_name, event ->
        send(test_pid, {:gepa_callback, event_name, event})
      end

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: EqualScoreAdapter.new(),
          max_metric_calls: 6,
          skip_perfect_score: false,
          acceptance_criterion: :improvement_or_equal,
          callbacks: [callback]
        )

      assert_receive {:gepa_callback, :optimization_start,
                      %{seed_candidate: %{"instruction" => "Original"}}}

      assert_receive {:gepa_callback, :iteration_start, %{iteration: 1}}
      assert_receive {:gepa_callback, :candidate_accepted, %{iteration: 1, new_candidate_idx: 1}}

      assert_receive {:gepa_callback, :optimization_end, %{total_metric_calls: calls}}
                     when calls > 0
    end
  end
end
