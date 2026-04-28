defmodule GEPA.OptimizeAnythingEvaluatorWrapperParityTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias GEPA.LLM.Client
  alias GEPA.OptimizeAnything
  alias GEPA.OptimizeAnything.{Adapter, EvaluatorWrapper, OptimizationState}

  defmodule FakeReqLLM do
    def put_key(_provider, _api_key), do: :ok

    def generate_text(model_spec, prompt, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:llm_request, model_spec, prompt, opts})
      {:ok, %{text: "response text", finish_reason: "stop"}}
    end
  end

  defmodule FakeResponse do
    def text(%{text: text}), do: text
  end

  describe "oa.log parity" do
    test "log basic capture" do
      evaluator = fn _candidate ->
        OptimizeAnything.log("hello world")
        OptimizeAnything.log("score is 42")
        1.0
      end

      result = EvaluatorWrapper.evaluate(evaluator, %{"x" => "1"})

      assert result.score == 1.0
      assert result.side_info["log"] =~ "hello world"
      assert result.side_info["log"] =~ "score is 42"
    end

    test "log with custom sep and ending" do
      evaluator = fn _candidate ->
        OptimizeAnything.log(["a", "b", "c"], sep: "-", ending: "!")
        1.0
      end

      result = EvaluatorWrapper.evaluate(evaluator, %{"x" => "1"})
      assert result.side_info["log"] == "a-b-c!"
    end

    test "log outside evaluator warns and discards output" do
      warning =
        capture_log(fn ->
          OptimizeAnything.log("stale output")
        end)

      assert warning =~ "outside of an evaluator"

      result =
        EvaluatorWrapper.evaluate(
          fn _candidate ->
            OptimizeAnything.log("fresh output")
            1.0
          end,
          %{"x" => "1"}
        )

      refute result.side_info["log"] =~ "stale output"
      assert result.side_info["log"] =~ "fresh output"
    end

    test "log no output means no log key" do
      result = EvaluatorWrapper.evaluate(fn _candidate -> 1.0 end, %{"x" => "1"})
      refute Map.has_key?(result.side_info, "log")
    end

    test "log child task with context propagation" do
      evaluator = fn _candidate ->
        context = OptimizeAnything.get_log_context()
        OptimizeAnything.log("from main")

        task =
          Task.async(fn ->
            OptimizeAnything.set_log_context(context)
            OptimizeAnything.log("from child")
          end)

        Task.await(task)
        1.0
      end

      result = EvaluatorWrapper.evaluate(evaluator, %{"x" => "1"})

      assert result.side_info["log"] =~ "from main"
      assert result.side_info["log"] =~ "from child"
    end

    test "log child task pool with manual context propagation" do
      evaluator = fn _candidate ->
        context = OptimizeAnything.get_log_context()

        0..4
        |> Task.async_stream(fn idx ->
          OptimizeAnything.set_log_context(context)
          OptimizeAnything.log("msg-#{idx}")
        end)
        |> Stream.run()

        1.0
      end

      result = EvaluatorWrapper.evaluate(evaluator, %{"x" => "1"})

      for idx <- 0..4 do
        assert result.side_info["log"] =~ "msg-#{idx}"
      end
    end

    test "parallel evaluators have isolated logs" do
      evaluator = fn candidate ->
        OptimizeAnything.log("eval-#{candidate.id}")
        OptimizeAnything.log("done-#{candidate.id}")
        String.to_integer(candidate.id) * 1.0
      end

      results =
        0..7
        |> Task.async_stream(fn idx ->
          {idx, EvaluatorWrapper.evaluate(evaluator, %{id: Integer.to_string(idx)})}
        end)
        |> Enum.map(fn {:ok, value} -> value end)
        |> Map.new()

      for {idx, result} <- results do
        log = result.side_info["log"]
        assert log =~ "eval-#{idx}"
        assert log =~ "done-#{idx}"

        for other_idx <- Map.keys(results), other_idx != idx do
          refute log =~ "eval-#{other_idx}"
        end
      end
    end

    test "get log context outside evaluator raises" do
      assert_raise RuntimeError, "No active log context", fn ->
        OptimizeAnything.get_log_context()
      end
    end

    test "log thread safe writes" do
      evaluator = fn _candidate ->
        context = OptimizeAnything.get_log_context()

        1..10
        |> Task.async_stream(fn thread_id ->
          OptimizeAnything.set_log_context(context)

          for idx <- 1..100 do
            OptimizeAnything.log("t#{thread_id}:#{idx}")
          end
        end)
        |> Stream.run()

        1.0
      end

      result = EvaluatorWrapper.evaluate(evaluator, %{"x" => "1"})
      lines = result.side_info["log"] |> String.split("\n", trim: true)
      assert length(lines) == 1000
    end
  end

  describe "stdio capture parity" do
    test "stdout captured when enabled" do
      result =
        EvaluatorWrapper.evaluate(
          fn _candidate ->
            IO.puts("hello from evaluator")
            1.0
          end,
          %{"x" => "1"},
          nil,
          capture_stdio: true
        )

      assert result.side_info["stdout"] =~ "hello from evaluator"
    end

    test "stdout not captured when disabled" do
      output =
        capture_io(fn ->
          result =
            EvaluatorWrapper.evaluate(
              fn _candidate ->
                IO.write("hello from evaluator")
                1.0
              end,
              %{"x" => "1"}
            )

          refute Map.has_key?(result.side_info, "stdout")
        end)

      assert output == "hello from evaluator"
    end

    test "log and stdio captured together" do
      result =
        EvaluatorWrapper.evaluate(
          fn _candidate ->
            OptimizeAnything.log("log message")
            IO.puts("stdout message")
            1.0
          end,
          %{"x" => "1"},
          nil,
          capture_stdio: true
        )

      assert result.side_info["log"] =~ "log message"
      assert result.side_info["stdout"] =~ "stdout message"
    end

    test "stdio not captured between evaluator calls" do
      evaluator = fn _candidate -> 1.0 end
      _first = EvaluatorWrapper.evaluate(evaluator, %{"x" => "1"}, nil, capture_stdio: true)

      between_output = capture_io(fn -> IO.write("between calls") end)
      second = EvaluatorWrapper.evaluate(evaluator, %{"x" => "2"}, nil, capture_stdio: true)

      assert between_output == "between calls"
      refute Map.has_key?(second.side_info, "stdout")
    end

    test "capture scoped per call not per wrapper" do
      result =
        EvaluatorWrapper.evaluate(
          fn _candidate ->
            IO.write("captured")
            1.0
          end,
          %{"x" => "1"},
          nil,
          capture_stdio: true
        )

      assert result.side_info["stdout"] == "captured"
      assert capture_io(fn -> IO.write("outside") end) == "outside"
    end
  end

  describe "side-info key collision parity" do
    test "log key collision warns and prefixes" do
      warning =
        capture_log(fn ->
          result =
            EvaluatorWrapper.evaluate(
              fn _candidate ->
                OptimizeAnything.log("captured log")
                {1.0, %{log: "user log value"}}
              end,
              %{"x" => "1"}
            )

          assert result.side_info["log"] == "user log value"
          assert result.side_info["_gepa_log"] =~ "captured log"
        end)

      assert warning =~ "conflicts"
    end

    test "stdout key collision warns and prefixes" do
      warning =
        capture_log(fn ->
          result =
            EvaluatorWrapper.evaluate(
              fn _candidate ->
                IO.write("captured stdout")
                {1.0, %{stdout: "user stdout value"}}
              end,
              %{"x" => "1"},
              nil,
              capture_stdio: true
            )

          assert result.side_info["stdout"] == "user stdout value"
          assert result.side_info["_gepa_stdout"] =~ "captured stdout"
        end)

      assert warning =~ "conflicts"
    end

    test "no collision no warning" do
      warning =
        capture_log(fn ->
          result =
            EvaluatorWrapper.evaluate(
              fn _candidate ->
                OptimizeAnything.log("some log")
                {1.0, %{my_key: "my_value"}}
              end,
              %{"x" => "1"}
            )

          assert result.side_info["my_key"] == "my_value"
          assert result.side_info["log"] =~ "some log"
        end)

      refute warning =~ "conflicts"
    end

    test "no collision when capture inactive" do
      warning =
        capture_log(fn ->
          result =
            EvaluatorWrapper.evaluate(
              fn _candidate ->
                {1.0, %{stdout: "user value", log: "user log"}}
              end,
              %{"x" => "1"}
            )

          assert result.side_info["stdout"] == "user value"
          assert result.side_info["log"] == "user log"
        end)

      refute warning =~ "conflicts"
    end
  end

  describe "candidate and evaluator mode parity" do
    test "str candidate unwrapped" do
      parent = self()

      result =
        EvaluatorWrapper.evaluate(
          fn candidate ->
            send(parent, {:candidate, candidate})
            1.0
          end,
          %{OptimizeAnything.str_candidate_key() => "hello world"},
          nil,
          str_candidate_key: OptimizeAnything.str_candidate_key()
        )

      assert result.score == 1.0
      assert_receive {:candidate, "hello world"}
    end

    test "dict candidate not unwrapped" do
      parent = self()

      EvaluatorWrapper.evaluate(
        fn candidate ->
          send(parent, {:candidate, candidate})
          1.0
        end,
        %{key: "value"}
      )

      assert_receive {:candidate, %{key: "value"}}
    end

    test "single instance mode no example passed" do
      parent = self()

      EvaluatorWrapper.evaluate(
        fn candidate ->
          send(parent, {:received, candidate})
          1.0
        end,
        %{"x" => "1"},
        %{input: "test"}
      )

      assert_receive {:received, %{"x" => "1"}}
    end

    test "per instance mode example passed" do
      parent = self()

      EvaluatorWrapper.evaluate(
        fn _candidate, example ->
          send(parent, {:example, example})
          1.0
        end,
        %{"x" => "1"},
        %{input: "test"}
      )

      assert_receive {:example, %{input: "test"}}
    end

    test "return tuple normalized" do
      result =
        EvaluatorWrapper.evaluate(
          fn _candidate ->
            {0.5, %{key: "val"}}
          end,
          %{"x" => "1"}
        )

      assert result.score == 0.5
      assert result.output == nil
      assert result.side_info["key"] == "val"
    end

    test "return float normalized" do
      result = EvaluatorWrapper.evaluate(fn _candidate -> 0.7 end, %{"x" => "1"})

      assert result.score == 0.7
      assert result.output == nil
      assert is_map(result.side_info)
    end

    test "nil side info becomes empty map" do
      result = EvaluatorWrapper.evaluate(fn _candidate -> {0.5, nil} end, %{"x" => "1"})

      assert result.score == 0.5
      assert result.output == nil
      assert result.side_info == %{}
    end
  end

  describe "optimization state parity" do
    test "construction" do
      state = %OptimizationState{best_example_evals: [%{score: 1.0, side_info: %{}}]}
      assert length(state.best_example_evals) == 1
      assert hd(state.best_example_evals).score == 1.0
    end

    test "empty evals" do
      assert %OptimizationState{best_example_evals: []}.best_example_evals == []
    end

    test "opt state forwarded when accepted" do
      parent = self()
      state = %OptimizationState{best_example_evals: [%{score: 0.5, side_info: %{}}]}

      EvaluatorWrapper.evaluate(
        fn _candidate, _example, opt_state ->
          send(parent, {:opt_state, opt_state})
          1.0
        end,
        %{"x" => "1"},
        nil,
        opt_state: state
      )

      assert_receive {:opt_state, ^state}
    end

    test "opt state filtered when not accepted" do
      parent = self()
      state = %OptimizationState{best_example_evals: []}

      EvaluatorWrapper.evaluate(
        fn _candidate ->
          send(parent, :called)
          1.0
        end,
        %{"x" => "1"},
        nil,
        opt_state: state
      )

      assert_receive :called
    end
  end

  describe "make_litellm_lm parity" do
    test "returns LM client instance" do
      lm = OptimizeAnything.make_litellm_lm("test-model")
      assert %Client{provider: :openai, model: "test-model"} = lm
    end

    test "string prompt" do
      lm = fake_lm()

      assert {:ok, "response text"} = GEPA.LLM.complete(lm, "hello")

      assert_received {:llm_request, "openai:test-model", "hello", opts}
      assert Keyword.fetch!(opts, :test_pid) == self()
    end

    test "messages prompt" do
      lm = fake_lm()
      messages = [%{role: "system", content: "sys"}, %{role: "user", content: "hi"}]

      assert {:ok, "response text"} = GEPA.LLM.complete(lm, messages)

      assert_received {:llm_request, "openai:test-model", ^messages, opts}
      assert Keyword.fetch!(opts, :test_pid) == self()
    end
  end

  describe "BEAM stdio capture utility parity" do
    test "passthrough when not capturing" do
      assert capture_io(fn -> IO.write("hello") end) == "hello"
    end

    test "capture when started" do
      result = capture_stdout("captured")
      assert result.side_info["stdout"] == "captured"
    end

    test "stop capture returns text and resets" do
      first = capture_stdout("first")
      assert first.side_info["stdout"] == "first"
      assert capture_io(fn -> IO.write("second") end) == "second"
    end

    test "per process isolation" do
      results =
        0..4
        |> Task.async_stream(fn idx -> {idx, capture_stdout("process-#{idx}")} end)
        |> Enum.map(fn {:ok, {idx, result}} -> {idx, result.side_info["stdout"]} end)

      for {idx, stdout} <- results do
        assert stdout == "process-#{idx}"
      end
    end

    test "captured stream text is binary" do
      result = capture_stdout("text")
      assert is_binary(result.side_info["stdout"])
    end

    test "capture isolation between processes" do
      results =
        0..3
        |> Task.async_stream(fn idx -> {idx, capture_stdout("worker-#{idx}")} end)
        |> Enum.map(fn {:ok, value} -> value end)

      for {idx, result} <- results do
        stdout = result.side_info["stdout"]
        assert stdout == "worker-#{idx}"

        for {other_idx, _other_result} <- results, other_idx != idx do
          refute stdout =~ "worker-#{other_idx}"
        end
      end
    end
  end

  describe "adapter-level evaluator wrapper parity" do
    test "str candidate mode unwraps through adapter" do
      parent = self()

      adapter =
        Adapter.new(
          evaluator: fn candidate, _example ->
            send(parent, {:candidate, candidate})
            1.0
          end,
          str_candidate_key: OptimizeAnything.str_candidate_key(),
          parallelism: 1
        )

      candidate = %{OptimizeAnything.str_candidate_key() => "seed"}

      assert {:ok, batch} = Adapter.evaluate(adapter, [%{}], candidate, false)
      assert batch.scores == [1.0]
      assert_receive {:candidate, "seed"}
    end
  end

  defp fake_lm do
    OptimizeAnything.make_litellm_lm(
      "test-model",
      req_llm_module: FakeReqLLM,
      response_module: FakeResponse,
      provider_opts: [test_pid: self()],
      env: fn _name -> nil end
    )
  end

  defp capture_stdout(text) do
    EvaluatorWrapper.evaluate(
      fn _candidate ->
        IO.write(text)
        1.0
      end,
      %{"x" => "1"},
      nil,
      capture_stdio: true
    )
  end
end
