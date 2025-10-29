defmodule GEPA.LLMTest do
  use ExUnit.Case, async: true
  doctest GEPA.LLM

  describe "GEPA.LLM behavior" do
    test "complete/3 delegates to module's implementation" do
      llm = GEPA.LLM.Mock.new(responses: ["Test response"])
      {:ok, response} = GEPA.LLM.complete(llm, "test prompt")
      assert response == "Test response"
    end

    test "default/0 returns ReqLLM with OpenAI by default" do
      llm = GEPA.LLM.default()
      assert %GEPA.LLM.ReqLLM{provider: :openai} = llm
    end

    test "default/0 respects application config" do
      original = Application.get_env(:gepa_ex, :llm, [])

      try do
        Application.put_env(:gepa_ex, :llm, provider: :gemini)
        llm = GEPA.LLM.default()
        assert %GEPA.LLM.ReqLLM{provider: :gemini} = llm
      after
        Application.put_env(:gepa_ex, :llm, original)
      end
    end
  end
end
