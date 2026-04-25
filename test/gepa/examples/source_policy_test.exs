defmodule GEPA.Examples.SourcePolicyTest do
  use ExUnit.Case, async: true

  test "examples are live-only and do not use mock or fake providers" do
    examples =
      "examples"
      |> Path.join("*.exs")
      |> Path.wildcard()

    assert examples != []

    forbidden = [
      "GEPA.LLM.Mock",
      "Mock.new",
      "Fake",
      "fake",
      "placeholder improvement"
    ]

    for path <- examples do
      content = File.read!(path)

      for term <- forbidden do
        refute String.contains?(content, term), "#{path} must not contain #{inspect(term)}"
      end
    end
  end
end
