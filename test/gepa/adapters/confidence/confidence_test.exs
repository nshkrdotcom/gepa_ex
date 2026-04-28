defmodule GEPA.Adapters.ConfidenceTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.Confidence
  alias GEPA.Adapters.Confidence.Scoring.{LinearBlend, Threshold}

  test "evaluate parses structured model output and records confidence objectives" do
    model = fn _prompt -> Jason.encode!(%{category_name: "Food & Drinks/Restaurants"}) end

    adapter =
      Confidence.new(
        model: model,
        field_path: "category_name",
        scoring_strategy: LinearBlend.new(low_confidence_threshold: 0.5),
        logprob_extractor: fn _decoded -> %{joint_logprob: -0.001, top_logprobs: []} end
      )

    batch = [%{input: "UBER EATS payment", answer: "Food & Drinks/Restaurants"}]

    assert {:ok, result} =
             Confidence.evaluate(adapter, batch, %{"system_prompt" => "Classify."}, true)

    assert result.scores == [1.0]
    assert [%{"accuracy" => 1.0, "probability" => probability}] = result.objective_scores
    assert_in_delta probability, :math.exp(-0.001), 1.0e-8
    assert [%{prediction: "Food & Drinks/Restaurants"}] = result.trajectories
  end

  test "make_reflective_dataset includes actionable feedback" do
    eval_batch = %GEPA.EvaluationBatch{
      outputs: [%{prediction: "wrong"}],
      scores: [0.0],
      trajectories: [
        %{
          input: "x",
          additional_context: %{},
          output: %{prediction: "wrong"},
          prediction: "wrong",
          expected: "right",
          correct?: false,
          probability: 0.2,
          objective_scores: %{"accuracy" => 0.0}
        }
      ]
    }

    assert {:ok, dataset} =
             Confidence.make_reflective_dataset(
               %Confidence{model: fn _ -> "{}" end},
               %{},
               eval_batch,
               ["system_prompt"]
             )

    assert [%{"Feedback" => feedback}] = dataset["system_prompt"]
    assert feedback =~ "Incorrect"
    assert feedback =~ "right"
  end

  describe "upstream JSON extraction parity" do
    test "simple field" do
      text = Jason.encode!(%{category_name: "Bills/Electricity"})

      assert Confidence.extract_answer_from_json(text, "category_name") == "Bills/Electricity"
    end

    test "nested field" do
      text = Jason.encode!(%{classification: %{name: "Shopping"}})

      assert Confidence.extract_answer_from_json(text, "classification.name") == "Shopping"
    end

    test "invalid json returns nil" do
      assert Confidence.extract_answer_from_json("not json", "category") == nil
    end

    test "missing field returns nil" do
      text = Jason.encode!(%{other: "value"})

      assert Confidence.extract_answer_from_json(text, "category") == nil
    end
  end

  describe "upstream feedback parity" do
    test "correct high confidence" do
      assert Confidence.build_feedback(%{
               correct?: true,
               expected: "Bills/Electricity",
               prediction: "Bills/Electricity",
               logprob_score: -0.01,
               top_alternatives: [],
               additional_context: %{},
               high_confidence_prob: 0.99,
               low_confidence_prob: 0.90
             }) == "Correct."
    end

    test "correct medium confidence" do
      feedback =
        Confidence.build_feedback(%{
          correct?: true,
          expected: "Bills/Electricity",
          prediction: "Bills/Electricity",
          logprob_score: -0.05,
          top_alternatives: [],
          additional_context: %{},
          high_confidence_prob: 0.99,
          low_confidence_prob: 0.90
        })

      assert feedback =~ "Correct"
      assert feedback =~ "probability"
    end

    test "correct low confidence lucky guess" do
      feedback =
        Confidence.build_feedback(%{
          correct?: true,
          expected: "Bills/Electricity",
          prediction: "Bills/Electricity",
          logprob_score: -2.3,
          top_alternatives: [
            %{token: "gas", probability: 0.09, resolved_value: "Bills/Gas & Oil"}
          ],
          additional_context: %{},
          high_confidence_prob: 0.99,
          low_confidence_prob: 0.90
        })

      assert feedback =~ "uncertain"
      assert feedback =~ "Bills/Gas & Oil"
    end

    test "incorrect high confidence" do
      feedback =
        Confidence.build_feedback(%{
          correct?: false,
          expected: "Shopping/Video Games",
          prediction: "Shopping/Electronics",
          logprob_score: -0.005,
          top_alternatives: [],
          additional_context: %{},
          high_confidence_prob: 0.99,
          low_confidence_prob: 0.50
        })

      assert feedback =~ "WRONG"
      assert feedback =~ "misleading"
    end

    test "incorrect low confidence" do
      feedback =
        Confidence.build_feedback(%{
          correct?: false,
          expected: "Shopping/Video Games",
          prediction: "Shopping/Electronics",
          logprob_score: -0.80,
          top_alternatives: [
            %{token: "vid", probability: 0.38, resolved_value: "Shopping/Video Games"}
          ],
          additional_context: %{},
          high_confidence_prob: 0.99,
          low_confidence_prob: 0.50
        })

      assert feedback =~ "Wrong"
      assert feedback =~ "Shopping/Video Games"
    end

    test "additional context included on incorrect" do
      feedback =
        Confidence.build_feedback(%{
          correct?: false,
          expected: "Bills/Electricity",
          prediction: "Bills/Gas & Oil",
          logprob_score: -0.60,
          top_alternatives: [],
          additional_context: %{merchant_type: "utility"},
          high_confidence_prob: 0.99,
          low_confidence_prob: 0.50
        })

      assert feedback =~ "merchant_type"
      assert feedback =~ "utility"
    end

    test "nil logprob correct shows correct" do
      assert Confidence.build_feedback(%{
               correct?: true,
               expected: "Food",
               prediction: "Food",
               logprob_score: nil,
               top_alternatives: [],
               additional_context: %{},
               high_confidence_prob: 0.99,
               low_confidence_prob: 0.90
             }) == "Correct."
    end

    test "nil logprob incorrect shows unknown confidence" do
      feedback =
        Confidence.build_feedback(%{
          correct?: false,
          expected: "Food",
          prediction: "Drinks",
          logprob_score: nil,
          top_alternatives: [],
          additional_context: %{},
          high_confidence_prob: 0.99,
          low_confidence_prob: 0.90
        })

      assert feedback =~ "unknown"
    end

    test "parse error shows placeholder" do
      feedback =
        Confidence.build_feedback(%{
          correct?: false,
          expected: "Food",
          prediction: nil,
          logprob_score: nil,
          top_alternatives: [],
          additional_context: %{},
          high_confidence_prob: 0.99,
          low_confidence_prob: 0.90
        })

      assert feedback =~ "<parse error>"
    end

    test "feedback contains probability" do
      feedback =
        Confidence.build_feedback(%{
          correct?: true,
          expected: "Food",
          prediction: "Food",
          logprob_score: -0.22,
          top_alternatives: [],
          additional_context: %{},
          high_confidence_prob: 0.99,
          low_confidence_prob: 0.50
        })

      assert feedback =~ "probability"
    end
  end

  describe "upstream evaluate parity" do
    test "correct high confidence scores one" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor: extractor(-0.001)
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "UBER EATS payment", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert result.scores == [1.0]
      assert [%{"accuracy" => 1.0, "probability" => probability}] = result.objective_scores
      assert_in_delta probability, :math.exp(-0.001), 1.0e-8
    end

    test "correct low confidence is penalized" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Bills/Electricity"})),
          logprob_extractor: extractor(-2.0),
          scoring_strategy:
            LinearBlend.new(low_confidence_threshold: 0.5, min_score_on_correct: 0.3)
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "LIGHT electricity bill", answer: "Bills/Electricity"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert hd(result.scores) < 1.0
      assert hd(result.scores) > 0.0
    end

    test "incorrect scores zero" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Shopping/Electronics"})),
          logprob_extractor: extractor(-0.22)
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "UBER EATS payment", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert result.scores == [0.0]
      [objective_scores] = result.objective_scores
      assert objective_scores["accuracy"] == 0.0
    end

    test "llm error returns failure score" do
      adapter =
        confidence_adapter(
          model: fn _prompt -> raise "API timeout" end,
          failure_score: 0.0
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert result.scores == [0.0]
      assert Map.get(hd(result.outputs), :parsed_value) == nil
    end

    test "capture traces populates trajectories" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor:
            extractor(-0.16, [
              %{token: "food", probability: 0.85, resolved_value: "Food & Drinks/Restaurants"}
            ])
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "UBER EATS", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 true
               )

      assert [trajectory] = result.trajectories
      assert trajectory.is_correct
      assert_in_delta trajectory.logprob_score, -0.16, 1.0e-12
      assert trajectory.parsed_value == "Food & Drinks/Restaurants"
      assert length(trajectory.top_alternatives) == 1
    end

    test "no traces when capture traces false" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor: extractor(-0.1)
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert result.trajectories == nil
    end

    test "logprob extraction failure degrades gracefully" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor: fn _decoded -> raise "logprob extraction error" end
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert result.scores == [1.0]
      assert Map.get(hd(result.outputs), :logprob_score) == nil
    end

    test "multiple examples in batch" do
      adapter =
        confidence_adapter(
          model:
            sequence_model([
              Jason.encode!(%{category_name: "Food & Drinks/Restaurants"}),
              Jason.encode!(%{category_name: "Bills/Electricity"})
            ]),
          logprob_extractor: sequence_extractor([-0.001, -0.001])
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 sample_batch(),
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert length(result.scores) == 2
      assert length(result.outputs) == 2
      assert result.scores == [1.0, 1.0]
    end

    test "threshold strategy gates on logprob" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor: extractor(-0.51),
          scoring_strategy: Threshold.new(threshold: 0.7)
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert result.scores == [0.0]
    end

    test "callable model supported" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      on_exit(fn ->
        if Process.alive?(calls), do: Agent.stop(calls)
      end)

      model = fn prompt ->
        Agent.update(calls, &[prompt | &1])
        Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})
      end

      adapter =
        confidence_adapter(
          model: model,
          logprob_extractor: extractor(-0.001)
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert [_prompt] = Agent.get(calls, & &1)
      assert result.scores == [1.0]
    end

    test "case insensitive correctness" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "food & drinks/restaurants"})),
          logprob_extractor: extractor(-0.001)
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert result.scores == [1.0]
    end

    test "objective scores contain accuracy and probability" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor: extractor(-0.35)
        )

      assert {:ok, result} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      [objective_scores] = result.objective_scores
      assert Map.has_key?(objective_scores, "accuracy")
      assert Map.has_key?(objective_scores, "probability")
      assert_in_delta objective_scores["probability"], :math.exp(-0.35), 1.0e-8
    end
  end

  describe "upstream reflective dataset parity" do
    test "reflective dataset structure" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor:
            extractor(-1.05, [
              %{token: "elec", probability: 0.30, resolved_value: "Shopping/Electronics"}
            ])
        )

      assert {:ok, eval_batch} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "UBER EATS", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 true
               )

      assert {:ok, dataset} =
               Confidence.make_reflective_dataset(
                 adapter,
                 %{"system_prompt" => "Classify."},
                 eval_batch,
                 ["system_prompt"]
               )

      assert [%{"Inputs" => _, "Generated Outputs" => _, "Feedback" => _}] =
               dataset["system_prompt"]
    end

    test "reflective feedback includes confidence info" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Bills/Electricity"})),
          logprob_extractor:
            extractor(-1.14, [
              %{token: "gas", probability: 0.09, resolved_value: "Bills/Gas & Oil"}
            ])
        )

      assert {:ok, eval_batch} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "LIGHT electricity bill", answer: "Bills/Electricity"}],
                 %{"system_prompt" => "Classify."},
                 true
               )

      assert {:ok, dataset} =
               Confidence.make_reflective_dataset(
                 adapter,
                 %{"system_prompt" => "Classify."},
                 eval_batch,
                 ["system_prompt"]
               )

      feedback = dataset["system_prompt"] |> hd() |> Map.fetch!("Feedback")
      assert feedback =~ "probability"
      assert feedback =~ "Bills/Gas & Oil"
    end

    test "generated outputs include probability" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor: extractor(-0.16)
        )

      assert {:ok, eval_batch} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 true
               )

      assert {:ok, dataset} =
               Confidence.make_reflective_dataset(
                 adapter,
                 %{"system_prompt" => "Classify."},
                 eval_batch,
                 ["system_prompt"]
               )

      generated = dataset["system_prompt"] |> hd() |> Map.fetch!("Generated Outputs")
      assert Map.has_key?(generated, :probability)
    end

    test "returns error when no trajectories" do
      adapter =
        confidence_adapter(
          model: static_model(Jason.encode!(%{category_name: "Food & Drinks/Restaurants"})),
          logprob_extractor: extractor(-0.1)
        )

      assert {:ok, eval_batch} =
               Confidence.evaluate(
                 adapter,
                 [%{input: "test", answer: "Food & Drinks/Restaurants"}],
                 %{"system_prompt" => "Classify."},
                 false
               )

      assert {:error, :missing_trajectories} =
               Confidence.make_reflective_dataset(
                 adapter,
                 %{"system_prompt" => "Classify."},
                 eval_batch,
                 ["system_prompt"]
               )
    end
  end

  defp confidence_adapter(opts) do
    opts
    |> Keyword.put_new(:field_path, "category_name")
    |> Confidence.new()
  end

  defp static_model(content), do: fn _prompt -> content end

  defp extractor(logprob, top_alternatives \\ []) do
    fn _decoded ->
      %{joint_logprob: logprob, top_logprobs: top_alternatives}
    end
  end

  defp sequence_model(contents) do
    {:ok, agent} = Agent.start_link(fn -> contents end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    fn _prompt ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> raise "no model responses left"
      end)
    end
  end

  defp sequence_extractor(logprobs) do
    {:ok, agent} = Agent.start_link(fn -> logprobs end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    fn _decoded ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {%{joint_logprob: next, top_logprobs: []}, rest}
        [] -> raise "no logprobs left"
      end)
    end
  end

  defp sample_batch do
    [
      %{input: "UBER EATS payment", additional_context: %{}, answer: "Food & Drinks/Restaurants"},
      %{
        input: "LIGHT electricity bill",
        additional_context: %{merchant_type: "utility"},
        answer: "Bills/Electricity"
      }
    ]
  end
end
