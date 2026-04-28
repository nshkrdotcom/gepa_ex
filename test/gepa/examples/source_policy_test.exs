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

  test "every example script is documented and included in the batch runner" do
    examples =
      "examples"
      |> Path.join("*.exs")
      |> Path.wildcard()

    readme = File.read!("examples/README.md")
    run_all = File.read!("examples/run_all.sh")

    for path <- examples do
      script = Path.basename(path)

      assert String.contains?(readme, script),
             "#{script} must be documented in examples/README.md"

      assert String.contains?(run_all, script),
             "#{script} must be included in examples/run_all.sh"
    end
  end
end
