defmodule GEPA.OfficialApiValidationTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  defmodule ProposingAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def evaluate(_adapter, batch, _candidate, capture_traces) do
      {:ok,
       %GEPA.EvaluationBatch{
         outputs: batch,
         scores: Enum.map(batch, fn _ -> 0.5 end),
         trajectories: if(capture_traces, do: batch)
       }}
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _eval_batch, components) do
      {:ok, Map.new(components, &{&1, [%{"Feedback" => "adapter feedback"}]})}
    end

    @impl true
    def propose_new_texts(_adapter, candidate, _dataset, components) do
      {:ok, Map.new(components, &{&1, Map.get(candidate, &1, "") <> " updated"})}
    end
  end

  test "user adapter is mutually exclusive with task_lm/model and evaluator" do
    assert_raise ArgumentError, ~r/task_lm|model/, fn ->
      GEPA.optimize(
        seed_candidate: %{"instruction" => "seed"},
        trainset: [%{input: "Q", answer: "A"}],
        adapter: ProposingAdapter.new(),
        task_lm: fn _messages -> "answer" end,
        max_metric_calls: 1
      )
    end

    assert_raise ArgumentError, ~r/evaluator/, fn ->
      GEPA.optimize(
        seed_candidate: %{"instruction" => "seed"},
        trainset: [%{input: "Q", answer: "A"}],
        adapter: ProposingAdapter.new(),
        evaluator: fn _candidate -> 1.0 end,
        max_metric_calls: 1
      )
    end
  end

  test "adapter proposal hook owns proposal generation" do
    assert_raise ArgumentError, ~r/custom_candidate_proposer/, fn ->
      GEPA.optimize(
        seed_candidate: %{"instruction" => "seed"},
        trainset: [%{input: "Q", answer: "A"}],
        adapter: ProposingAdapter.new(),
        custom_candidate_proposer: fn candidate, _dataset, components ->
          Map.take(candidate, components)
        end,
        max_metric_calls: 1
      )
    end

    assert_raise ArgumentError, ~r/proposal_template|reflection_prompt_template/, fn ->
      GEPA.optimize(
        seed_candidate: %{"instruction" => "seed"},
        trainset: [%{input: "Q", answer: "A"}],
        adapter: ProposingAdapter.new(),
        proposal_template: "Current: {current_instruction}",
        max_metric_calls: 1
      )
    end
  end
end
