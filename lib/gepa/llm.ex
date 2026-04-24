defmodule GEPA.LLM do
  @moduledoc """
  Behavior and facade for Language Model integrations.

  This module defines the interface that all LLM providers must implement
  to work with GEPA. It provides a simple, unified API for text completion
  across different LLM providers.

  ## Implementations

  - `GEPA.LLM.Adapters.ReqLLM` - Hosted provider adapter using ReqLLM
    - Supports OpenAI, Google Gemini, and Anthropic
  - `GEPA.LLM.Adapters.AgentSessionManager` - Local CLI/agent adapter using ASM
    - Supports Claude, Codex, Gemini, and Amp where ASM supports them
  - `GEPA.LLM.ReqLLM` - Backward-compatible wrapper around the ReqLLM adapter
  - `GEPA.LLM.Mock` - Mock implementation for testing

  ## Configuration

  LLM providers can be configured via application config or explicit runtime options:

      config :gepa_ex, :llm,
        provider: :openai,
        api_key: "sk-...",
        model: "gpt-5.4-mini",
        temperature: 0.7

  Or at runtime:

      llm = GEPA.LLM.req_llm(
        :gemini,
        api_key: "...",
        model: "gemini-flash-lite-latest"
      )

      {:ok, response} = GEPA.LLM.complete(llm, prompt, temperature: 0.9)

  ## Example

      # Using OpenAI through the ReqLLM adapter
      llm = GEPA.LLM.req_llm(:openai, api_key: "sk-...")
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA")

      # Using Gemini through the ReqLLM adapter
      llm = GEPA.LLM.req_llm(:gemini, api_key: "...")
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA")

      # Using Anthropic Claude through the ReqLLM adapter
      llm = GEPA.LLM.req_llm(:anthropic, api_key: "...")
      {:ok, response} = GEPA.LLM.complete(llm, "Explain GEPA")

      # Using Mock (for testing)
      llm = GEPA.LLM.Mock.new(responses: ["Fixed response"])
      {:ok, response} = GEPA.LLM.complete(llm, "Any prompt")
  """

  alias GEPA.LLM.{Adapters, Client, Mock, ReqLLM, Request, Response}

  @type t :: module() | map() | Client.t()

  @type completion_opts :: [
          temperature: float(),
          max_tokens: pos_integer(),
          top_p: float(),
          model: String.t(),
          timeout: pos_integer()
        ]

  @type structured_result :: {:ok, map()} | {:error, term()}

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
  Completes a prompt using the LLM provider and returns a structured map.

  Providers that support native tool_use / function calling implement this
  callback to force well-formed JSON output.  Providers that do not implement
  it fall back to `complete/3` with JSON parsing via `fallback_complete_structured/3`.

  ## Returns

    - `{:ok, map}` - Structured result (always includes at least `"instruction"` key)
    - `{:error, reason}` - Error with reason
  """
  @callback complete_structured(llm :: t(), prompt :: String.t(), opts :: completion_opts()) ::
              structured_result()

  @optional_callbacks complete_structured: 3

  @doc """
  Builds a normalized GEPA LLM client.
  """
  @spec new(:req_llm | :agent_session_manager | :asm, keyword()) :: Client.t()
  def new(:req_llm, opts) do
    provider = Keyword.fetch!(opts, :provider)
    req_llm(provider, Keyword.delete(opts, :provider))
  end

  def new(adapter, opts) when adapter in [:agent_session_manager, :asm] do
    provider = Keyword.fetch!(opts, :provider)
    agent(provider, Keyword.delete(opts, :provider))
  end

  @doc """
  Builds a hosted-provider client backed by ReqLLM.
  """
  @spec req_llm(atom(), keyword()) :: Client.t()
  def req_llm(provider, opts \\ []) when is_atom(provider) do
    opts
    |> Keyword.put(:provider, provider)
    |> Adapters.ReqLLM.new!()
  end

  @doc """
  Builds a local CLI/agent client backed by Agent Session Manager.
  """
  @spec agent(atom(), keyword()) :: Client.t()
  def agent(provider, opts \\ []) when is_atom(provider) do
    opts
    |> Keyword.put(:provider, provider)
    |> Adapters.AgentSessionManager.new!()
  end

  @doc """
  Convenience function to call complete/3 on any LLM implementation.

  Delegates to the appropriate module's complete/3 callback.
  """
  @spec complete(t(), String.t(), completion_opts()) :: {:ok, String.t()} | {:error, term()}
  def complete(llm, prompt, opts \\ [])

  def complete(%Client{} = client, prompt, opts) when is_binary(prompt) do
    request = Request.from_prompt(prompt, opts)

    with {:ok, %Response{} = response} <- client.adapter.complete(client, request) do
      {:ok, Response.text(response)}
    end
  end

  def complete(%module{} = llm, prompt, opts) when is_atom(module) do
    module.complete(llm, prompt, opts)
  end

  def complete(module, prompt, opts) when is_atom(module) do
    module.complete(module, prompt, opts)
  end

  @doc """
  Streams a prompt when the selected normalized client supports streaming.
  """
  @spec stream(t(), String.t(), completion_opts()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(%Client{} = client, prompt, opts \\ []) when is_binary(prompt) do
    request =
      prompt
      |> Request.from_prompt(opts)
      |> Map.put(:stream?, true)

    client.adapter.stream(client, request)
  end

  @doc """
  Completes a prompt and returns a structured map.

  Dispatches to the provider's `complete_structured/3` when available;
  falls back to `complete/3` with JSON parsing otherwise.

  ## Examples

      {:ok, %{"instruction" => text}} = GEPA.LLM.complete_structured(llm, prompt)
  """
  @spec complete_structured(t(), String.t(), completion_opts()) :: structured_result()
  def complete_structured(llm, prompt, opts \\ [])

  def complete_structured(%Client{} = client, prompt, opts) when is_binary(prompt) do
    request =
      Request.structured(
        prompt,
        Keyword.put_new(opts, :schema, Adapters.ReqLLM.instruction_schema())
      )

    with {:ok, %Response{object: object} = response} <- client.adapter.complete(client, request) do
      if is_map(object) do
        {:ok, object}
      else
        {:ok, %{"instruction" => Response.text(response)}}
      end
    end
  end

  def complete_structured(%module{} = llm, prompt, opts) when is_atom(module) do
    if function_exported?(module, :complete_structured, 3) do
      module.complete_structured(llm, prompt, opts)
    else
      fallback_complete_structured(llm, prompt, opts)
    end
  end

  def complete_structured(module, prompt, opts) when is_atom(module) do
    if function_exported?(module, :complete_structured, 3) do
      module.complete_structured(module, prompt, opts)
    else
      fallback_complete_structured(module, prompt, opts)
    end
  end

  defp fallback_complete_structured(llm, prompt, opts) do
    case complete(llm, prompt, opts) do
      {:ok, text} -> parse_instruction_json(text)
      {:error, _} = err -> err
    end
  end

  defp parse_instruction_json(text) do
    trimmed = String.trim(text)

    case Jason.decode(trimmed) do
      {:ok, %{"instruction" => _} = map} -> {:ok, map}
      {:ok, map} when is_map(map) -> {:ok, map}
      {:error, _} -> {:ok, %{"instruction" => trimmed}}
    end
  end

  @doc """
  Returns the default LLM provider based on application configuration.

  Priority:
  1. Application config `:gepa_ex, :llm`
  2. Falls back to OpenAI via ReqLLM

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

    provider = Keyword.get(config, :provider, :openai)

    build_default_llm(provider, config)
  end

  defp build_default_llm(:mock, _config), do: Mock.new()

  defp build_default_llm(provider, config) do
    ReqLLM.new(Keyword.put(config, :provider, provider))
  end
end
