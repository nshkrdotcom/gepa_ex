defmodule GEPA.OptimizeTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Adapters.Basic
  alias GEPA.LLM.Mock
  alias GEPA.Result
  alias GEPA.StopCondition.MaxCalls
  alias GEPA.Strategies.BatchSampler.EpochShuffled
  alias GEPA.Strategies.CandidateSelector.{CurrentBest, EpsilonGreedy, Pareto, TopKPareto}
  alias GEPA.Strategies.ComponentSelector.RoundRobin
  alias GEPA.Strategies.EvaluationPolicy.Full

  defmodule EqualScoreAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
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

    @impl true
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

    @impl true
    def propose_new_texts(_adapter, candidate, _reflective_dataset, components) do
      {:ok, Map.new(components, &{&1, candidate[&1] <> " updated"})}
    end
  end

  defmodule ImmediateStop do
    @behaviour GEPA.StopCondition

    defstruct []

    @impl true
    def should_stop?(%__MODULE__{}, _state), do: true
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

    test "raises without reflection_llm, custom proposer, or adapter proposer" do
      assert_raise ArgumentError, ~r/reflection_llm was not provided/, fn ->
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          max_metric_calls: 10,
          skip_perfect_score: false
        )
      end
    end
  end

  describe "GEPA.optimize/1 option validation" do
    test "raises when seed_candidate not provided" do
      assert_raise ArgumentError,
                   ~r/seed_candidate must contain at least one component text/,
                   fn ->
                     GEPA.optimize(
                       trainset: [%{input: "Q", answer: "A"}],
                       valset: [%{input: "Q2", answer: "A2"}],
                       adapter: Basic.new(),
                       max_metric_calls: 10
                     )
                   end
    end

    test "raises when seed_candidate is nil" do
      assert_raise ArgumentError,
                   ~r/seed_candidate must contain at least one component text/,
                   fn ->
                     GEPA.optimize(
                       seed_candidate: nil,
                       trainset: [%{input: "Q", answer: "A"}],
                       adapter: Basic.new(),
                       stop_conditions: [%ImmediateStop{}]
                     )
                   end
    end

    test "raises when seed_candidate is empty" do
      assert_raise ArgumentError,
                   ~r/seed_candidate must contain at least one component text/,
                   fn ->
                     GEPA.optimize(
                       seed_candidate: %{},
                       trainset: [%{input: "Q", answer: "A"}],
                       adapter: Basic.new(),
                       stop_conditions: [%ImmediateStop{}]
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

    test "raises when no stop condition is provided" do
      assert_raise ArgumentError, ~r/must provide at least one stop condition/, fn ->
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          custom_candidate_proposer: custom_candidate_proposer()
        )
      end
    end

    test "defaults valset to trainset when omitted" do
      test_pid = self()

      callback = fn
        :optimization_start, %{valset_size: valset_size} ->
          send(test_pid, {:valset_size, valset_size})

        _event, _payload ->
          :ok
      end

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q1", answer: "A1"}, %{input: "Q2", answer: "A2"}],
          adapter: Basic.new(),
          custom_candidate_proposer: custom_candidate_proposer(),
          stop_conditions: [%ImmediateStop{}],
          callbacks: [callback]
        )

      assert %GEPA.Result{} = result
      assert_receive {:valset_size, 2}
    end

    test "accepts custom stop conditions without max_metric_calls" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          adapter: Basic.new(),
          custom_candidate_proposer: custom_candidate_proposer(),
          stop_conditions: [%ImmediateStop{}]
        )

      assert %GEPA.Result{} = result
      assert length(result.candidates) == 1
    end

    test "combines custom stop conditions with max_metric_calls" do
      test_pid = self()

      callback = fn
        :optimization_start, %{config: config} ->
          send(test_pid, {:stop_conditions, config.stop_conditions})

        _event, _payload ->
          :ok
      end

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          adapter: Basic.new(),
          custom_candidate_proposer: custom_candidate_proposer(),
          stop_conditions: [%ImmediateStop{}],
          max_metric_calls: 10,
          callbacks: [callback]
        )

      assert_receive {:stop_conditions, stop_conditions}
      assert Enum.any?(stop_conditions, &match?(%ImmediateStop{}, &1))
      assert Enum.any?(stop_conditions, &match?(%MaxCalls{max_calls: 10}, &1))
    end

    test "adds run_dir file stopper automatically" do
      test_pid = self()

      callback = fn
        :optimization_start, %{config: config} ->
          send(test_pid, {:stop_conditions, config.stop_conditions})

        _event, _payload ->
          :ok
      end

      tmp_dir =
        Path.join(System.tmp_dir!(), "gepa-optimize-test-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      {:ok, _result} =
        GEPA.optimize(
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          adapter: Basic.new(),
          custom_candidate_proposer: custom_candidate_proposer(),
          stop_conditions: [%ImmediateStop{}],
          run_dir: tmp_dir,
          callbacks: [callback]
        )

      assert_receive {:stop_conditions, stop_conditions}

      assert Enum.any?(stop_conditions, fn
               condition ->
                 Map.get(condition, :__struct__) == GEPA.StopCondition.FileStopper and
                   Map.get(condition, :path) == Path.join(tmp_dir, "gepa.stop")
             end)
    end
  end

  describe "GEPA.optimize/1 public strategy options" do
    test "normalizes candidate selector aliases" do
      assert_config(candidate_selection_strategy: :pareto, candidate_selector: Pareto)
      assert_config(candidate_selection_strategy: "pareto", candidate_selector: Pareto)
      assert_config(candidate_selection_strategy: :current_best, candidate_selector: CurrentBest)

      assert_config(
        candidate_selection_strategy: :epsilon_greedy,
        candidate_selector: %{__struct__: EpsilonGreedy}
      )

      assert_config(
        candidate_selection_strategy: :top_k_pareto,
        candidate_selector: %{__struct__: TopKPareto, k: 5}
      )
    end

    test "normalizes batch sampler, module selector, validation policy, and acceptance criterion" do
      assert_config(
        batch_sampler: :epoch_shuffled,
        reflection_minibatch_size: 7,
        module_selector: :round_robin,
        val_evaluation_policy: :full_eval,
        acceptance_criterion: :strict_improvement,
        assert: fn config ->
          assert %EpochShuffled{minibatch_size: 7} = config.batch_sampler
          assert config.module_selector == RoundRobin
          assert config.val_evaluation_policy == Full
          assert config.acceptance_criterion == GEPA.Strategies.Acceptance.StrictImprovement
        end
      )
    end

    test "builds evaluation cache and passes exception policy" do
      assert_config(
        cache_evaluation: true,
        raise_on_exception: false,
        assert: fn config ->
          assert %GEPA.EvaluationCache{} = config.evaluation_cache
          assert config.raise_on_exception == false
        end
      )
    end

    test "passes max_iterations and num_parallel_proposals to engine config" do
      assert_config(
        max_iterations: 12,
        num_parallel_proposals: 3,
        assert: fn config ->
          assert config.max_iterations == 12
          assert config.num_parallel_proposals == 3
        end
      )
    end

    test "builds merge proposer from public options" do
      assert_config(
        use_merge: true,
        max_merge_invocations: 9,
        merge_val_overlap_floor: 2,
        assert: fn config ->
          assert %GEPA.Proposer.Merge{} = config.merge_proposer
          assert config.merge_proposer.max_merge_invocations == 9
          assert config.merge_proposer.val_overlap_floor == 2
        end
      )
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
          max_metric_calls: 1,
          task_lm: task_lm,
          custom_candidate_proposer: custom_candidate_proposer()
        )

      assert %GEPA.Result{} = result
      assert Result.best_score(result) == 1.0
    end

    test "optimizes an AIME-style system prompt with default adapter and reflection_lm" do
      aime_examples = aime_style_examples()
      trainset = Enum.take(aime_examples, 10)
      valset = Enum.drop(aime_examples, 10)
      answers_by_input = Map.new(aime_examples, &{&1.input, &1.answer})

      optimized_prompt =
        "Check each arithmetic step twice and return only the final integer answer."

      captured_prompts = :ets.new(:aime_reflection_prompts, [:ordered_set, :public])

      reflection_lm =
        Mock.new(
          response_fn: fn prompt ->
            :ets.insert(captured_prompts, {System.unique_integer([:positive]), prompt})
            "```\n#{optimized_prompt}\n```"
          end
        )

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

      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{
            "system_prompt" =>
              "Solve the problem. The final answer must be an integer in the range 0-999."
          },
          trainset: trainset,
          valset: valset,
          task_lm: task_lm,
          max_metric_calls: 30,
          reflection_lm: reflection_lm,
          reflection_minibatch_size: 3,
          score_threshold: 1.0
        )

      prompts = :ets.tab2list(captured_prompts) |> Enum.map(&elem(&1, 1))
      :ets.delete(captured_prompts)

      assert Enum.any?(prompts, &String.contains?(&1, "Generated Outputs"))
      assert length(result.candidates) >= 2
      assert Result.best_score(result) == 1.0
      assert Result.best_candidate(result)["system_prompt"] == optimized_prompt
    end
  end

  describe "GEPA.optimize/1 acceptance criteria" do
    test "max_iterations limits the safety iteration cap" do
      {:ok, result} =
        GEPA.optimize(
          seed_candidate: %{"instruction" => "Original"},
          trainset: [%{input: "Q", answer: "A"}],
          valset: [%{input: "Q2", answer: "A2"}],
          adapter: EqualScoreAdapter.new(),
          max_metric_calls: 100,
          max_iterations: 0,
          skip_perfect_score: false
        )

      assert result.i == -1
      assert length(result.candidates) == 1
    end

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

  defp custom_candidate_proposer do
    fn candidate, _reflective_dataset, components ->
      Map.new(components, fn component ->
        {component, Map.get(candidate, component, "") <> " updated"}
      end)
    end
  end

  defp aime_style_examples do
    for n <- 1..20 do
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

  defp assert_config(opts) do
    assertion = Keyword.get(opts, :assert)
    expected_selector = Keyword.get(opts, :candidate_selector)
    opts = Keyword.delete(opts, :assert) |> Keyword.delete(:candidate_selector)
    test_pid = self()

    callback = fn
      :optimization_start, %{config: config} ->
        send(test_pid, {:config, config})

      _event, _payload ->
        :ok
    end

    {:ok, _result} =
      GEPA.optimize(
        [
          seed_candidate: %{"i" => "test"},
          trainset: [%{input: "Q", answer: "A"}],
          adapter: Basic.new(),
          custom_candidate_proposer: custom_candidate_proposer(),
          stop_conditions: [%ImmediateStop{}],
          callbacks: [callback]
        ] ++ opts
      )

    assert_receive {:config, config}

    if expected_selector do
      if is_map(expected_selector) do
        assert Map.take(config.candidate_selector, Map.keys(expected_selector)) ==
                 expected_selector
      else
        assert config.candidate_selector == expected_selector
      end
    end

    if assertion do
      assertion.(config)
    end
  end
end
