defmodule GEPA.LLM.Request do
  @moduledoc """
  Normalized request passed from GEPA to LLM adapters.
  """

  @type prompt :: String.t() | [map()]

  @type t :: %__MODULE__{
          input: prompt() | nil,
          messages: [map()] | nil,
          system: String.t() | nil,
          schema: keyword() | map() | nil,
          tools: [term()],
          tool_choice: :auto | :none | :required | {:tool, String.t()} | nil,
          stream?: boolean(),
          temperature: float() | nil,
          model: String.t() | nil,
          max_tokens: pos_integer() | nil,
          top_p: float() | nil,
          timeout: pos_integer() | nil,
          session: term(),
          provider_opts: keyword(),
          metadata: map()
        }

  defstruct [
    :input,
    :messages,
    :system,
    :schema,
    :tool_choice,
    :temperature,
    :model,
    :max_tokens,
    :top_p,
    :timeout,
    :session,
    tools: [],
    stream?: false,
    provider_opts: [],
    metadata: %{}
  ]

  @spec from_prompt(prompt(), keyword()) :: t()
  def from_prompt(prompt, opts \\ []) when is_binary(prompt) or is_list(prompt) do
    %__MODULE__{
      input: prompt,
      messages: Keyword.get(opts, :messages) || if(is_list(prompt), do: prompt),
      system: Keyword.get(opts, :system),
      schema: Keyword.get(opts, :schema),
      tools: Keyword.get(opts, :tools, []),
      tool_choice: Keyword.get(opts, :tool_choice),
      stream?: Keyword.get(opts, :stream?, false),
      temperature: Keyword.get(opts, :temperature),
      model: Keyword.get(opts, :model),
      max_tokens: Keyword.get(opts, :max_tokens),
      top_p: Keyword.get(opts, :top_p),
      timeout: Keyword.get(opts, :timeout),
      session: Keyword.get(opts, :session),
      provider_opts: Keyword.get(opts, :provider_opts, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec structured(prompt(), keyword()) :: t()
  def structured(prompt, opts \\ []) when is_binary(prompt) or is_list(prompt) do
    prompt
    |> from_prompt(opts)
    |> Map.put(:schema, Keyword.get(opts, :schema))
  end

  @spec prompt(t()) :: prompt() | nil
  def prompt(%__MODULE__{messages: messages}) when is_list(messages), do: messages
  def prompt(%__MODULE__{input: input}), do: input

  @doc "Render prompt messages to plain text for adapters that only support text."
  @spec to_text(prompt() | nil) :: String.t() | nil
  def to_text(nil), do: nil
  def to_text(prompt) when is_binary(prompt), do: prompt

  def to_text(messages) when is_list(messages) do
    Enum.map_join(messages, "\n\n", fn
      %{role: role, content: content} -> "#{role}: #{content_to_text(content)}"
      %{"role" => role, "content" => content} -> "#{role}: #{content_to_text(content)}"
      other -> content_to_text(other)
    end)
  end

  defp content_to_text(content) when is_binary(content), do: content

  defp content_to_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{type: "text", text: text} -> text
      %{"type" => "text", "text" => text} -> text
      %{type: "image_url"} -> "[image]"
      %{"type" => "image_url"} -> "[image]"
      other -> inspect(other)
    end)
  end

  defp content_to_text(content), do: inspect(content)
end
