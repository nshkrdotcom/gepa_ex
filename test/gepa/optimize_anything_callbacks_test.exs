defmodule GEPA.OptimizeAnythingCallbacksTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.OptimizeAnything

  defmodule Recorder do
    defstruct [:pid]

    def on_optimization_start(%__MODULE__{pid: pid}, _event),
      do: send(pid, {:oa_callback, :optimization_start})

    def on_iteration_start(%__MODULE__{pid: pid}, _event),
      do: send(pid, {:oa_callback, :iteration_start})

    def on_iteration_end(%__MODULE__{pid: pid}, _event),
      do: send(pid, {:oa_callback, :iteration_end})

    def on_optimization_end(%__MODULE__{pid: pid}, _event),
      do: send(pid, {:oa_callback, :optimization_end})
  end

  defmodule Counter do
    defstruct [:pid, :id]

    def on_iteration_end(%__MODULE__{pid: pid, id: id}, _event),
      do: send(pid, {:oa_callback, id, :iteration_end})
  end

  defmodule ProposalRecorder do
    defstruct [:pid]

    def on_proposal_start(%__MODULE__{pid: pid}, _event),
      do: send(pid, {:oa_callback, :proposal_start})

    def on_proposal_end(%__MODULE__{pid: pid}, _event),
      do: send(pid, {:oa_callback, :proposal_end})
  end

  test "callbacks receive optimize_anything lifecycle events" do
    assert {:ok, result} = optimize_with_callbacks([%Recorder{pid: self()}])

    events = drain_events()

    assert %GEPA.Result{} = result
    assert :optimization_start in events
    assert :iteration_start in events
    assert :iteration_end in events
    assert :optimization_end in events
  end

  test "multiple optimize_anything callbacks all receive events" do
    assert {:ok, _result} =
             optimize_with_callbacks([
               %Counter{pid: self(), id: :first},
               %Counter{pid: self(), id: :second}
             ])

    events = drain_events()
    first_count = Enum.count(events, &(&1 == {:first, :iteration_end}))
    second_count = Enum.count(events, &(&1 == {:second, :iteration_end}))

    assert first_count > 0
    assert first_count == second_count
  end

  test "optimize_anything works without callbacks by default" do
    assert {:ok, result} =
             OptimizeAnything.optimize_anything(
               seed_candidate: "x",
               evaluator: &good_evaluator/1,
               engine: %{max_metric_calls: 3, reflection_minibatch_size: 1},
               reflection: %{reflection_lm: &mock_lm/1}
             )

    assert %GEPA.Result{} = result
  end

  test "optimize_anything callbacks receive proposal events" do
    assert {:ok, _result} = optimize_with_callbacks([%ProposalRecorder{pid: self()}])

    events = drain_events()

    assert :proposal_start in events
    assert :proposal_end in events
  end

  defp optimize_with_callbacks(callbacks) do
    OptimizeAnything.optimize_anything(
      seed_candidate: "x",
      evaluator: &good_evaluator/1,
      callbacks: callbacks,
      engine: %{max_metric_calls: 5, reflection_minibatch_size: 1},
      reflection: %{reflection_lm: &mock_lm/1}
    )
  end

  defp good_evaluator(_candidate), do: {0.5, %{}}
  defp mock_lm(_prompt), do: "```\ncandidate\n```"

  defp drain_events(acc \\ []) do
    receive do
      {:oa_callback, event} -> drain_events([event | acc])
      {:oa_callback, id, event} -> drain_events([{id, event} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
