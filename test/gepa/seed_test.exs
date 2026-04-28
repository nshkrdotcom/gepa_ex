defmodule GEPA.SeedTest do
  use ExUnit.Case, async: true

  alias GEPA.Seed

  test "build_prompt includes objective background and first three examples" do
    prompt =
      Seed.build_prompt(
        objective: "Optimize kernels.",
        background: "Target H100 GPUs.",
        dataset: [%{input: 1}, %{input: 2}, %{input: 3}, %{input: 4}]
      )

    assert prompt =~ "## Goal"
    assert prompt =~ "Optimize kernels."
    assert prompt =~ "## Domain Context & Constraints"
    assert prompt =~ "Example 3"
    refute prompt =~ "Example 4"
  end

  test "extract_fenced_text strips optional language specifier" do
    assert Seed.extract_fenced_text("```python\ndef run(), do: :ok\n```") == "def run(), do: :ok"
  end
end
