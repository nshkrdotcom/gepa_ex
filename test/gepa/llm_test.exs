defmodule GEPA.LLMTest do
  use GEPA.SupertesterCase, isolation: :full_isolation
  doctest GEPA.LLM

  alias GEPA.LLM.Mock

  describe "GEPA.LLM behavior" do
    test "complete/3 delegates to module's implementation" do
      llm = Mock.new(responses: ["Test response"])
      {:ok, response} = GEPA.LLM.complete(llm, "test prompt")
      assert response == "Test response"
    end

    test "default/0 returns a Mock when no provider is configured" do
      original = Application.get_env(:gepa_ex, :llm, [])

      try do
        Application.delete_env(:gepa_ex, :llm)
        assert %Mock{} = GEPA.LLM.default()
      after
        Application.put_env(:gepa_ex, :llm, original)
      end
    end

    test "default/0 returns a Mock when the provider is :mock" do
      original = Application.get_env(:gepa_ex, :llm, [])

      try do
        Application.put_env(:gepa_ex, :llm, provider: :mock)
        assert %Mock{} = GEPA.LLM.default()
      after
        Application.put_env(:gepa_ex, :llm, original)
      end
    end

    test "default/0 raises for a non-mock provider (built-in network providers were removed)" do
      original = Application.get_env(:gepa_ex, :llm, [])

      try do
        Application.put_env(:gepa_ex, :llm, provider: :openai)
        assert_raise ArgumentError, fn -> GEPA.LLM.default() end
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
  end
end
