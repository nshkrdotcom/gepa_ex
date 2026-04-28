defmodule GEPA.SeedGenerationParityTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.OptimizeAnything
  alias GEPA.Seed

  describe "upstream seed generation prompt parity" do
    test "objective-only prompt includes goal and output format" do
      prompt = Seed.build_prompt(objective: "Maximize throughput.")

      assert prompt =~ "## Goal"
      assert prompt =~ "Maximize throughput."
      refute prompt =~ "## Domain Context"
      refute prompt =~ "## Sample Inputs"
      assert prompt =~ "``` blocks"
    end

    test "prompt includes background when provided" do
      prompt =
        Seed.build_prompt(
          objective: "Write fast code.",
          background: "Use CUDA. Target H100 GPUs."
        )

      assert prompt =~ "## Goal"
      assert prompt =~ "Write fast code."
      assert prompt =~ "## Domain Context & Constraints"
      assert prompt =~ "Use CUDA. Target H100 GPUs."
    end

    test "prompt includes up to three dataset examples" do
      prompt =
        Seed.build_prompt(
          objective: "Solve problems.",
          dataset: [%{input: "a"}, %{input: "b"}, %{input: "c"}, %{input: "d"}]
        )

      assert prompt =~ "## Sample Inputs"
      assert prompt =~ "Example 1"
      assert prompt =~ "Example 2"
      assert prompt =~ "Example 3"
      refute prompt =~ "Example 4"
    end

    test "prompt includes all sections when all inputs are present" do
      prompt =
        Seed.build_prompt(
          objective: "Optimize kernels.",
          background: "Target A100 GPUs.",
          dataset: [%{problem: "matmul"}]
        )

      assert prompt =~ "## Goal"
      assert prompt =~ "## Domain Context & Constraints"
      assert prompt =~ "## Sample Inputs"
      assert prompt =~ "## Output Format"
    end

    test "explicit empty dataset still renders sample input section" do
      prompt = Seed.build_prompt(objective: "Do stuff.", dataset: [])

      assert prompt =~ "## Sample Inputs"
    end
  end

  describe "upstream seed candidate generation parity" do
    test "extracts generated candidate from backtick blocks" do
      key = OptimizeAnything.str_candidate_key()
      lm = fn _prompt -> "```\ngenerated candidate text\n```" end

      assert {:ok, %{^key => "generated candidate text"}} =
               Seed.generate(lm, objective: "Test objective.")
    end

    test "extracts generated candidate with language specifier" do
      key = OptimizeAnything.str_candidate_key()
      lm = fn _prompt -> "```python\ndef solve():\n    return 42\n```" end

      assert {:ok, %{^key => candidate}} = Seed.generate(lm, objective: "Write code.")

      assert candidate == "def solve():\n    return 42"
    end

    test "passes objective and background to LM prompt" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      lm = fn prompt ->
        Agent.update(calls, &(&1 ++ [prompt]))
        "```\nresult\n```"
      end

      assert {:ok, _candidate} =
               Seed.generate(lm, objective: "My objective.", background: "My background.")

      assert [prompt] = Agent.get(calls, & &1)
      assert prompt =~ "My objective."
      assert prompt =~ "My background."
    end

    test "passes dataset examples to LM prompt" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      lm = fn prompt ->
        Agent.update(calls, &(&1 ++ [prompt]))
        "```\nresult\n```"
      end

      assert {:ok, _candidate} =
               Seed.generate(
                 lm,
                 objective: "Solve.",
                 dataset: [%{input: "example1"}, %{input: "example2"}]
               )

      assert [prompt] = Agent.get(calls, & &1)
      assert prompt =~ "example1"
      assert prompt =~ "example2"
    end

    test "logs seed generation messages when logger is provided" do
      {:ok, logs} = Agent.start_link(fn -> [] end)
      logger = fn message -> Agent.update(logs, &(&1 ++ [message])) end

      lm = fn _prompt -> "```\ncandidate\n```" end

      assert {:ok, _candidate} = Seed.generate(lm, objective: "Goal.", logger: logger)

      assert [first, second] = Agent.get(logs, & &1)
      assert first =~ "Generating"
      assert second =~ "Generated"
    end
  end

  describe "upstream seedless optimize-anything validation parity" do
    test "seedless mode requires objective" do
      assert {:error, %ArgumentError{message: message}} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: nil,
                 evaluator: fn _candidate -> 1.0 end,
                 engine: %{max_metric_calls: 1}
               )

      assert message =~ "objective is required"
    end

    test "seedless mode rejects whitespace-only objective" do
      assert {:error, %ArgumentError{message: message}} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: nil,
                 evaluator: fn _candidate -> 1.0 end,
                 objective: "   ",
                 engine: %{max_metric_calls: 1}
               )

      assert message =~ "objective is required"
    end

    test "seedless mode requires reflection LM" do
      assert {:error, %ArgumentError{message: message}} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: nil,
                 evaluator: fn _candidate -> 1.0 end,
                 objective: "Test objective.",
                 engine: %{max_metric_calls: 1},
                 reflection: %{reflection_lm: nil}
               )

      assert message =~ "reflection_lm is required"
    end
  end

  describe "upstream seedless optimize-anything integration parity" do
    test "single-instance flow generates seed and runs optimization" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      reflection_lm = fn prompt ->
        Agent.update(calls, &(&1 ++ [prompt]))
        "```\ngenerated initial candidate\n```"
      end

      assert {:ok, result} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: nil,
                 evaluator: fn candidate -> min(String.length(candidate) / 100.0, 1.0) end,
                 objective: "Generate a long candidate string.",
                 engine: %{max_metric_calls: 2, reflection_minibatch_size: 1},
                 reflection: %{reflection_lm: reflection_lm}
               )

      assert [seed_prompt | _] = Agent.get(calls, & &1)
      assert seed_prompt =~ "## Goal"
      assert seed_prompt =~ "Generate a long candidate string."
      assert is_binary(GEPA.Result.best_candidate(result))
    end

    test "dataset flow includes examples in seed prompt" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      reflection_lm = fn prompt ->
        Agent.update(calls, &(&1 ++ [prompt]))
        "```\nSolve the math problem step by step.\n```"
      end

      dataset = [
        %{input: "2+2", answer: "4"},
        %{input: "3*5", answer: "15"}
      ]

      assert {:ok, result} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: nil,
                 evaluator: fn _candidate, _example -> 0.5 end,
                 objective: "Generate a prompt for math problems.",
                 dataset: dataset,
                 engine: %{max_metric_calls: 3, reflection_minibatch_size: 1},
                 reflection: %{reflection_lm: reflection_lm}
               )

      assert [seed_prompt | _] = Agent.get(calls, & &1)
      assert seed_prompt =~ "2+2"
      assert is_binary(GEPA.Result.best_candidate(result))
    end
  end
end
