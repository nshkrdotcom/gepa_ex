defmodule GEPA.ReflectionCostTrackingParityTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.LLM
  alias GEPA.LLM.{Client, Response, Tracking}
  alias GEPA.StopCondition.MaxReflectionCost

  defmodule MeteredAdapter do
    @moduledoc false

    def complete(%Client{adapter_state: responses}, _request) when is_pid(responses) do
      Agent.get_and_update(responses, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, :no_response}, []}
      end)
    end
  end

  describe "upstream LM cost tracking parity" do
    test "initial cost and token counters are zero" do
      lm = metered_lm([])

      assert GEPA.LM.total_cost(lm) == 0.0
      assert GEPA.LM.total_tokens_in(lm) == 0
      assert GEPA.LM.total_tokens_out(lm) == 0
    end

    test "cost and provider token usage accumulate across calls" do
      lm =
        metered_lm([
          response("response", prompt_tokens: 100, completion_tokens: 50, cost: 0.005),
          response("response", prompt_tokens: 100, completion_tokens: 50, cost: 0.005)
        ])

      assert {:ok, "response"} = GEPA.LM.complete(lm, "first call")
      assert GEPA.LM.total_cost(lm) == 0.005
      assert GEPA.LM.total_tokens_in(lm) == 100
      assert GEPA.LM.total_tokens_out(lm) == 50

      assert {:ok, "response"} = GEPA.LM.complete(lm, "second call")
      assert GEPA.LM.total_cost(lm) == 0.01
      assert GEPA.LM.total_tokens_in(lm) == 200
      assert GEPA.LM.total_tokens_out(lm) == 100
    end

    test "batch completion accumulates per-response cost and token usage" do
      lm =
        metered_lm([
          response(" answer1 ", prompt_tokens: 50, completion_tokens: 20, cost: 0.002),
          response(" answer2 ", prompt_tokens: 60, completion_tokens: 30, cost: 0.002)
        ])

      assert {:ok, ["answer1", "answer2"]} =
               GEPA.LM.batch_complete(lm, [
                 [%{role: "user", content: "q1"}],
                 [%{role: "user", content: "q2"}]
               ])

      assert GEPA.LM.total_cost(lm) == 0.004
      assert GEPA.LM.total_tokens_in(lm) == 110
      assert GEPA.LM.total_tokens_out(lm) == 50
    end

    test "unknown provider cost and missing usage remain zero" do
      lm = metered_lm([%Response{text: "response", usage: nil, cost: nil, stop_reason: :stop}])

      assert {:ok, "response"} = GEPA.LM.complete(lm, "test")
      assert GEPA.LM.total_cost(lm) == 0.0
      assert GEPA.LM.total_tokens_in(lm) == 0
      assert GEPA.LM.total_tokens_out(lm) == 0
    end
  end

  describe "upstream TrackingLM parity" do
    test "wraps callable and returns its response" do
      tracker = Tracking.new(fn _prompt -> "hello world" end)

      assert {:ok, "hello world"} = LLM.complete(tracker, "test prompt")
    end

    test "tracks estimated tokens" do
      tracker = Tracking.new(fn _prompt -> String.duplicate("a", 40) end)

      assert {:ok, _response} = LLM.complete(tracker, String.duplicate("b", 80))
      assert Tracking.total_tokens_in(tracker) == 20
      assert Tracking.total_tokens_out(tracker) == 10
    end

    test "accumulates estimated tokens across calls" do
      tracker = Tracking.new(fn _prompt -> "response" end)

      assert {:ok, _response} = LLM.complete(tracker, "prompt one")
      tokens_after_one = Tracking.total_tokens_out(tracker)
      assert {:ok, _response} = LLM.complete(tracker, "prompt two")

      assert Tracking.total_tokens_out(tracker) == tokens_after_one * 2
    end

    test "callable tracking cost is always zero" do
      tracker = Tracking.new(fn _prompt -> "response" end)

      assert {:ok, _response} = LLM.complete(tracker, "test")
      assert Tracking.total_cost(tracker) == 0.0
    end

    test "exposes tracking counters" do
      tracker = Tracking.new(fn _prompt -> "ok" end)

      assert is_number(Tracking.total_cost(tracker))
      assert is_integer(Tracking.total_tokens_in(tracker))
      assert is_integer(Tracking.total_tokens_out(tracker))
      assert is_integer(Tracking.calls(tracker))
    end

    test "handles list prompts" do
      tracker = Tracking.new(fn _prompt -> "response" end)

      assert {:ok, _response} = LLM.complete(tracker, [%{role: "user", content: "hello"}])
      assert Tracking.total_tokens_in(tracker) > 0
    end
  end

  describe "upstream callable wrapping parity" do
    test "plain callable gets wrapped" do
      fun = fn _prompt -> "```\nnew text\n```" end

      assert is_function(fun, 1)
      wrapped = LLM.track(fun)

      assert %Tracking{} = wrapped
      assert is_number(Tracking.total_cost(wrapped))
    end

    test "LM instance is not double wrapped" do
      lm = metered_lm([])

      assert LLM.track(lm) == lm
    end
  end

  describe "upstream max reflection cost stopper parity" do
    test "stops when budget is exceeded" do
      stopper = MaxReflectionCost.new(10.0, %{total_cost: 10.5})

      assert MaxReflectionCost.should_stop?(stopper, nil)
    end

    test "continues when under budget" do
      stopper = MaxReflectionCost.new(10.0, %{total_cost: 5.0})

      refute MaxReflectionCost.should_stop?(stopper, nil)
    end

    test "tracking LM never trips a positive cost budget" do
      tracker = Tracking.new(fn _prompt -> "response" end)

      assert {:ok, _response} = LLM.complete(tracker, "test")

      stopper = MaxReflectionCost.new(0.001, tracker)

      refute MaxReflectionCost.should_stop?(stopper, nil)
    end

    test "nil LM never trips a positive cost budget" do
      stopper = MaxReflectionCost.new(0.001, nil)

      refute MaxReflectionCost.should_stop?(stopper, nil)
    end
  end

  defp metered_lm(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)
    client = %Client{adapter: MeteredAdapter, adapter_state: agent}
    GEPA.LM.new("openai/gpt-4.1-mini", client: client)
  end

  defp response(text, opts) do
    %Response{
      text: text,
      usage: %{
        prompt_tokens: Keyword.fetch!(opts, :prompt_tokens),
        completion_tokens: Keyword.fetch!(opts, :completion_tokens)
      },
      cost: Keyword.fetch!(opts, :cost),
      stop_reason: :stop
    }
  end
end
