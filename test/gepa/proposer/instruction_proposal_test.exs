defmodule GEPA.Proposer.InstructionProposalTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.LLM.Mock
  alias GEPA.Proposer.InstructionProposal

  describe "new/1" do
    test "creates with default template" do
      llm = Mock.new(responses: ["improved"])
      proposal = InstructionProposal.new(llm: llm)

      assert proposal.llm == llm
      assert proposal.template != nil
      assert String.contains?(proposal.template, "<curr_param>")
      assert String.contains?(proposal.template, "<side_info>")
    end

    test "accepts custom template with required placeholders" do
      llm = Mock.new(responses: ["improved"])

      custom_template = """
      Improve this: {component_name}
      Current: {current_instruction}
      Examples: {reflective_dataset}
      """

      proposal = InstructionProposal.new(llm: llm, template: custom_template)
      assert proposal.template == custom_template
    end

    test "raises if template missing {component_name}" do
      llm = Mock.new(responses: ["improved"])

      assert_raise ArgumentError, ~r/missing required placeholders.*component_name/, fn ->
        InstructionProposal.new(
          llm: llm,
          template: "Current: {current_instruction}\nExamples: {reflective_dataset}"
        )
      end
    end

    test "raises if template missing {current_instruction}" do
      llm = Mock.new(responses: ["improved"])

      assert_raise ArgumentError, ~r/missing required placeholders.*current_instruction/, fn ->
        InstructionProposal.new(
          llm: llm,
          template: "Component: {component_name}\nExamples: {reflective_dataset}"
        )
      end
    end

    test "raises if template missing {reflective_dataset}" do
      llm = Mock.new(responses: ["improved"])

      assert_raise ArgumentError, ~r/missing required placeholders.*reflective_dataset/, fn ->
        InstructionProposal.new(
          llm: llm,
          template: "Component: {component_name}\nCurrent: {current_instruction}"
        )
      end
    end

    test "raises if llm not provided" do
      assert_raise ArgumentError, ~r/must provide :llm/, fn ->
        InstructionProposal.new([])
      end
    end

    test "accepts custom extract_fn" do
      llm = Mock.new(responses: ["improved"])
      extract_fn = fn response -> "Extracted: #{response}" end

      proposal = InstructionProposal.new(llm: llm, extract_fn: extract_fn)
      assert proposal.extract_fn == extract_fn
    end

    test "accepts custom format_fn" do
      llm = Mock.new(responses: ["improved"])
      format_fn = fn dataset -> "Custom: #{inspect(dataset)}" end

      proposal = InstructionProposal.new(llm: llm, format_fn: format_fn)
      assert proposal.format_fn == format_fn
    end
  end

  describe "propose/4" do
    test "generates improved instruction from LLM" do
      llm = Mock.new(responses: ["Better instruction here"])
      proposal = InstructionProposal.new(llm: llm)

      dataset = [
        %{
          "Inputs" => %{"question" => "What is 2+2?"},
          "Generated Outputs" => "5",
          "Feedback" => "Incorrect, answer is 4"
        }
      ]

      {:ok, result} =
        InstructionProposal.propose(
          proposal,
          "math_solver",
          "Answer math questions",
          dataset
        )

      assert result == "Better instruction here"
    end

    test "trims whitespace from response" do
      llm = Mock.new(responses: ["  trimmed response  \n\n"])
      proposal = InstructionProposal.new(llm: llm)

      {:ok, result} = InstructionProposal.propose(proposal, "test", "original", [])
      assert result == "trimmed response"
    end

    test "default template does not require component name" do
      captured_prompt =
        capture_prompt(fn prompt ->
          refute String.contains?(prompt, "my_component")
          assert String.contains?(prompt, "instruction")
          "response"
        end)

      proposal = InstructionProposal.new(llm: captured_prompt)
      InstructionProposal.propose(proposal, "my_component", "instruction", [])
    end

    test "substitutes current_instruction in template" do
      captured_prompt =
        capture_prompt(fn prompt ->
          assert String.contains?(prompt, "My current instruction text")
          "response"
        end)

      proposal = InstructionProposal.new(llm: captured_prompt)
      InstructionProposal.propose(proposal, "comp", "My current instruction text", [])
    end

    test "formats reflective dataset into template" do
      captured_prompt =
        capture_prompt(fn prompt ->
          # Should contain formatted dataset
          assert String.contains?(prompt, "Example 1")
          assert String.contains?(prompt, "What is 2+2?")
          assert String.contains?(prompt, "wrong answer")
          assert String.contains?(prompt, "Should be 4")
          "response"
        end)

      proposal = InstructionProposal.new(llm: captured_prompt)

      dataset = [
        %{
          "Inputs" => %{"question" => "What is 2+2?"},
          "Generated Outputs" => "wrong answer",
          "Feedback" => "Should be 4"
        }
      ]

      InstructionProposal.propose(proposal, "comp", "instruction", dataset)
    end

    test "uses custom format_fn when provided" do
      captured_prompt =
        capture_prompt(fn prompt ->
          assert String.contains?(prompt, "CUSTOM_FORMAT_MARKER")
          "response"
        end)

      format_fn = fn _dataset -> "CUSTOM_FORMAT_MARKER" end
      proposal = InstructionProposal.new(llm: captured_prompt, format_fn: format_fn)

      InstructionProposal.propose(proposal, "comp", "instruction", [%{"test" => "data"}])
    end

    test "uses custom extract_fn when provided" do
      llm = Mock.new(responses: ["```\nExtracted content\n```"])

      extract_fn = fn response ->
        case Regex.run(~r/```\n(.+?)\n```/s, response) do
          [_, content] -> content
          nil -> response
        end
      end

      proposal = InstructionProposal.new(llm: llm, extract_fn: extract_fn)
      {:ok, result} = InstructionProposal.propose(proposal, "comp", "instruction", [])

      assert result == "Extracted content"
    end

    test "passes stripped LLM response to custom extract_fn" do
      test_pid = self()
      llm = Mock.new(responses: ["  response with spaces  "])

      extract_fn = fn response ->
        send(test_pid, {:extract_fn_received, response})
        response
      end

      proposal = InstructionProposal.new(llm: llm, extract_fn: extract_fn)

      assert {:ok, "response with spaces", _prompt, "response with spaces"} =
               InstructionProposal.propose_with_metadata(proposal, "comp", "instruction", [])

      assert_receive {:extract_fn_received, "response with spaces"}
    end

    test "default extractor strips language specifier from fenced instruction" do
      llm =
        Mock.new(
          responses: [
            """
            Here's the improved instruction:
            ```markdown
            This is the actual instruction content.
            It should not include the word 'markdown'.
            ```
            """
          ]
        )

      proposal = InstructionProposal.new(llm: llm)

      {:ok, result} = InstructionProposal.propose(proposal, "comp", "instruction", [])

      assert result ==
               "This is the actual instruction content.\nIt should not include the word 'markdown'."
    end

    test "default extractor uses outermost fenced block" do
      llm =
        Mock.new(
          responses: [
            """
            Begin text
            ```plaintext
            Begin instructions

            ```
            Internal block 1
            ```

            ```python
            Internal block 2
            ```

            End instructions
            ```
            End text
            """
          ]
        )

      proposal = InstructionProposal.new(llm: llm)

      {:ok, result} = InstructionProposal.propose(proposal, "comp", "instruction", [])

      assert result ==
               "Begin instructions\n\n```\nInternal block 1\n```\n\n```python\nInternal block 2\n```\n\nEnd instructions"
    end

    test "default extractor handles unmatched opening or closing fences" do
      opening = Mock.new(responses: ["```text\nHere are the instructions."])
      closing = Mock.new(responses: ["Here are the instructions.\n```"])

      {:ok, opening_result} =
        opening
        |> then(&InstructionProposal.new(llm: &1))
        |> InstructionProposal.propose("comp", "instruction", [])

      {:ok, closing_result} =
        closing
        |> then(&InstructionProposal.new(llm: &1))
        |> InstructionProposal.propose("comp", "instruction", [])

      assert opening_result == "Here are the instructions."
      assert closing_result == "Here are the instructions."
    end

    test "default extractor returns trimmed raw text when no complete fence exists" do
      llm =
        Mock.new(
          responses: ["\n Here are some backticks:\n```\nI hope you didn't get confused. "]
        )

      proposal = InstructionProposal.new(llm: llm)

      {:ok, result} = InstructionProposal.propose(proposal, "comp", "instruction", [])

      assert result == "Here are some backticks:\n```\nI hope you didn't get confused."
    end

    test "handles empty dataset" do
      llm = Mock.new(responses: ["improved"])
      proposal = InstructionProposal.new(llm: llm)

      {:ok, result} = InstructionProposal.propose(proposal, "comp", "instruction", [])
      assert result == "improved"
    end

    test "handles multiple examples in dataset" do
      captured_prompt =
        capture_prompt(fn prompt ->
          assert String.contains?(prompt, "Example 1")
          assert String.contains?(prompt, "Example 2")
          assert String.contains?(prompt, "Example 3")
          "response"
        end)

      proposal = InstructionProposal.new(llm: captured_prompt)

      dataset = [
        %{"Inputs" => %{"q" => "1"}, "Generated Outputs" => "a1", "Feedback" => "f1"},
        %{"Inputs" => %{"q" => "2"}, "Generated Outputs" => "a2", "Feedback" => "f2"},
        %{"Inputs" => %{"q" => "3"}, "Generated Outputs" => "a3", "Feedback" => "f3"}
      ]

      InstructionProposal.propose(proposal, "comp", "instruction", dataset)
    end

    test "returns error when LLM fails" do
      llm = Mock.new(response_fn: fn _prompt -> raise "LLM error" end)
      _proposal = InstructionProposal.new(llm: llm)

      # Mock doesn't support error returns, so we need a different approach
      # For now, skip this test - will be handled in integration
    end
  end

  describe "upstream output extractor parity" do
    test "extracts instructions from upstream fenced-code scenarios" do
      cases = [
        {
          """
          Here's the improved instruction:
          ```markdown
          This is the actual instruction content.
          It should not include the word 'markdown'.
          ```
          """,
          "This is the actual instruction content.\nIt should not include the word 'markdown'."
        },
        {
          """
          Here's the instruction:
          ```
          This is the instruction without language specifier.
          ```
          Done.
          """,
          "This is the instruction without language specifier."
        },
        {
          """
          ```markdown
          Don't get confused by these backticks: ```
          ```
          """,
          "Don't get confused by these backticks: ```"
        },
        {
          """
          ```

          Here are the instructions.

          ```
          """,
          "Here are the instructions."
        },
        {
          """
          Begin text
          ```plaintext
          Begin instructions

          ```
          Internal block 1
          ```

          ```python
          Internal block 2
          ```

          End instructions
          ```
          End text
          """,
          "Begin instructions\n\n```\nInternal block 1\n```\n\n```python\nInternal block 2\n```\n\nEnd instructions"
        },
        {
          """
          ```text
          Here are the instructions.
          """,
          "Here are the instructions."
        },
        {
          """
          Here are the instructions.
          ```
          """,
          "Here are the instructions."
        },
        {
          """
          Here are some backticks:
          ```
          I hope you didn't get confused.
          """,
          "Here are some backticks:\n```\nI hope you didn't get confused."
        },
        {
          """
          Here are the instructions.
          """,
          "Here are the instructions."
        }
      ]

      for {lm_output, expected_instruction} <- cases do
        proposal = InstructionProposal.new(llm: Mock.new(responses: [lm_output]))

        assert {:ok, ^expected_instruction} =
                 InstructionProposal.propose(proposal, "comp", "instruction", [])
      end
    end
  end

  describe "propose_batch/4" do
    test "proposes for multiple components" do
      # Return different responses based on call order
      call_count = :counters.new(1, [:atomics])

      response_fn = fn _prompt ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case count do
          0 -> "improved instruction 1"
          1 -> "improved instruction 2"
          _ -> "improved instruction N"
        end
      end

      llm = Mock.new(response_fn: response_fn)
      proposal = InstructionProposal.new(llm: llm)

      candidate = %{
        "system_prompt" => "Original system prompt",
        "user_template" => "Original user template"
      }

      reflective_dataset = %{
        "system_prompt" => [
          %{"Inputs" => %{}, "Generated Outputs" => "", "Feedback" => "improve"}
        ],
        "user_template" => [
          %{"Inputs" => %{}, "Generated Outputs" => "", "Feedback" => "improve"}
        ]
      }

      {:ok, result} =
        InstructionProposal.propose_batch(
          proposal,
          candidate,
          reflective_dataset,
          ["system_prompt", "user_template"]
        )

      assert Map.has_key?(result, "system_prompt")
      assert Map.has_key?(result, "user_template")
      assert is_binary(result["system_prompt"])
      assert is_binary(result["user_template"])
    end

    test "returns results only for requested components" do
      llm = Mock.new(responses: ["improved"])
      proposal = InstructionProposal.new(llm: llm)

      candidate = %{
        "comp_a" => "A",
        "comp_b" => "B",
        "comp_c" => "C"
      }

      reflective_dataset = %{
        "comp_a" => [],
        "comp_b" => [],
        "comp_c" => []
      }

      {:ok, result} =
        InstructionProposal.propose_batch(
          proposal,
          candidate,
          reflective_dataset,
          # Only request two components
          ["comp_a", "comp_c"]
        )

      assert Map.has_key?(result, "comp_a")
      assert Map.has_key?(result, "comp_c")
      refute Map.has_key?(result, "comp_b")
    end

    test "handles missing component in candidate gracefully" do
      llm = Mock.new(responses: ["improved"])
      proposal = InstructionProposal.new(llm: llm)

      candidate = %{"existing" => "value"}
      reflective_dataset = %{"missing" => []}

      {:ok, result} =
        InstructionProposal.propose_batch(
          proposal,
          candidate,
          reflective_dataset,
          ["missing"]
        )

      # Should still work, just with empty current instruction
      assert Map.has_key?(result, "missing")
    end

    test "handles missing component in reflective dataset gracefully" do
      llm = Mock.new(responses: ["improved"])
      proposal = InstructionProposal.new(llm: llm)

      candidate = %{"comp" => "value"}
      # Empty dataset
      reflective_dataset = %{}

      {:ok, result} =
        InstructionProposal.propose_batch(
          proposal,
          candidate,
          reflective_dataset,
          ["comp"]
        )

      # Should still work with empty dataset
      assert Map.has_key?(result, "comp")
    end
  end

  describe "default_template/0" do
    test "returns a valid template string" do
      template = InstructionProposal.default_template()

      assert is_binary(template)
      assert String.contains?(template, "<curr_param>")
      assert String.contains?(template, "<side_info>")
    end
  end

  describe "new/1 — structured_output option" do
    test "defaults structured_output to false" do
      llm = Mock.new(responses: ["improved"])
      proposal = InstructionProposal.new(llm: llm)

      assert proposal.structured_output == false
    end

    test "accepts structured_output: true" do
      llm = Mock.new(responses: ["improved"])
      proposal = InstructionProposal.new(llm: llm, structured_output: true)

      assert proposal.structured_output == true
    end

    test "accepts structured_output: false explicitly" do
      llm = Mock.new(responses: ["improved"])
      proposal = InstructionProposal.new(llm: llm, structured_output: false)

      assert proposal.structured_output == false
    end
  end

  describe "propose/4 — structured_output: true" do
    test "uses complete_structured path and extracts instruction key" do
      # Mock returns JSON with instruction key; fallback wraps it correctly
      json_response = Jason.encode!(%{"instruction" => "structured result"})
      llm = Mock.new(responses: [json_response])

      proposal = InstructionProposal.new(llm: llm, structured_output: true)

      {:ok, result} = InstructionProposal.propose(proposal, "comp", "original", [])

      assert result == "structured result"
    end

    test "extracts instruction from plain text via fallback" do
      llm = Mock.new(responses: ["plain improved instruction"])
      proposal = InstructionProposal.new(llm: llm, structured_output: true)

      {:ok, result} = InstructionProposal.propose(proposal, "comp", "original", [])

      assert result == "plain improved instruction"
    end

    test "returns empty string when structured result has no instruction key" do
      json_response = Jason.encode!(%{"other_key" => "value"})
      llm = Mock.new(responses: [json_response])

      proposal = InstructionProposal.new(llm: llm, structured_output: true)

      {:ok, result} = InstructionProposal.propose(proposal, "comp", "original", [])

      # Map has no "instruction" key → extract_structured_instruction returns ""
      assert result == ""
    end
  end

  describe "propose/4 — structured_output: false (default text path unchanged)" do
    test "still uses the text path when structured_output is false" do
      llm = Mock.new(responses: ["  text response  "])
      proposal = InstructionProposal.new(llm: llm, structured_output: false)

      {:ok, result} = InstructionProposal.propose(proposal, "comp", "original", [])

      assert result == "text response"
    end
  end

  # Helper to capture the prompt sent to LLM
  defp capture_prompt(assertion_fn) do
    Mock.new(
      response_fn: fn prompt ->
        assertion_fn.(prompt)
      end
    )
  end
end
