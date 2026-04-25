defmodule GEPA.CodeExecutionTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  test "executes code in process with stdout and result" do
    result = GEPA.CodeExecution.execute("IO.puts(\"hello\")\n1 + 2")

    assert result.ok
    assert result.result == 3
    assert result.stdout =~ "hello"
  end

  test "returns structured errors instead of raising" do
    result = GEPA.CodeExecution.execute("raise \"boom\"")

    refute result.ok
    assert result.error =~ "boom"
  end

  test "executes code in subprocess" do
    result = GEPA.CodeExecution.execute("IO.puts(\"sub\")", mode: :subprocess)

    assert result.ok
    assert result.stdout =~ "sub"
  end

  test "converts side info into serializable data" do
    assert GEPA.CodeExecution.side_info_to_data(%{a: {:x, 1}}) == %{"a" => [":x", 1]}
  end
end
