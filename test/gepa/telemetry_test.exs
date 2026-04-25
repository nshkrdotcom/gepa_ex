defmodule GEPA.TelemetryTest do
  use GEPA.SupertesterCase, isolation: :full_isolation, async: false

  alias GEPA.DataLoader.List, as: ListLoader
  alias GEPA.StopCondition.MaxCalls
  alias GEPA.Strategies.CandidateSelector.CurrentBest
  alias GEPA.Telemetry

  defmodule TelemetryTestAdapter do
    @moduledoc false
    defstruct []

    def new, do: %__MODULE__{}

    def evaluate(_adapter, batch, candidate, capture_traces) do
      score =
        if String.contains?(Map.get(candidate, "instruction", ""), "[Optimized]") do
          1.0
        else
          0.2
        end

      scores = Enum.map(batch, fn _ -> score end)
      outputs = Enum.map(batch, fn _ -> "out" end)

      trajectories =
        if capture_traces do
          Enum.map(batch, fn _ -> %{score: score, input: :train} end)
        else
          nil
        end

      {:ok,
       %GEPA.EvaluationBatch{
         outputs: outputs,
         scores: scores,
         trajectories: trajectories
       }}
    end

    def make_reflective_dataset(_adapter, candidate, eval_batch, components) do
      dataset =
        for component <- components, into: %{} do
          items =
            Enum.map(eval_batch.scores, fn score ->
              %{
                "Inputs" => %{},
                "Generated Outputs" => candidate[component],
                "Feedback" => "score=#{score}"
              }
            end)

          {component, items}
        end

      {:ok, dataset}
    end

    def propose_new_texts(_adapter, candidate, _reflective_dataset, components) do
      {:ok, Map.new(components, &{&1, candidate[&1] <> " [Optimized]"})}
    end
  end

  setup do
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

    events = [
      [:gepa, :run, :start],
      [:gepa, :run, :stop],
      [:gepa, :baseline, :computed],
      [:gepa, :iteration, :start],
      [:gepa, :iteration, :stop],
      [:gepa, :proposal, :generated],
      [:gepa, :proposal, :decision],
      [:gepa, :valset, :update],
      [:gepa, :evaluation, :batch]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(self(), {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "emits lifecycle, schema, and baseline events" do
    {:ok, _} = run_engine(max_calls: 6)

    events = collect_events()

    run_start = fetch_event(events, [:gepa, :run, :start])
    assert run_start.meta.schema_version == Telemetry.schema_version()
    assert run_start.meta.config[:trainset] == "[DataLoader]"
    assert run_start.meta.config[:valset] == "[DataLoader]"
    assert run_start.meta.config[:adapter] == "[Adapter]"

    baseline = fetch_event(events, [:gepa, :baseline, :computed])
    assert baseline.meas.iteration == 0
    assert baseline.meas.base_program_full_valset_score >= 0.0

    run_stop = fetch_event(events, [:gepa, :run, :stop])
    assert run_stop.meas.iterations >= 0
    assert run_stop.meas.total_metric_calls > 0
    assert run_stop.meas.best_score >= 0.0
  end

  test "emits iteration, proposal, and valset updates with acceptance" do
    {:ok, _} = run_engine(max_calls: 8)

    events = collect_events()

    iter_start = fetch_event(events, [:gepa, :iteration, :start])
    assert iter_start.meas.iteration == 1
    assert iter_start.meta.selected_program_candidate == 0

    proposal_gen = fetch_event(events, [:gepa, :proposal, :generated])
    assert proposal_gen.meas.subsample_after_sum > proposal_gen.meas.subsample_before_sum
    assert proposal_gen.meta.tag == "reflective_mutation"

    decision = fetch_event(events, [:gepa, :proposal, :decision])
    assert decision.meas.accepted == true
    assert decision.meta.reason == :accepted

    valset = fetch_event(events, [:gepa, :valset, :update])
    assert valset.meas.val_program_average > 0.0
    assert is_integer(valset.meta.new_program_idx)

    iter_stop = fetch_event(events, [:gepa, :iteration, :stop])
    assert iter_stop.meas.iteration_duration_ms >= 0
    assert iter_stop.meas.proposal_accepted in [true, false]

    run_stop = fetch_event(events, [:gepa, :run, :stop])
    assert run_stop.meas.best_score >= valset.meas.val_program_average
  end

  # Helpers

  defp run_engine(opts) do
    trainset = ListLoader.new([%{input: "t", answer: "a"}])
    valset = ListLoader.new([%{input: "v", answer: "a"}])

    config = %{
      seed_candidate: %{"instruction" => "base"},
      trainset: trainset,
      valset: valset,
      adapter: TelemetryTestAdapter.new(),
      candidate_selector: CurrentBest,
      stop_conditions: [MaxCalls.new(opts[:max_calls])],
      reflection_minibatch_size: 1,
      perfect_score: 1.0,
      skip_perfect_score: false,
      seed: 123,
      run_dir: nil
    }

    GEPA.Engine.run(config)
  end

  defp collect_events(acc \\ []) do
    receive do
      {:event, event, measurements, metadata} ->
        collect_events([{event, measurements, metadata} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp fetch_event(events, name) do
    case Enum.find(events, fn {event_name, _, _} -> event_name == name end) do
      {^name, meas, meta} ->
        %{event: name, meas: meas, meta: meta}

      nil ->
        flunk(
          "Expected event #{inspect(name)} not found. Seen: #{inspect(Enum.map(events, &elem(&1, 0)))}"
        )
    end
  end
end
