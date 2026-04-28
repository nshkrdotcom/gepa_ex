defmodule GEPA.LLM.TrackingTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.LLM.Tracking

  test "wraps callables and tracks calls plus token estimates" do
    tracker = Tracking.new(fn prompt -> "answer: #{inspect(prompt)}" end)

    assert {:ok, response} = GEPA.LLM.complete(tracker, "hello")
    assert response =~ "hello"
    assert Tracking.calls(tracker) == 1
    assert Tracking.total_tokens_in(tracker) > 0
    assert Tracking.total_tokens_out(tracker) > 0
    assert Tracking.total_cost(tracker) == 0.0
  end

  test "supports two-arity callables" do
    tracker = Tracking.new(fn prompt, opts -> "#{prompt}:#{opts[:suffix]}" end)

    assert {:ok, "hello:ok"} = GEPA.LLM.complete(tracker, "hello", suffix: "ok")
    assert Tracking.calls(tracker) == 1
  end
end
