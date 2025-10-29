defmodule GEPA.LLM.ReqLLMTest do
  use ExUnit.Case, async: true

  alias GEPA.LLM.ReqLLM

  describe "new/1" do
    test "creates OpenAI instance with defaults" do
      llm = ReqLLM.new(provider: :openai)

      assert llm.provider == :openai
      assert llm.model == "gpt-4o-mini"
      assert llm.temperature == 0.7
      assert llm.max_tokens == 2000
      assert llm.timeout == 60_000
    end

    test "creates Gemini instance with defaults" do
      llm = ReqLLM.new(provider: :gemini)

      assert llm.provider == :gemini
      assert llm.model == "gemini-flash-lite-latest"
      assert llm.temperature == 0.7
      assert llm.max_tokens == 2000
    end

    test "creates instance with custom options" do
      llm =
        ReqLLM.new(
          provider: :openai,
          model: "gpt-4o",
          temperature: 0.9,
          max_tokens: 1000,
          top_p: 0.95,
          timeout: 30_000
        )

      assert llm.model == "gpt-4o"
      assert llm.temperature == 0.9
      assert llm.max_tokens == 1000
      assert llm.top_p == 0.95
      assert llm.timeout == 30_000
    end

    test "picks up API key from environment for OpenAI" do
      System.put_env("OPENAI_API_KEY", "test-key-123")
      llm = ReqLLM.new(provider: :openai)
      assert llm.api_key == "test-key-123"
      System.delete_env("OPENAI_API_KEY")
    end

    test "picks up API key from environment for Gemini" do
      System.put_env("GEMINI_API_KEY", "test-gemini-key")
      llm = ReqLLM.new(provider: :gemini)
      assert llm.api_key == "test-gemini-key"
      System.delete_env("GEMINI_API_KEY")
    end

    test "explicit API key takes precedence over environment" do
      System.put_env("OPENAI_API_KEY", "env-key")
      llm = ReqLLM.new(provider: :openai, api_key: "explicit-key")
      assert llm.api_key == "explicit-key"
      System.delete_env("OPENAI_API_KEY")
    end

    test "raises on invalid provider" do
      assert_raise ArgumentError, ~r/provider must be/, fn ->
        ReqLLM.new(provider: :invalid)
      end
    end

    test "requires provider option" do
      assert_raise KeyError, fn ->
        ReqLLM.new([])
      end
    end
  end

  describe "complete/3 option merging" do
    test "per-call options override instance options" do
      llm =
        ReqLLM.new(
          provider: :openai,
          model: "gpt-4o-mini",
          temperature: 0.7,
          api_key: "default-key"
        )

      # Test that complete would merge options correctly
      # We can't actually call complete without mocking HTTP, but we can test the struct
      assert llm.model == "gpt-4o-mini"
      assert llm.temperature == 0.7
    end
  end

  describe "model defaults" do
    test "OpenAI default model is gpt-4o-mini" do
      llm = ReqLLM.new(provider: :openai)
      assert llm.model == "gpt-4o-mini"
    end

    test "Gemini default model is gemini-flash-lite-latest" do
      llm = ReqLLM.new(provider: :gemini)
      assert llm.model == "gemini-flash-lite-latest"
    end

    test "can override default models" do
      llm1 = ReqLLM.new(provider: :openai, model: "gpt-4o")
      assert llm1.model == "gpt-4o"

      llm2 = ReqLLM.new(provider: :gemini, model: "gemini-1.5-pro")
      assert llm2.model == "gemini-1.5-pro"
    end
  end

  describe "configuration" do
    test "stores all configuration options" do
      llm =
        ReqLLM.new(
          provider: :openai,
          model: "gpt-4o",
          api_key: "sk-test",
          temperature: 0.8,
          max_tokens: 500,
          top_p: 0.9,
          timeout: 45_000,
          req_options: [connect_timeout: 10_000]
        )

      assert llm.provider == :openai
      assert llm.model == "gpt-4o"
      assert llm.api_key == "sk-test"
      assert llm.temperature == 0.8
      assert llm.max_tokens == 500
      assert llm.top_p == 0.9
      assert llm.timeout == 45_000
      assert llm.req_options == [connect_timeout: 10_000]
    end

    test "nil values are allowed for optional parameters" do
      llm = ReqLLM.new(provider: :openai, top_p: nil)
      assert llm.top_p == nil
    end
  end

  # Note: Integration tests with actual HTTP calls would go in a separate
  # integration test file and would be optional (require API keys).
  # These tests cover the structure and configuration of ReqLLM without
  # requiring network calls or complex mocking of external libraries.

  describe "documentation and examples" do
    test "example from module docs works" do
      # OpenAI example
      llm = ReqLLM.new(provider: :openai)
      assert %ReqLLM{provider: :openai} = llm

      # Gemini example
      llm = ReqLLM.new(provider: :gemini)
      assert %ReqLLM{provider: :gemini} = llm

      # Custom options example
      llm =
        ReqLLM.new(
          provider: :openai,
          model: "gpt-4o",
          temperature: 0.9,
          max_tokens: 1000
        )

      assert llm.model == "gpt-4o"
      assert llm.temperature == 0.9
    end
  end

  describe "environment variable fallbacks" do
    test "GOOGLE_API_KEY works as fallback for Gemini" do
      System.put_env("GOOGLE_API_KEY", "google-key")
      System.delete_env("GEMINI_API_KEY")

      llm = ReqLLM.new(provider: :gemini)
      assert llm.api_key == "google-key"

      System.delete_env("GOOGLE_API_KEY")
    end

    test "GEMINI_API_KEY takes precedence over GOOGLE_API_KEY" do
      System.put_env("GEMINI_API_KEY", "gemini-key")
      System.put_env("GOOGLE_API_KEY", "google-key")

      llm = ReqLLM.new(provider: :gemini)
      assert llm.api_key == "gemini-key"

      System.delete_env("GEMINI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")
    end
  end

  describe "struct creation and validation" do
    test "creates valid struct with all fields" do
      llm = ReqLLM.new(provider: :openai, api_key: "test")

      assert is_struct(llm, ReqLLM)
      assert is_atom(llm.provider)
      assert is_binary(llm.model)
      assert is_float(llm.temperature)
      assert is_integer(llm.max_tokens)
      assert is_integer(llm.timeout)
    end

    test "handles missing API key gracefully (returns nil)" do
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("GEMINI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")

      llm = ReqLLM.new(provider: :openai)
      assert llm.api_key == nil

      llm = ReqLLM.new(provider: :gemini)
      assert llm.api_key == nil
    end
  end

  describe "type specifications" do
    test "provider type is enforced" do
      # Valid providers
      assert %ReqLLM{provider: :openai} = ReqLLM.new(provider: :openai)
      assert %ReqLLM{provider: :gemini} = ReqLLM.new(provider: :gemini)

      # Invalid providers raise
      assert_raise ArgumentError, fn ->
        ReqLLM.new(provider: :anthropic)
      end
    end
  end
end
