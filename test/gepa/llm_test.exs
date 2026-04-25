defmodule GEPA.LLMTest do
  use GEPA.SupertesterCase, isolation: :full_isolation
  doctest GEPA.LLM

  alias GEPA.LLM.Mock
  alias GEPA.LLM.ReqLLM

  describe "GEPA.LLM behavior" do
    test "complete/3 delegates to module's implementation" do
      llm = Mock.new(responses: ["Test response"])
      {:ok, response} = GEPA.LLM.complete(llm, "test prompt")
      assert response == "Test response"
    end

    test "default/0 returns ReqLLM with OpenAI by default" do
      llm = GEPA.LLM.default()
      assert %ReqLLM{provider: :openai} = llm
    end

    test "default/0 respects application config" do
      original = Application.get_env(:gepa_ex, :llm, [])

      try do
        Application.put_env(:gepa_ex, :llm, provider: :gemini)
        llm = GEPA.LLM.default()
        assert %ReqLLM{provider: :gemini} = llm
      after
        Application.put_env(:gepa_ex, :llm, original)
      end
    end

    test "default/0 routes Anthropic through ReqLLM compatibility wrapper" do
      original = Application.get_env(:gepa_ex, :llm, [])

      try do
        Application.put_env(:gepa_ex, :llm, provider: :anthropic)
        llm = GEPA.LLM.default()
        assert %ReqLLM{provider: :anthropic} = llm
      after
        Application.put_env(:gepa_ex, :llm, original)
      end
    end
  end

  describe "complete_structured/3 — fallback path (Mock has no complete_structured/3)" do
    test "wraps plain text response as %{\"instruction\" => text}" do
      llm = Mock.new(responses: ["some improved instruction"])

      assert {:ok, %{"instruction" => "some improved instruction"}} =
               GEPA.LLM.complete_structured(llm, "propose something")
    end

    test "parses valid JSON with instruction key" do
      json = Jason.encode!(%{"instruction" => "json instruction"})
      llm = Mock.new(responses: [json])

      assert {:ok, %{"instruction" => "json instruction"}} =
               GEPA.LLM.complete_structured(llm, "prompt")
    end

    test "parses valid JSON without instruction key as-is" do
      json = Jason.encode!(%{"other_key" => "value"})
      llm = Mock.new(responses: [json])

      assert {:ok, %{"other_key" => "value"}} =
               GEPA.LLM.complete_structured(llm, "prompt")
    end

    test "wraps non-JSON text as instruction string after trimming" do
      llm = Mock.new(responses: ["  just text with whitespace  "])

      assert {:ok, %{"instruction" => "just text with whitespace"}} =
               GEPA.LLM.complete_structured(llm, "prompt")
    end
  end

  describe "complete_structured/3 — dispatch" do
    test "Mock does not export complete_structured/3" do
      refute function_exported?(Mock, :complete_structured, 3)
    end

    test "falls back for Mock (no complete_structured exported)" do
      llm = Mock.new(responses: ["fallback response"])

      assert {:ok, %{"instruction" => "fallback response"}} =
               GEPA.LLM.complete_structured(llm, "prompt")
    end

    test "dispatches to ReqLLM Anthropic wrapper when configured" do
      llm = ReqLLM.new(provider: :anthropic, api_key: nil)

      assert {:error, reason} = GEPA.LLM.complete_structured(llm, "hello")
      reason_text = reason |> inspect() |> String.downcase()
      assert String.contains?(reason_text, "api")

      assert String.contains?(reason_text, "key") or
               String.contains?(reason_text, "authentication")
    end
  end
end
