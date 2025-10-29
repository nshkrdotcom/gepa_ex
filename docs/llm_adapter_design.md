# LLM Adapter Design

## Python GEPA Approach

### Overview

The Python GEPA library uses a flexible, duck-typed approach for LLM integration:

```python
# From generic_rag_adapter.py
def __init__(
    self,
    llm_model,  # Can be string, callable, or object
    ...
):
    self.llm_client = llm_model
```

### Flexibility Pattern

The Python implementation handles three types of LLM clients:

1. **Callable Function**:
   ```python
   if callable(self.llm_client):
       response = self.llm_client(messages)
   ```

2. **LiteLLM-style Object**:
   ```python
   else:
       response = self.llm_client.completion(messages=messages).choices[0].message.content
   ```

3. **String Model Name**: Used with `litellm` library directly

### Message Format

Standard OpenAI-style messages:
```python
messages = [
    {"role": "system", "content": "instruction"},
    {"role": "user", "content": "query"}
]
```

### Error Handling

- Individual LLM call failures are caught and return fallback values
- Systemic failures bubble up as exceptions

---

## Proposed Elixir Design

### Core Principle: Behavior-Based Abstraction

Use Elixir behaviors for clean, type-safe LLM integration.

### Architecture

```
GEPA.LLM.Behavior (behavior)
├── GEPA.LLM.Mock (test implementation)
├── GEPA.LLM.OpenAI (OpenAI/compatible APIs)
├── GEPA.LLM.Anthropic (Claude API)
├── GEPA.LLM.Custom (user-defined wrapper)
└── User implementations...
```

### 1. Behavior Definition

