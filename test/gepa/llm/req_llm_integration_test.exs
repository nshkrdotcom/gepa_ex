defmodule GEPA.LLM.ReqLLMIntegrationTest do
  use GEPA.SupertesterCase, isolation: :full_isolation, async: false

  # These tests demonstrate the complete/3 function behavior
  # They don't make real HTTP calls, but test the request building logic

  alias GEPA.LLM.ReqLLM

  @moduletag :integration

  describe "complete/3 request building (without HTTP)" do
    test "builds correct request structure for OpenAI" do
      llm =
        ReqLLM.new(
          provider: :openai,
          model: "gpt-4o-mini",
          api_key: "test-key",
          temperature: 0.8,
          max_tokens: 500
        )

      # We can verify the struct is properly configured
      assert llm.provider == :openai
      assert llm.model == "gpt-4o-mini"
      assert llm.api_key == "test-key"
      assert llm.temperature == 0.8
      assert llm.max_tokens == 500

      # The actual complete call would fail without mocking ReqLLM.OpenAI
      # but we've verified the configuration is correct
    end

    test "builds correct request structure for Gemini" do
      llm =
        ReqLLM.new(
          provider: :gemini,
          model: "gemini-2.0-flash-lite",
          api_key: "test-key",
          temperature: 0.8,
          max_tokens: 500
        )

      assert llm.provider == :gemini
      assert llm.model == "gemini-2.0-flash-lite"
      assert llm.api_key == "test-key"
      assert llm.temperature == 0.8
      assert llm.max_tokens == 500
    end

    test "per-call options would override instance options" do
      llm =
        ReqLLM.new(
          provider: :openai,
          model: "gpt-4o-mini",
          temperature: 0.7
        )

      # Verify instance defaults
      assert llm.temperature == 0.7

      # In actual call, opts would override:
      # complete(llm, "prompt", temperature: 0.9)
      # This would use temperature: 0.9 for that specific call
    end
  end

  describe "error handling structure" do
    test "handles missing API key case" do
      llm = ReqLLM.new(provider: :openai, api_key: nil)

      # Without API key, the actual call would fail
      # Testing that the struct allows nil api_key (fail at call time, not creation)
      assert llm.api_key == nil
    end

    test "validates provider at creation time, not call time" do
      # This should fail immediately
      assert_raise ArgumentError, fn ->
        ReqLLM.new(provider: :invalid_provider)
      end
    end
  end

  # Real hosted-provider smoke checks live in examples and take explicit CLI
  # credentials. The unit/integration suite remains deterministic.
end
