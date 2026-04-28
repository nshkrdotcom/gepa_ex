defmodule GEPA.LLM do
  @moduledoc """
  Behavior and facade for Language Model integrations.

  GEPA optimizers talk to LLMs through this normalized facade rather than
  provider-specific code. The facade accepts plain text prompts and
  OpenAI-compatible chat/multimodal message lists; adapters can decide how much
  of that surface they support.
  """

  alias GEPA.LLM.{Adapters, Client, Mock, ReqLLM, Request, Response, Tracking}

  @type prompt :: String.t() | [map()]
  @type t :: module() | map() | Client.t() | function()

  @type completion_opts :: keyword()

  @type structured_result :: {:ok, map()} | {:error, term()}

  @callback complete(llm :: t(), prompt :: prompt(), opts :: completion_opts()) ::
              {:ok, String.t()} | {:error, term()}

  @callback complete_structured(llm :: t(), prompt :: prompt(), opts :: completion_opts()) ::
              structured_result()

  @optional_callbacks complete_structured: 3

  @doc "Builds a normalized GEPA LLM client."
  @spec new(:req_llm | :agent_session_manager | :asm, keyword()) :: Client.t()
  def new(:req_llm, opts) do
    provider = Keyword.fetch!(opts, :provider)
    req_llm(provider, Keyword.delete(opts, :provider))
  end

  def new(adapter, opts) when adapter in [:agent_session_manager, :asm] do
    provider = Keyword.fetch!(opts, :provider)
    agent(provider, Keyword.delete(opts, :provider))
  end

  @doc "Builds a hosted-provider client backed by ReqLLM."
  @spec req_llm(atom(), keyword()) :: Client.t()
  def req_llm(provider, opts \\ []) when is_atom(provider) do
    opts
    |> Keyword.put(:provider, provider)
    |> Adapters.ReqLLM.new!()
  end

  @doc "Builds a local CLI/agent client backed by Agent Session Manager."
  @spec agent(atom(), keyword()) :: Client.t()
  def agent(provider, opts \\ []) when is_atom(provider) do
    opts
    |> Keyword.put(:provider, provider)
    |> Adapters.AgentSessionManager.new!()
  end

  @doc "Wrap a one- or two-arity callable in a cost/token tracking LLM."
  @spec track(function() | t()) :: Tracking.t() | t()
  def track(%Tracking{} = tracking), do: tracking

  def track(callable) when is_function(callable, 1) or is_function(callable, 2),
    do: Tracking.new(callable)

  def track(other), do: other

  @doc "Convenience function to call complete/3 on any LLM implementation."
  @spec complete(t(), prompt(), completion_opts()) :: {:ok, String.t()} | {:error, term()}
  def complete(llm, prompt, opts \\ [])

  def complete(%Client{} = client, prompt, opts) when is_binary(prompt) or is_list(prompt) do
    request = Request.from_prompt(prompt, opts)

    with {:ok, %Response{} = response} <- client.adapter.complete(client, request) do
      {:ok, Response.text(response)}
    end
  end

  def complete(fun, prompt, opts) when is_function(fun, 2) do
    fun.(prompt, opts) |> normalize_callable_response()
  rescue
    error -> {:error, Exception.message(error)}
  end

  def complete(fun, prompt, _opts) when is_function(fun, 1) do
    fun.(prompt) |> normalize_callable_response()
  rescue
    error -> {:error, Exception.message(error)}
  end

  def complete(%module{} = llm, prompt, opts) when is_atom(module) do
    module.complete(llm, prompt, opts)
  end

  def complete(module, prompt, opts) when is_atom(module) do
    module.complete(module, prompt, opts)
  end

  @doc "Streams a prompt when the selected normalized client supports streaming."
  @spec stream(t(), prompt(), completion_opts()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(%Client{} = client, prompt, opts \\ []) when is_binary(prompt) or is_list(prompt) do
    request =
      prompt
      |> Request.from_prompt(opts)
      |> Map.put(:stream?, true)

    client.adapter.stream(client, request)
  end

  @doc "Completes a prompt and returns a structured map."
  @spec complete_structured(t(), prompt(), completion_opts()) :: structured_result()
  def complete_structured(llm, prompt, opts \\ [])

  def complete_structured(%Client{} = client, prompt, opts)
      when is_binary(prompt) or is_list(prompt) do
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

  def complete_structured(fun, prompt, opts) when is_function(fun, 2) do
    fun.(prompt, opts)
    |> normalize_callable_response()
    |> case do
      {:ok, text} -> parse_instruction_json(text)
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def complete_structured(fun, prompt, opts) when is_function(fun, 1) do
    fallback_complete_structured(fun, prompt, opts)
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

  defp normalize_callable_response({:ok, %Response{} = response}),
    do: {:ok, Response.text(response)}

  defp normalize_callable_response({:ok, response}) when is_binary(response), do: {:ok, response}

  defp normalize_callable_response({:ok, %{content: content}}) when is_binary(content),
    do: {:ok, content}

  defp normalize_callable_response({:ok, %{text: text}}) when is_binary(text), do: {:ok, text}
  defp normalize_callable_response({:error, _} = error), do: error
  defp normalize_callable_response(response) when is_binary(response), do: {:ok, response}

  defp normalize_callable_response(%{content: content}) when is_binary(content),
    do: {:ok, content}

  defp normalize_callable_response(%{text: text}) when is_binary(text), do: {:ok, text}
  defp normalize_callable_response(other), do: {:ok, to_string(other)}

  @doc "Returns the default LLM provider based on application configuration."
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
