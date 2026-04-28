defmodule GEPA.ParetoFrontierTypesTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Adapters.Default
  alias GEPA.Result

  test "optimize supports objective, hybrid, and instance frontier types with objective scores" do
    for frontier_type <- [:objective, :hybrid, :instance] do
      assert {:ok, result} =
               GEPA.optimize(
                 seed_candidate: %{"system_prompt" => "You are a helpful assistant."},
                 trainset: examples(),
                 valset: examples(),
                 adapter: Default.new(model: &task_lm/1, evaluator: &evaluator/2),
                 reflection_lm: &reflection_lm/1,
                 frontier_type: frontier_type,
                 max_metric_calls: 12,
                 reflection_minibatch_size: 2,
                 skip_perfect_score: false
               )

      assert result.total_num_evals > 0
      assert is_binary(Result.best_candidate(result)["system_prompt"])
      assert [%{"quality" => quality, "leakage" => leakage} | _] = result.val_aggregate_subscores
      assert is_number(quality)
      assert is_number(leakage)
      assert %{"quality" => _, "leakage" => _} = result.objective_pareto_front
    end
  end

  defp examples do
    for i <- 1..4 do
      %{
        "input" => "Please redact secret#{i} from query #{i}.",
        "answer" => "redacted #{i}",
        "additional_context" => %{"pii_units" => "secret#{i}||token#{i}"}
      }
    end
  end

  defp task_lm(messages) do
    user_message = List.last(messages).content
    [idx] = Regex.run(~r/query (\d+)/, user_message, capture: :all_but_first)
    "redacted #{idx}"
  end

  defp reflection_lm(_prompt),
    do: "```\nRedact each requested secret and return only the redacted answer.\n```"

  defp evaluator(data, response) do
    quality = if String.contains?(response, data["answer"]), do: 1.0, else: 0.0

    pii_units =
      data
      |> get_in(["additional_context", "pii_units"])
      |> String.split("||", trim: true)

    leaked = Enum.count(pii_units, &String.contains?(response, &1))
    leakage = if pii_units == [], do: 1.0, else: 1.0 - leaked / length(pii_units)
    score = (quality + leakage) / 2

    {score, "quality=#{quality}; leakage=#{leakage}",
     %{"quality" => quality, "leakage" => leakage}}
  end
end