```elixir
defmodule GEPA.LLM.Behavior do
  @moduledoc """
  Behavior for LLM client implementations.

  Provides a standardized interface for different LLM providers,
  allowing GEPA to work with any LLM backend.
  """

  @type message :: %{
    role: :system | :user | :assistant,
    content: String.t()
  }

  @type completion_result ::
    {:ok, %{content: String.t(), usage: map() | nil}}
    | {:error, term()}

  @type config :: keyword()

  @doc """
  Complete a conversation with the LLM.

  ## Parameters

  - `messages`: List of conversation messages
  - `config`: Optional configuration (model, temperature, etc.)

  ## Returns

  - `{:ok, %{content: ..., usage: ...}}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> messages = [
      ...>   %{role: :system, content: "You are a helpful assistant."},
      ...>   %{role: :user, content: "What is 2+2?"}
      ...> ]
      iex> GEPA.LLM.OpenAI.complete(messages, model: "gpt-4")
      {:ok, %{content: "2+2 equals 4.", usage: %{...}}}
  """
  @callback complete(messages :: [message()], config :: config()) :: completion_result()

  @doc """
  Validate client configuration.

  Called during initialization to ensure the client is properly configured.
  Should return :ok or {:error, reason}.
  """
  @callback validate_config(config :: config()) :: :ok | {:error, String.t()}

  @doc """
  Get the model identifier.

  Returns the model name/identifier for logging and debugging.
  """
  @callback model_name(config :: config()) :: String.t()

  @optional_callbacks [validate_config: 1, model_name: 1]
end
```

### 2. Configuration System

```elixir
# In application config or runtime
config :gepa_ex, :llm,
  adapter: GEPA.LLM.OpenAI,
  model: "gpt-4-turbo",
  api_key: {:system, "OPENAI_API_KEY"},
  temperature: 0.7,
  max_tokens: 2000,
  timeout: 30_000

# Or per-adapter configuration
config :gepa_ex, GEPA.LLM.OpenAI,
  base_url: "https://api.openai.com/v1",
  default_model: "gpt-4-turbo",
  retry_attempts: 3
```

### 3. Implementation Examples

#### Mock (for testing)

```elixir
defmodule GEPA.LLM.Mock do
  @behaviour GEPA.LLM.Behavior

  @impl true
  def complete(messages, _config \\ []) do
    # Simple echo-based mock
    last_user_msg =
      messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :user))

    {:ok, %{
      content: "Mock response to: #{last_user_msg.content}",
      usage: %{prompt_tokens: 10, completion_tokens: 5}
    }}
  end

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def model_name(_config), do: "mock-model"
end
```

#### OpenAI / Compatible APIs

```elixir
defmodule GEPA.LLM.OpenAI do
  @behaviour GEPA.LLM.Behavior

  @moduledoc """
  OpenAI-compatible LLM client.

  Works with OpenAI, Azure OpenAI, and compatible APIs (Groq, Together, etc.)

  ## Configuration

      config :gepa_ex, GEPA.LLM.OpenAI,
        api_key: {:system, "OPENAI_API_KEY"},
        base_url: "https://api.openai.com/v1",
        organization: nil
  """

  @impl true
  def complete(messages, config \\ []) do
    model = config[:model] || get_default_model()

    request_body = %{
      model: model,
      messages: format_messages(messages),
      temperature: config[:temperature] || 0.7,
      max_tokens: config[:max_tokens]
    }

    case make_request("/chat/completions", request_body, config) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]} = response} ->
        {:ok, %{
          content: content,
          usage: Map.get(response, "usage")
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def validate_config(config) do
    api_key = resolve_config(config, :api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, "OpenAI API key not configured"}
    else
      :ok
    end
  end

  @impl true
  def model_name(config) do
    config[:model] || get_default_model()
  end

  # Private helpers

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg.role),
        "content" => msg.content
      }
    end)
  end

  defp make_request(path, body, config) do
    base_url = config[:base_url] || Application.get_env(:gepa_ex, __MODULE__)[:base_url] || "https://api.openai.com/v1"
    api_key = resolve_config(config, :api_key)

    url = base_url <> path
    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.post(url, Jason.encode!(body), headers) do
      {:ok, %{status_code: 200, body: response_body}} ->
        {:ok, Jason.decode!(response_body)}

      {:ok, %{status_code: status, body: error_body}} ->
        {:error, "HTTP #{status}: #{error_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp resolve_config(config, key) do
    case config[key] || Application.get_env(:gepa_ex, __MODULE__)[key] do
      {:system, env_var} -> System.get_env(env_var)
      value -> value
    end
  end

  defp get_default_model do
    Application.get_env(:gepa_ex, __MODULE__)[:default_model] || "gpt-4-turbo"
  end
end
```

#### Anthropic Claude

```elixir
defmodule GEPA.LLM.Anthropic do
  @behaviour GEPA.LLM.Behavior

  @moduledoc """
  Anthropic Claude LLM client.

  ## Configuration

      config :gepa_ex, GEPA.LLM.Anthropic,
        api_key: {:system, "ANTHROPIC_API_KEY"},
        base_url: "https://api.anthropic.com"
  """

  @impl true
  def complete(messages, config \\ []) do
    model = config[:model] || "claude-3-5-sonnet-20241022"

    # Anthropic requires system message separate
    {system_msg, conversation} = extract_system_message(messages)

    request_body = %{
      model: model,
      system: system_msg,
      messages: format_messages(conversation),
      max_tokens: config[:max_tokens] || 2000,
      temperature: config[:temperature] || 0.7
    }

    case make_request("/v1/messages", request_body, config) do
      {:ok, %{"content" => [%{"text" => text} | _]} = response} ->
        {:ok, %{
          content: text,
          usage: Map.get(response, "usage")
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def validate_config(config) do
    api_key = resolve_config(config, :api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, "Anthropic API key not configured"}
    else
      :ok
    end
  end

  @impl true
  def model_name(config) do
    config[:model] || "claude-3-5-sonnet-20241022"
  end

  # Private helpers

  defp extract_system_message(messages) do
    case Enum.find(messages, &(&1.role == :system)) do
      %{content: system_content} ->
        conversation = Enum.reject(messages, &(&1.role == :system))
        {system_content, conversation}

      nil ->
        {"", messages}
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg.role),
        "content" => msg.content
      }
    end)
  end

  defp make_request(path, body, config) do
    base_url = config[:base_url] || Application.get_env(:gepa_ex, __MODULE__)[:base_url] || "https://api.anthropic.com"
    api_key = resolve_config(config, :api_key)

    url = base_url <> path
    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.post(url, Jason.encode!(body), headers) do
      {:ok, %{status_code: 200, body: response_body}} ->
        {:ok, Jason.decode!(response_body)}

      {:ok, %{status_code: status, body: error_body}} ->
        {:error, "HTTP #{status}: #{error_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp resolve_config(config, key) do
    case config[key] || Application.get_env(:gepa_ex, __MODULE__)[key] do
      {:system, env_var} -> System.get_env(env_var)
      value -> value
    end
  end
end
```

#### Custom Wrapper

```elixir
defmodule GEPA.LLM.Custom do
  @behaviour GEPA.LLM.Behavior

  @moduledoc """
  Custom LLM client wrapper for user-defined implementations.

  Allows users to wrap any function or module as an LLM client.

  ## Examples

      # Function-based
      my_llm_fn = fn messages, _config ->
        # Your custom logic
        {:ok, %{content: "response"}}
      end

      config = [
        adapter: GEPA.LLM.Custom,
        function: my_llm_fn
      ]

      # Module-based
      config = [
        adapter: GEPA.LLM.Custom,
        module: MyApp.CustomLLM,
        function: :complete
      ]
  """

  @impl true
  def complete(messages, config \\ []) do
    case config[:function] do
      fun when is_function(fun, 2) ->
        fun.(messages, config)

      fun when is_function(fun, 1) ->
        fun.(messages)

      nil ->
        case {config[:module], config[:function]} do
          {mod, fun} when is_atom(mod) and is_atom(fun) ->
            apply(mod, fun, [messages, config])

          _ ->
            {:error, "No function or module configured for Custom adapter"}
        end
    end
  end

  @impl true
  def validate_config(config) do
    cond do
      is_function(config[:function]) -> :ok
      is_atom(config[:module]) and is_atom(config[:function]) -> :ok
      true -> {:error, "Custom adapter requires :function or {:module, :function}"}
    end
  end

  @impl true
  def model_name(config) do
    config[:model] || "custom-model"
  end
end
```

### 4. Usage in Adapters

```elixir
defmodule GEPA.Adapters.Basic do
  @moduledoc """
  Basic adapter with configurable LLM client.
  """

  defstruct [:llm_config, :failure_score]

  def new(opts \\ []) do
    %__MODULE__{
      llm_config: opts[:llm_config] || default_llm_config(),
      failure_score: opts[:failure_score] || 0.0
    }
  end

  defp evaluate_single(adapter, example, instruction, capture_traces) do
    messages = [
      %{role: :system, content: instruction},
      %{role: :user, content: example.input}
    ]

    # Get LLM adapter module
    llm_adapter = adapter.llm_config[:adapter] || GEPA.LLM.Mock

    # Call LLM
    case llm_adapter.complete(messages, adapter.llm_config) do
      {:ok, %{content: response}} ->
        score = calculate_score(response, example)
        trajectory = build_trajectory(capture_traces, example, response, score)
        {:ok, response, score, trajectory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_llm_config do
    Application.get_env(:gepa_ex, :llm, [adapter: GEPA.LLM.Mock])
  end
end
```

### 5. Configuration Examples

#### Development (Mock)

```elixir
# config/dev.exs
config :gepa_ex, :llm,
  adapter: GEPA.LLM.Mock
```

#### Production (OpenAI)

```elixir
# config/prod.exs
config :gepa_ex, :llm,
  adapter: GEPA.LLM.OpenAI,
  model: "gpt-4-turbo",
  api_key: {:system, "OPENAI_API_KEY"},
  temperature: 0.7

config :gepa_ex, GEPA.LLM.OpenAI,
  base_url: "https://api.openai.com/v1",
  retry_attempts: 3
```

#### Production (Claude)

```elixir
# config/prod.exs
config :gepa_ex, :llm,
  adapter: GEPA.LLM.Anthropic,
  model: "claude-3-5-sonnet-20241022",
  api_key: {:system, "ANTHROPIC_API_KEY"}
```

#### Custom Implementation

```elixir
# config/runtime.exs
config :gepa_ex, :llm,
  adapter: GEPA.LLM.Custom,
  function: &MyApp.LLM.complete/2,
  model: "my-custom-model"
```

## Benefits of This Approach

1. **Type Safety**: Behaviors enforce contract at compile time
2. **Testability**: Easy to swap Mock in tests
3. **Extensibility**: Users can implement their own adapters
4. **Configuration**: Flexible runtime and compile-time config
5. **Error Handling**: Explicit {:ok, _} | {:error, _} returns
6. **Observability**: Easy to add telemetry/logging at adapter level

## Migration Path

1. ✅ Keep existing GEPA.LLM.Mock for backward compatibility
2. Implement GEPA.LLM.Behavior
3. Implement GEPA.LLM.OpenAI
4. Implement GEPA.LLM.Anthropic
5. Update adapters to use configurable LLM clients
6. Add telemetry events
7. Create user documentation with examples

## Dependencies

Add to mix.exs:

```elixir
defp deps do
  [
    {:httpoison, "~> 2.2"},  # For HTTP requests
    {:jason, "~> 1.4"},       # Already included
    {:telemetry, "~> 1.2"},   # Already included
    # Optional: for more robust HTTP client
    {:req, "~> 0.4", optional: true}
  ]
end
```

## Testing Strategy

```elixir
# Test with mock
test "adapter works with mock LLM" do
  config = [adapter: GEPA.LLM.Mock]
  adapter = GEPA.Adapters.Basic.new(llm_config: config)
  # assertions...
end

# Test with custom function
test "adapter works with custom function" do
  custom_fn = fn _messages, _config ->
    {:ok, %{content: "custom response"}}
  end

  config = [adapter: GEPA.LLM.Custom, function: custom_fn]
  adapter = GEPA.Adapters.Basic.new(llm_config: config)
  # assertions...
end
```
