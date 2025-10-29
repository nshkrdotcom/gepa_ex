defmodule GEPA.LLM.MockTest do
  use ExUnit.Case, async: true
  doctest GEPA.LLM.Mock

  describe "new/1" do
    test "creates a mock with default options" do
      llm = GEPA.LLM.Mock.new()
      assert %GEPA.LLM.Mock{} = llm
      assert llm.responses == nil
      assert llm.response_fn == nil
      assert llm.call_count == 0
    end

    test "creates a mock with fixed responses" do
      llm = GEPA.LLM.Mock.new(responses: ["Response 1", "Response 2"])
      assert llm.responses == ["Response 1", "Response 2"]
    end

    test "creates a mock with response function" do
      response_fn = fn prompt -> "Echo: #{prompt}" end
      llm = GEPA.LLM.Mock.new(response_fn: response_fn)
      assert is_function(llm.response_fn, 1)
    end
  end

  describe "complete/3 with fixed responses" do
    test "always returns first response from list" do
      llm = GEPA.LLM.Mock.new(responses: ["First", "Second", "Third"])

      {:ok, response1} = GEPA.LLM.Mock.complete(llm, "prompt 1")
      assert response1 == "First"

      {:ok, response2} = GEPA.LLM.Mock.complete(llm, "prompt 2")
      # Always returns first
      assert response2 == "First"

      {:ok, response3} = GEPA.LLM.Mock.complete(llm, "prompt 3")
      assert response3 == "First"
    end

    test "handles single response" do
      llm = GEPA.LLM.Mock.new(responses: ["Only response"])

      {:ok, response1} = GEPA.LLM.Mock.complete(llm, "prompt 1")
      {:ok, response2} = GEPA.LLM.Mock.complete(llm, "prompt 2")

      assert response1 == "Only response"
      assert response2 == "Only response"
    end

    test "for varying responses use response_fn with closure" do
      # Example: cycling through responses with closure state
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      llm =
        GEPA.LLM.Mock.new(
          response_fn: fn _prompt ->
            count = Agent.get_and_update(agent, fn c -> {c, c + 1} end)
            responses = ["First", "Second", "Third"]
            Enum.at(responses, rem(count, length(responses)))
          end
        )

      {:ok, r1} = GEPA.LLM.Mock.complete(llm, "p1")
      {:ok, r2} = GEPA.LLM.Mock.complete(llm, "p2")
      {:ok, r3} = GEPA.LLM.Mock.complete(llm, "p3")
      {:ok, r4} = GEPA.LLM.Mock.complete(llm, "p4")

      assert r1 == "First"
      assert r2 == "Second"
      assert r3 == "Third"
      # Cycles
      assert r4 == "First"

      Agent.stop(agent)
    end
  end

  describe "complete/3 with response function" do
    test "uses provided function to generate responses" do
      llm = GEPA.LLM.Mock.new(response_fn: fn prompt -> "Echo: #{prompt}" end)

      {:ok, response1} = GEPA.LLM.Mock.complete(llm, "hello")
      assert response1 == "Echo: hello"

      {:ok, response2} = GEPA.LLM.Mock.complete(llm, "world")
      assert response2 == "Echo: world"
    end

    test "response function can access prompt content" do
      llm =
        GEPA.LLM.Mock.new(
          response_fn: fn prompt ->
            if String.contains?(prompt, "question") do
              "Answer"
            else
              "Default"
            end
          end
        )

      {:ok, response1} = GEPA.LLM.Mock.complete(llm, "This is a question")
      assert response1 == "Answer"

      {:ok, response2} = GEPA.LLM.Mock.complete(llm, "This is a statement")
      assert response2 == "Default"
    end
  end

  describe "complete/3 with default behavior" do
    test "generates improved instruction for prompts with code blocks" do
      llm = GEPA.LLM.Mock.new()

      {:ok, response} = GEPA.LLM.Mock.complete(llm, "```\nSome instruction\n```")

      assert response =~ "```"
      assert response =~ "Improved instruction"
      assert response =~ "feedback"
    end

    test "generates generic instruction for simple prompts" do
      llm = GEPA.LLM.Mock.new()

      {:ok, response} = GEPA.LLM.Mock.complete(llm, "Simple prompt")

      assert response =~ "```"
      assert response =~ "instruction"
    end
  end

  describe "complete/3 honors opts parameter" do
    test "accepts opts but doesn't modify behavior (mock ignores them)" do
      llm = GEPA.LLM.Mock.new(responses: ["Response"])

      {:ok, response} = GEPA.LLM.Mock.complete(llm, "prompt", temperature: 0.9, max_tokens: 100)

      assert response == "Response"
    end
  end

  describe "legacy API compatibility" do
    test "generate/1 works with backward compatibility" do
      {:ok, response} = GEPA.LLM.Mock.generate("Test prompt")
      assert is_binary(response)
      assert response =~ "```"
    end

    test "complete/1 with messages list works" do
      messages = [
        %{role: "user", content: "What is 2+2?"}
      ]

      {:ok, result} = GEPA.LLM.Mock.complete(messages)
      assert result.content =~ "Answer:"
    end
  end
end
