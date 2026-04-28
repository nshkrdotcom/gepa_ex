defmodule GEPA.CallbacksUpstreamTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GEPA.Callbacks.Composite

  defmodule Recorder do
    defstruct [:pid]

    for event_name <- [
          :optimization_start,
          :optimization_end,
          :iteration_start,
          :iteration_end,
          :candidate_selected,
          :minibatch_sampled,
          :evaluation_start,
          :evaluation_end,
          :evaluation_skipped,
          :reflective_dataset_built,
          :proposal_start,
          :proposal_end,
          :candidate_accepted,
          :candidate_rejected,
          :merge_attempted,
          :merge_accepted,
          :merge_rejected,
          :pareto_front_updated,
          :state_saved,
          :budget_updated,
          :error,
          :valset_evaluated
        ] do
      method_name = String.to_atom("on_#{event_name}")

      def unquote(method_name)(%__MODULE__{pid: pid}, event) do
        send(pid, {:callback, unquote(method_name), event})
      end
    end
  end

  defmodule EmptyCallback do
    defstruct []
  end

  defmodule PartialCallback do
    defstruct [:pid]

    def on_optimization_start(%__MODULE__{pid: pid}, event) do
      send(pid, {:callback, :on_optimization_start, event})
    end
  end

  defmodule FailingCallback do
    defstruct [:fail_on]

    def on_optimization_start(%__MODULE__{fail_on: :on_optimization_start}, _event) do
      raise ArgumentError, "Intentional failure"
    end

    def on_iteration_start(%__MODULE__{fail_on: :on_iteration_start}, _event) do
      raise ArgumentError, "Intentional failure"
    end
  end

  defmodule OptimizingAdapter do
    @behaviour GEPA.Adapter

    defstruct []

    def new, do: %__MODULE__{}

    @impl true
    def evaluate(_adapter, batch, candidate, capture_traces) do
      improved? = String.contains?(Map.get(candidate, "instruction", ""), "improved")
      score = if improved?, do: 1.0, else: 0.25

      trajectories =
        if capture_traces do
          Enum.map(batch, fn example ->
            %{input: example.input, output: "answer", feedback: "score=#{score}"}
          end)
        end

      {:ok,
       %GEPA.EvaluationBatch{
         outputs: Enum.map(batch, fn _ -> "answer" end),
         scores: Enum.map(batch, fn _ -> score end),
         trajectories: trajectories,
         num_metric_calls: length(batch)
       }}
    end

    @impl true
    def make_reflective_dataset(_adapter, candidate, eval_batch, components) do
      {:ok,
       Map.new(components, fn component ->
         rows =
           Enum.map(eval_batch.trajectories, fn trajectory ->
             %{
               "Inputs" => %{"input" => trajectory.input},
               "Generated Outputs" => Map.get(candidate, component),
               "Feedback" => trajectory.feedback
             }
           end)

         {component, rows}
       end)}
    end

    @impl true
    def propose_new_texts(_adapter, candidate, _reflective_dataset, components) do
      new_texts = Map.new(components, &{&1, Map.get(candidate, &1, "") <> " improved"})
      prompts = Map.new(components, &{&1, "Improve #{&1}"})
      raw_outputs = Map.new(components, &{&1, Map.fetch!(new_texts, &1)})

      {:ok, new_texts, prompts, raw_outputs}
    end
  end

  defmodule PartialRuntimeCallback do
    defstruct [:pid]

    def on_iteration_start(%__MODULE__{pid: pid}, event) do
      send(pid, {:partial_runtime, :iteration_start, event.iteration})
    end

    def on_budget_updated(%__MODULE__{pid: pid}, event) do
      send(pid, {:partial_runtime, :budget_updated, event.metric_calls_used})
    end
  end

  test "callbacks may implement upstream-style on_* methods" do
    callback = %Recorder{pid: self()}

    assert :ok = GEPA.Callbacks.notify([callback], :iteration_end, %{iteration: 7})
    assert_receive {:callback, :on_iteration_end, %{iteration: 7}}
  end

  test "callback protocol is runtime checkable" do
    callback = %Recorder{pid: self()}

    assert function_exported?(GEPA.Callbacks, :notify, 3)
    assert :ok = GEPA.Callbacks.notify([callback], "on_optimization_start", %{config: %{}})
    assert_receive {:callback, :on_optimization_start, %{config: %{}}}
  end

  test "empty callback implementation is ignored" do
    assert :ok =
             GEPA.Callbacks.notify([%EmptyCallback{}], :optimization_start, %{
               seed_candidate: %{},
               trainset_size: 0,
               valset_size: 0,
               config: %{}
             })
  end

  test "partial callback implementation receives implemented methods and ignores missing ones" do
    callback = %PartialCallback{pid: self()}

    assert :ok =
             GEPA.Callbacks.notify([callback], :optimization_start, %{
               seed_candidate: %{},
               trainset_size: 10,
               valset_size: 5,
               config: %{}
             })

    assert_receive {:callback, :on_optimization_start, %{trainset_size: 10}}
    assert :ok = GEPA.Callbacks.notify([callback], :iteration_start, %{iteration: 1, state: nil})
  end

  test "on_optimization_start called with correct args" do
    callback = %Recorder{pid: self()}

    event = %{
      seed_candidate: %{"instructions" => "test"},
      trainset_size: 100,
      valset_size: 20,
      config: %{max_metric_calls: 500}
    }

    assert :ok = GEPA.Callbacks.notify([callback], :optimization_start, event)
    assert_receive {:callback, :on_optimization_start, ^event}
  end

  test "on_optimization_end called with final state" do
    callback = %Recorder{pid: self()}
    state = %{done: true}

    event = %{
      best_candidate_idx: 3,
      total_iterations: 50,
      total_metric_calls: 450,
      final_state: state
    }

    assert :ok = GEPA.Callbacks.notify([callback], :optimization_end, event)
    assert_receive {:callback, :on_optimization_end, ^event}
  end

  test "on_iteration_start called with correct args" do
    callback = %Recorder{pid: self()}
    event = %{iteration: 5, state: %{i: 4}}

    assert :ok = GEPA.Callbacks.notify([callback], :iteration_start, event)
    assert_receive {:callback, :on_iteration_start, ^event}
  end

  test "on_iteration_end called with outcome" do
    callback = %Recorder{pid: self()}

    assert :ok =
             GEPA.Callbacks.notify([callback], :iteration_end, %{
               iteration: 5,
               state: %{},
               proposal_accepted: true
             })

    assert :ok =
             GEPA.Callbacks.notify([callback], :iteration_end, %{
               iteration: 6,
               state: %{},
               proposal_accepted: false
             })

    assert_receive {:callback, :on_iteration_end, %{proposal_accepted: true}}
    assert_receive {:callback, :on_iteration_end, %{proposal_accepted: false}}
  end

  test "on_candidate_selected called with selection info" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 3,
      candidate_idx: 2,
      candidate: %{"instructions" => "selected"},
      score: 0.85
    }

    assert :ok = GEPA.Callbacks.notify([callback], :candidate_selected, event)
    assert_receive {:callback, :on_candidate_selected, ^event}
  end

  test "on_minibatch_sampled called with ids" do
    callback = %Recorder{pid: self()}
    event = %{iteration: 3, minibatch_ids: [0, 5, 12, 23, 45], trainset_size: 100}

    assert :ok = GEPA.Callbacks.notify([callback], :minibatch_sampled, event)
    assert_receive {:callback, :on_minibatch_sampled, ^event}
  end

  test "on_candidate_accepted called on improvement" do
    callback = %Recorder{pid: self()}
    event = %{iteration: 5, new_candidate_idx: 3, new_score: 0.92, parent_ids: [1]}

    assert :ok = GEPA.Callbacks.notify([callback], :candidate_accepted, event)
    assert_receive {:callback, :on_candidate_accepted, ^event}
  end

  test "on_candidate_rejected called on no improvement" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 5,
      old_score: 0.85,
      new_score: 0.80,
      reason: "New subsample score not better than old"
    }

    assert :ok = GEPA.Callbacks.notify([callback], :candidate_rejected, event)
    assert_receive {:callback, :on_candidate_rejected, %{reason: reason}}
    assert reason =~ "not better"
  end

  test "on_evaluation_start called with batch info" do
    callback = %Recorder{pid: self()}
    inputs = [%{question: "What is 2+2?"}, %{question: "What is 3+3?"}]

    event = %{
      iteration: 3,
      candidate_idx: 1,
      batch_size: 35,
      capture_traces: true,
      parent_ids: [0],
      inputs: inputs,
      is_seed_candidate: false
    }

    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_start, event)
    assert_receive {:callback, :on_evaluation_start, ^event}
  end

  test "on_evaluation_end scores are list of floats" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 3,
      candidate_idx: 1,
      scores: [0.8, 0.9, 1.0, 0.7, 0.85],
      has_trajectories: true,
      parent_ids: [0],
      outputs: ["answer1", "answer2", "answer3", "answer4", "answer5"],
      trajectories: [%{trace: "t1"}, %{trace: "t2"}],
      objective_scores: [%{"accuracy" => 0.8}],
      is_seed_candidate: false
    }

    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_end, event)
    assert_receive {:callback, :on_evaluation_end, received}
    assert Enum.all?(received.scores, &is_float/1)
    assert received.has_trajectories
    assert received.outputs == event.outputs
    assert received.objective_scores == event.objective_scores
  end

  test "on_evaluation_start with new candidate" do
    callback = %Recorder{pid: self()}
    inputs = [%{q: "test"}]

    event = %{
      iteration: 5,
      candidate_idx: nil,
      batch_size: 10,
      capture_traces: false,
      parent_ids: [3],
      inputs: inputs,
      is_seed_candidate: false
    }

    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_start, event)
    assert_receive {:callback, :on_evaluation_start, ^event}
  end

  test "on_evaluation with merge parents" do
    callback = %Recorder{pid: self()}
    inputs = for index <- 0..4, do: %{q: "q#{index}"}
    outputs = for index <- 0..4, do: "out#{index}"

    start_event = %{
      iteration: 10,
      candidate_idx: nil,
      batch_size: 5,
      capture_traces: false,
      parent_ids: [2, 7],
      inputs: inputs,
      is_seed_candidate: false
    }

    end_event = %{
      iteration: 10,
      candidate_idx: nil,
      scores: [0.9, 0.85, 0.95, 0.88, 0.92],
      has_trajectories: false,
      parent_ids: [2, 7],
      outputs: outputs,
      trajectories: nil,
      objective_scores: nil,
      is_seed_candidate: false
    }

    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_start, start_event)
    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_end, end_event)
    assert_receive {:callback, :on_evaluation_start, ^start_event}
    assert_receive {:callback, :on_evaluation_end, ^end_event}
  end

  test "on_evaluation with seed candidate" do
    callback = %Recorder{pid: self()}
    inputs = for index <- 0..19, do: %{seed_input: index}

    event = %{
      iteration: 1,
      candidate_idx: 0,
      batch_size: 20,
      capture_traces: true,
      parent_ids: [],
      inputs: inputs,
      is_seed_candidate: true
    }

    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_start, event)
    assert_receive {:callback, :on_evaluation_start, ^event}
  end

  test "on_evaluation_skipped no trajectories" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 3,
      candidate_idx: 1,
      reason: :no_trajectories,
      scores: [0.8, 0.9, 0.7],
      is_seed_candidate: false
    }

    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_skipped, event)
    assert_receive {:callback, :on_evaluation_skipped, ^event}
  end

  test "on_evaluation_skipped perfect scores" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 5,
      candidate_idx: 2,
      reason: :all_scores_perfect,
      scores: [1.0, 1.0, 1.0, 1.0],
      is_seed_candidate: false
    }

    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_skipped, event)
    assert_receive {:callback, :on_evaluation_skipped, ^event}
  end

  test "on_evaluation_skipped with nil scores" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 4,
      candidate_idx: 0,
      reason: :no_trajectories,
      scores: nil,
      is_seed_candidate: true
    }

    assert :ok = GEPA.Callbacks.notify([callback], :evaluation_skipped, event)
    assert_receive {:callback, :on_evaluation_skipped, ^event}
  end

  test "on_reflective_dataset_built called with dataset" do
    callback = %Recorder{pid: self()}

    dataset = %{
      "predictor" => [
        %{
          "Inputs" => %{"question" => "What is 2+2?"},
          "Generated Outputs" => %{"answer" => "5"},
          "Feedback" => "Incorrect"
        }
      ]
    }

    event = %{iteration: 3, candidate_idx: 1, components: ["predictor"], dataset: dataset}

    assert :ok = GEPA.Callbacks.notify([callback], :reflective_dataset_built, event)
    assert_receive {:callback, :on_reflective_dataset_built, %{dataset: received}}
    assert get_in(received, ["predictor", Access.at(0), "Inputs"])
    assert get_in(received, ["predictor", Access.at(0), "Feedback"])
  end

  test "on_proposal_start and end called with instructions" do
    callback = %Recorder{pid: self()}

    start_event = %{
      iteration: 3,
      parent_candidate: %{"instructions" => "Original"},
      components: ["instructions"],
      reflective_dataset: %{"instructions" => []}
    }

    end_event = %{
      iteration: 3,
      new_instructions: %{"instructions" => "Improved"},
      prompts: %{"instructions" => "Reflect"},
      raw_lm_outputs: %{"instructions" => "```\nImproved\n```"}
    }

    assert :ok = GEPA.Callbacks.notify([callback], :proposal_start, start_event)
    assert :ok = GEPA.Callbacks.notify([callback], :proposal_end, end_event)
    assert_receive {:callback, :on_proposal_start, ^start_event}
    assert_receive {:callback, :on_proposal_end, ^end_event}
  end

  test "on_merge_attempted called with parents" do
    callback = %Recorder{pid: self()}
    event = %{iteration: 10, parent_ids: [1, 3], merged_candidate: %{"instructions" => "merged"}}

    assert :ok = GEPA.Callbacks.notify([callback], :merge_attempted, event)
    assert_receive {:callback, :on_merge_attempted, ^event}
  end

  test "on_merge_accepted called on improvement" do
    callback = %Recorder{pid: self()}
    event = %{iteration: 10, new_candidate_idx: 5, parent_ids: [1, 3]}

    assert :ok = GEPA.Callbacks.notify([callback], :merge_accepted, event)
    assert_receive {:callback, :on_merge_accepted, ^event}
  end

  test "on_merge_rejected called on failure" do
    callback = %Recorder{pid: self()}
    event = %{iteration: 10, parent_ids: [1, 3], reason: "Merged score worse than both parents"}

    assert :ok = GEPA.Callbacks.notify([callback], :merge_rejected, event)
    assert_receive {:callback, :on_merge_rejected, %{reason: reason}}
    assert reason =~ "worse"
  end

  test "on_pareto_front_updated called with changes" do
    callback = %Recorder{pid: self()}
    event = %{iteration: 5, new_front: [0, 2, 4], displaced_candidates: [1]}

    assert :ok = GEPA.Callbacks.notify([callback], :pareto_front_updated, event)
    assert_receive {:callback, :on_pareto_front_updated, ^event}
  end

  test "on_state_saved called with run_dir" do
    callback = %Recorder{pid: self()}
    event = %{iteration: 5, run_dir: "/tmp/gepa_run_123"}

    assert :ok = GEPA.Callbacks.notify([callback], :state_saved, event)
    assert_receive {:callback, :on_state_saved, ^event}
  end

  test "on_budget_updated tracks remaining calls" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 5,
      metric_calls_used: 150,
      metric_calls_delta: 10,
      metric_calls_remaining: 350
    }

    assert :ok = GEPA.Callbacks.notify([callback], :budget_updated, event)
    assert_receive {:callback, :on_budget_updated, ^event}
  end

  test "on_valset_evaluated called with correct args" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 5,
      candidate_idx: 3,
      candidate: %{"instructions" => "test"},
      scores_by_val_id: %{"val_0" => 0.8, "val_1" => 0.9, "val_2" => 0.7},
      average_score: 0.8,
      num_examples_evaluated: 3,
      total_valset_size: 10,
      parent_ids: [1],
      is_best_program: true,
      outputs_by_val_id: %{"val_0" => "output_0", "val_1" => "output_1", "val_2" => "output_2"}
    }

    assert :ok = GEPA.Callbacks.notify([callback], :valset_evaluated, event)
    assert_receive {:callback, :on_valset_evaluated, ^event}
  end

  test "on_valset_evaluated with seed candidate" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 1,
      candidate_idx: 0,
      candidate: %{"instructions" => "seed"},
      scores_by_val_id: %{0 => 0.5, 1 => 0.6},
      average_score: 0.55,
      num_examples_evaluated: 2,
      total_valset_size: 2,
      parent_ids: [],
      is_best_program: true,
      outputs_by_val_id: %{0 => "out_0", 1 => "out_1"}
    }

    assert :ok = GEPA.Callbacks.notify([callback], :valset_evaluated, event)
    assert_receive {:callback, :on_valset_evaluated, ^event}
  end

  test "on_valset_evaluated with mutation" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 3,
      candidate_idx: 2,
      candidate: %{"instructions" => "mutated"},
      scores_by_val_id: %{0 => 0.7, 1 => 0.8},
      average_score: 0.75,
      num_examples_evaluated: 2,
      total_valset_size: 5,
      parent_ids: [1],
      is_best_program: false,
      outputs_by_val_id: %{0 => "out_0", 1 => "out_1"}
    }

    assert :ok = GEPA.Callbacks.notify([callback], :valset_evaluated, event)
    assert_receive {:callback, :on_valset_evaluated, ^event}
  end

  test "on_valset_evaluated with merge" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 10,
      candidate_idx: 5,
      candidate: %{"instructions" => "merged"},
      scores_by_val_id: %{"a" => 0.9, "b" => 0.85},
      average_score: 0.875,
      num_examples_evaluated: 2,
      total_valset_size: 2,
      parent_ids: [2, 4],
      is_best_program: true,
      outputs_by_val_id: %{"a" => "out_a", "b" => "out_b"}
    }

    assert :ok = GEPA.Callbacks.notify([callback], :valset_evaluated, event)
    assert_receive {:callback, :on_valset_evaluated, ^event}
  end

  test "on_valset_evaluated with nil outputs" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 2,
      candidate_idx: 1,
      candidate: %{"instructions" => "test"},
      scores_by_val_id: %{0 => 0.6},
      average_score: 0.6,
      num_examples_evaluated: 1,
      total_valset_size: 5,
      parent_ids: [0],
      is_best_program: false,
      outputs_by_val_id: nil
    }

    assert :ok = GEPA.Callbacks.notify([callback], :valset_evaluated, event)
    assert_receive {:callback, :on_valset_evaluated, ^event}
  end

  test "on_valset_evaluated partial coverage" do
    callback = %Recorder{pid: self()}

    event = %{
      iteration: 4,
      candidate_idx: 3,
      candidate: %{"instructions" => "partial eval"},
      scores_by_val_id: %{0 => 0.8, 2 => 0.9, 5 => 0.7},
      average_score: 0.8,
      num_examples_evaluated: 3,
      total_valset_size: 10,
      parent_ids: [2],
      is_best_program: false,
      outputs_by_val_id: %{0 => "o0", 2 => "o2", 5 => "o5"}
    }

    assert :ok = GEPA.Callbacks.notify([callback], :valset_evaluated, event)
    assert_receive {:callback, :on_valset_evaluated, received}
    assert received.num_examples_evaluated == 3
    assert received.total_valset_size == 10
    assert map_size(received.scores_by_val_id) == 3
  end

  test "on_error called with exception" do
    callback = %Recorder{pid: self()}
    exception = %ArgumentError{message: "Test error"}
    event = %{iteration: 5, exception: exception, will_continue: true}

    assert :ok = GEPA.Callbacks.notify([callback], :error, event)
    assert_receive {:callback, :on_error, ^event}
  end

  test "callback exception does not stop notification" do
    failing = %FailingCallback{fail_on: :on_optimization_start}
    recording = %Recorder{pid: self()}

    assert :ok = GEPA.Callbacks.notify([failing, recording], :optimization_start, %{config: %{}})
    assert_receive {:callback, :on_optimization_start, %{config: %{}}}
  end

  test "callback exception is logged" do
    log =
      capture_log(fn ->
        assert :ok =
                 GEPA.Callbacks.notify(
                   [%FailingCallback{fail_on: :on_optimization_start}],
                   :optimization_start,
                   %{config: %{}}
                 )
      end)

    assert log =~ "failed on on_optimization_start"
  end

  test "composite callback calls all callbacks" do
    composite = Composite.new([%Recorder{pid: self()}, %Recorder{pid: self()}])

    assert :ok = GEPA.Callbacks.notify([composite], :optimization_start, %{config: %{}})

    assert length(drain_events(:on_optimization_start)) == 2
  end

  test "multiple callbacks all receive events" do
    callbacks = for _ <- 1..3, do: %Recorder{pid: self()}

    assert :ok = GEPA.Callbacks.notify(callbacks, :iteration_start, %{iteration: 1, state: nil})
    assert length(drain_events(:on_iteration_start)) == 3
  end

  test "callback order is preserved" do
    test_pid = self()

    callbacks = [
      fn _event_name, _event -> send(test_pid, {:order, :first}) end,
      fn _event_name, _event -> send(test_pid, {:order, :second}) end,
      fn _event_name, _event -> send(test_pid, {:order, :third}) end
    ]

    assert :ok = GEPA.Callbacks.notify(callbacks, :optimization_start, %{config: %{}})
    assert_receive {:order, :first}
    assert_receive {:order, :second}
    assert_receive {:order, :third}
  end

  test "composite callback add method" do
    composite =
      Composite.new()
      |> Composite.add(%Recorder{pid: self()})

    assert :ok = GEPA.Callbacks.notify([composite], :optimization_start, %{config: %{}})
    assert_receive {:callback, :on_optimization_start, %{config: %{}}}
  end

  test "notify callbacks with nil" do
    assert :ok = GEPA.Callbacks.notify(nil, :optimization_start, %{config: %{}})
  end

  test "notify callbacks with empty list" do
    assert :ok = GEPA.Callbacks.notify([], :optimization_start, %{config: %{}})
  end

  test "reflective dataset structure is correct" do
    callback = %Recorder{pid: self()}

    dataset = %{
      "predictor_name" => [
        %{
          "Inputs" => %{"field1" => "value1"},
          "Generated Outputs" => %{"output1" => "result1"},
          "Feedback" => "This is feedback"
        }
      ]
    }

    assert :ok =
             GEPA.Callbacks.notify([callback], :reflective_dataset_built, %{
               iteration: 1,
               candidate_idx: 0,
               components: ["predictor_name"],
               dataset: dataset
             })

    assert_receive {:callback, :on_reflective_dataset_built, %{dataset: received}}

    assert [%{"Inputs" => _, "Generated Outputs" => _, "Feedback" => _}] =
             received["predictor_name"]
  end

  test "iteration numbers start at one" do
    callback = %Recorder{pid: self()}

    assert :ok = GEPA.Callbacks.notify([callback], :iteration_start, %{iteration: 1, state: nil})
    assert_receive {:callback, :on_iteration_start, %{iteration: 1}}
  end

  test "callback receives real optimization flow" do
    callback = %Recorder{pid: self()}

    assert {:ok, result} =
             GEPA.optimize(
               seed_candidate: %{"instruction" => "initial"},
               trainset: [%{input: "train", answer: "answer"}],
               valset: [%{input: "val", answer: "answer"}],
               adapter: OptimizingAdapter.new(),
               max_candidate_proposals: 1,
               callbacks: [callback],
               skip_perfect_score: false,
               acceptance_criterion: :improvement_or_equal
             )

    events = drain_events()

    assert %GEPA.Result{} = result
    assert one_event(events, :on_optimization_start).trainset_size == 1
    assert one_event(events, :on_optimization_start).valset_size == 1
    assert one_event(events, :on_optimization_end).total_metric_calls > 0
    assert event_count(events, :on_iteration_start) >= 1
    assert event_count(events, :on_iteration_start) == event_count(events, :on_iteration_end)
    assert event_count(events, :on_candidate_selected) >= 1
    assert event_count(events, :on_minibatch_sampled) >= 1
    assert event_count(events, :on_evaluation_start) >= 1
    assert event_count(events, :on_evaluation_end) >= 1
    assert event_count(events, :on_budget_updated) >= 1
    assert event_count(events, :on_pareto_front_updated) >= 1
    assert event_count(events, :on_valset_evaluated) >= 1
    assert event_count(events, :on_proposal_start) >= 1
    assert event_count(events, :on_proposal_start) == event_count(events, :on_proposal_end)

    assert event_count(events, :on_candidate_accepted) +
             event_count(events, :on_candidate_rejected) >= 1

    seed_valset_events =
      Enum.filter(events, fn {method, event} ->
        method == :on_valset_evaluated and event.iteration == 0 and event.candidate_idx == 0
      end)

    assert length(seed_valset_events) == 1
  end

  test "callback with stopper interaction receives budget updates" do
    callback = %Recorder{pid: self()}

    assert {:ok, _result} =
             GEPA.optimize(
               seed_candidate: %{"instruction" => "initial"},
               trainset: [%{input: "train", answer: "answer"}],
               valset: [%{input: "val", answer: "answer"}],
               adapter: OptimizingAdapter.new(),
               max_candidate_proposals: 1,
               callbacks: [callback],
               skip_perfect_score: false,
               acceptance_criterion: :improvement_or_equal
             )

    budget_events = drain_events(:on_budget_updated)
    assert budget_events != []
    assert List.last(budget_events).metric_calls_used > 0
    assert Map.has_key?(List.last(budget_events), :metric_calls_remaining)
  end

  test "callbacks during optimization integration records required event families" do
    callback = %Recorder{pid: self()}

    assert {:ok, result} =
             GEPA.optimize(
               seed_candidate: %{"instruction" => "initial"},
               trainset: [%{input: "train", answer: "answer"}],
               valset: [%{input: "val", answer: "answer"}],
               adapter: OptimizingAdapter.new(),
               max_candidate_proposals: 1,
               callbacks: [callback],
               skip_perfect_score: false,
               acceptance_criterion: :improvement_or_equal
             )

    events = drain_events()
    best = GEPA.Result.best_candidate(result)

    assert is_binary(best["instruction"])
    assert event_count(events, :on_optimization_start) == 1
    assert event_count(events, :on_optimization_end) == 1
    assert event_count(events, :on_budget_updated) >= 1
    assert event_count(events, :on_pareto_front_updated) >= 1
    assert event_count(events, :on_valset_evaluated) >= 1
  end

  test "multiple integration callbacks all receive events" do
    callback1 = %Recorder{pid: self()}
    callback2 = %Recorder{pid: self()}

    assert {:ok, _result} =
             GEPA.optimize(
               seed_candidate: %{"instruction" => "initial"},
               trainset: [%{input: "train", answer: "answer"}],
               valset: [%{input: "val", answer: "answer"}],
               adapter: OptimizingAdapter.new(),
               max_candidate_proposals: 1,
               callbacks: [callback1, callback2],
               skip_perfect_score: false,
               acceptance_criterion: :improvement_or_equal
             )

    events = drain_events()
    assert event_count(events, :on_optimization_start) == 2
    assert event_count(events, :on_optimization_end) == 2
    assert rem(event_count(events, :on_iteration_start), 2) == 0
    assert rem(event_count(events, :on_iteration_end), 2) == 0
  end

  test "partial integration callback implementation works" do
    callback = %PartialRuntimeCallback{pid: self()}

    assert {:ok, _result} =
             GEPA.optimize(
               seed_candidate: %{"instruction" => "initial"},
               trainset: [%{input: "train", answer: "answer"}],
               valset: [%{input: "val", answer: "answer"}],
               adapter: OptimizingAdapter.new(),
               max_candidate_proposals: 1,
               callbacks: [callback],
               skip_perfect_score: false,
               acceptance_criterion: :improvement_or_equal
             )

    assert_receive {:partial_runtime, :iteration_start, 1}
    assert_receive {:partial_runtime, :budget_updated, used} when used > 0
  end

  defp drain_events(method_name \\ nil, acc \\ []) do
    receive do
      {:callback, method, event} ->
        if is_nil(method_name) or method == method_name do
          drain_events(method_name, [{method, event} | acc])
        else
          drain_events(method_name, acc)
        end
    after
      0 ->
        acc
        |> Enum.reverse()
        |> Enum.map(fn
          {_method, event} when not is_nil(method_name) -> event
          event -> event
        end)
    end
  end

  defp event_count(events, method_name) do
    Enum.count(events, fn {method, _event} -> method == method_name end)
  end

  defp one_event(events, method_name) do
    events
    |> Enum.find(fn {method, _event} -> method == method_name end)
    |> elem(1)
  end
end
