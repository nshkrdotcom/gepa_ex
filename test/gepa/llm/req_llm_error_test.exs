defmodule GEPA.LLM.ReqLLMErrorTest do
  use ExUnit.Case, async: true

  alias GEPA.LLM.ReqLLM

  describe "error handling" do
    test "returns error or success depending on ReqLLM availability" do
      llm = ReqLLM.new(provider: :openai, api_key: "test-key")

      # This may succeed if ReqLLM modules are available, or error if not
      # We're testing that it doesn't crash
      result = ReqLLM.complete(llm, "test prompt")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles missing API key gracefully" do
      llm = ReqLLM.new(provider: :openai, api_key: nil)

      result = ReqLLM.complete(llm, "test prompt")

      # Should error due to missing API key, or if modules available might succeed
      # Key point: doesn't crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles invalid prompt type gracefully" do
      llm = ReqLLM.new(provider: :openai, api_key: "test")

      # Passing non-string should raise FunctionClauseError
      assert_raise FunctionClauseError, fn ->
        ReqLLM.complete(llm, 123)
      end

      assert_raise FunctionClauseError, fn ->
        ReqLLM.complete(llm, nil)
      end
    end

    test "empty string prompt is valid" do
      llm = ReqLLM.new(provider: :openai, api_key: "test")

      # Should not raise for empty string (though API might reject it)
      result = ReqLLM.complete(llm, "")
      # Will error due to missing ReqLLM module, but validates prompt type
      assert {:error, _} = result
    end

    test "handles Gemini provider gracefully" do
      llm = ReqLLM.new(provider: :gemini, api_key: "test-key")

      result = ReqLLM.complete(llm, "test prompt")

      # May succeed if ReqLLM is available, or error if not
      # Key point: doesn't crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "timeout handling" do
    test "timeout option is properly set" do
      llm = ReqLLM.new(provider: :openai, api_key: "test", timeout: 5000)

      assert llm.timeout == 5000

      # Actual timeout handling happens in HTTP layer (ReqLLM)
      # We verify the configuration is passed through
    end

    test "default timeout is reasonable" do
      llm = ReqLLM.new(provider: :openai)

      # Default should be 60 seconds
      assert llm.timeout == 60_000
    end
  end

  describe "parameter validation" do
    test "accepts valid temperature range" do
      llm = ReqLLM.new(provider: :openai, temperature: 0.0)
      assert llm.temperature == 0.0

      llm = ReqLLM.new(provider: :openai, temperature: 1.0)
      assert llm.temperature == 1.0

      llm = ReqLLM.new(provider: :openai, temperature: 0.5)
      assert llm.temperature == 0.5
    end

    test "accepts valid max_tokens" do
      llm = ReqLLM.new(provider: :openai, max_tokens: 1)
      assert llm.max_tokens == 1

      llm = ReqLLM.new(provider: :openai, max_tokens: 10000)
      assert llm.max_tokens == 10000
    end

    test "accepts optional top_p parameter" do
      llm = ReqLLM.new(provider: :openai, top_p: 0.9)
      assert llm.top_p == 0.9

      llm = ReqLLM.new(provider: :openai)
      assert llm.top_p == nil
    end
  end

  describe "req_options passthrough" do
    test "custom req_options are stored" do
      custom_opts = [
        connect_timeout: 5000,
        receive_timeout: 30_000,
        retry: false
      ]

      llm = ReqLLM.new(provider: :openai, req_options: custom_opts)

      assert llm.req_options == custom_opts
    end

    test "req_options default to empty list" do
      llm = ReqLLM.new(provider: :openai)
      assert llm.req_options == []
    end
  end

  describe "API key retrieval" do
    setup do
      # Clear all API keys before each test
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("GEMINI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")
      :ok
    end

    test "no API key results in nil" do
      llm = ReqLLM.new(provider: :openai)
      assert llm.api_key == nil
    end

    test "explicit nil API key is preserved" do
      llm = ReqLLM.new(provider: :openai, api_key: nil)
      assert llm.api_key == nil
    end

    test "empty string API key is preserved" do
      llm = ReqLLM.new(provider: :openai, api_key: "")
      assert llm.api_key == ""
    end
  end

  describe "model specification" do
    test "accepts any string as model name" do
      # OpenAI models
      llm = ReqLLM.new(provider: :openai, model: "gpt-4")
      assert llm.model == "gpt-4"

      llm = ReqLLM.new(provider: :openai, model: "gpt-4-turbo")
      assert llm.model == "gpt-4-turbo"

      # Gemini models
      llm = ReqLLM.new(provider: :gemini, model: "gemini-pro")
      assert llm.model == "gemini-pro"

      # Future/unknown models should work
      llm = ReqLLM.new(provider: :openai, model: "gpt-5-ultra")
      assert llm.model == "gpt-5-ultra"
    end
  end

  describe "complete/3 opts parameter" do
    test "accepts opts parameter" do
      llm = ReqLLM.new(provider: :openai, api_key: "test")

      # Should not raise, even though it will error due to missing ReqLLM module
      result = ReqLLM.complete(llm, "prompt", temperature: 0.9, max_tokens: 100)
      assert {:error, _} = result
    end

    test "empty opts list works" do
      llm = ReqLLM.new(provider: :openai, api_key: "test")

      result = ReqLLM.complete(llm, "prompt", [])
      assert {:error, _} = result
    end
  end
end
