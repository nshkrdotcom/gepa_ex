defmodule GEPA.LLM do
  @moduledoc """
  Behavior for Language Model integrations.

  This module defines the interface that all LLM providers must implement
  to work with GEPA. It provides a simple, unified API for text completion
  across different LLM providers.

  ## Implementations

  - `GEPA.LLM.ReqLLM` - Production implementation using ReqLLM library
    - Supports OpenAI (default: gpt-4o-mini)
    - Supports Google Gemini (default: gemini-2.0-flash-exp)
  - `GEPA.LLM.Mock` - Mock implementation for testing

  ## Configuration

  LLM providers can be configured via application config or runtime options:

      config :gepa_ex, :llm,
        provider: :openai,
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-4o-mini",
        temperature: 0.7

  Or at runtime:

      llm = GEPA.LLM.ReqLLM.new(
        provider: :gemini,
        api_key: System.get_env("GEMINI_API_KEY"),
        model: "gemini-2.0-flash-exp"
      )

      {:ok, response} = GEPA.LLM.complete(llm, prompt, temperature: 0.9)

  ## Example

      # Using OpenAI
      llm = GEPA.LLM.ReqLLM.new(provider: :openai)
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA")

      # Using Gemini
      llm = GEPA.LLM.ReqLLM.new(provider: :gemini)
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA")

      # Using Mock (for testing)
      llm = GEPA.LLM.Mock.new(responses: ["Fixed response"])
      {:ok, response} = GEPA.LLM.complete(llm, "Any prompt")
  """

  @type t :: module() | map()

  @type completion_opts :: [
          temperature: float(),
          max_tokens: pos_integer(),
          top_p: float(),
          model: String.t(),
          timeout: pos_integer()
        ]

  @doc """
  Completes a prompt using the LLM provider.

  ## Parameters

    - `llm` - LLM provider instance
    - `prompt` - Text prompt to complete
    - `opts` - Optional parameters (temperature, max_tokens, etc.)

  ## Returns

    - `{:ok, response}` - Successful completion with response text
    - `{:error, reason}` - Error with reason

  ## Examples

      {:ok, response} = GEPA.LLM.complete(llm, "What is 2+2?")
      {:ok, response} = GEPA.LLM.complete(llm, prompt, temperature: 0.9, max_tokens: 500)
  """
  @callback complete(llm :: t(), prompt :: String.t(), opts :: completion_opts()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Convenience function to call complete/3 on any LLM implementation.

  Delegates to the appropriate module's complete/3 callback.
  """
  @spec complete(t(), String.t(), completion_opts()) :: {:ok, String.t()} | {:error, term()}
  def complete(llm, prompt, opts \\ [])

  def complete(%module{} = llm, prompt, opts) when is_atom(module) do
    module.complete(llm, prompt, opts)
  end

  def complete(module, prompt, opts) when is_atom(module) do
    module.complete(module, prompt, opts)
  end

  @doc """
  Returns the default LLM provider based on application configuration.

  Priority:
  1. Application config `:gepa_ex, :llm`
  2. Environment variable `GEPA_LLM_PROVIDER`
  3. Falls back to OpenAI via ReqLLM

  ## Examples

      # With config set
      config :gepa_ex, :llm, provider: :gemini
      llm = GEPA.LLM.default()

      # Without config (uses OpenAI)
      llm = GEPA.LLM.default()
  """
  @spec default() :: t()
  def default do
    config = Application.get_env(:gepa_ex, :llm, [])

    provider =
      Keyword.get(config, :provider) ||
        parse_env_provider(System.get_env("GEPA_LLM_PROVIDER")) ||
        :openai

    GEPA.LLM.ReqLLM.new(Keyword.put(config, :provider, provider))
  end

  defp parse_env_provider(nil), do: nil
  defp parse_env_provider("openai"), do: :openai
  defp parse_env_provider("gemini"), do: :gemini
  defp parse_env_provider("mock"), do: :mock
  defp parse_env_provider(_), do: nil
end
