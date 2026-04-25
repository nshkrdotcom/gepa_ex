defmodule GEPA.LLM.Response do
  @moduledoc """
  Normalized LLM adapter response.
  """

  @type t :: %__MODULE__{
          text: String.t() | nil,
          object: map() | nil,
          messages: [term()] | nil,
          tool_calls: [term()],
          tool_results: [term()],
          usage: map() | nil,
          cost: map() | number() | nil,
          stop_reason: atom() | String.t() | nil,
          adapter: module() | nil,
          provider: atom() | nil,
          model: String.t() | nil,
          session_ref: term(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :text,
    :object,
    :messages,
    :usage,
    :cost,
    :stop_reason,
    :adapter,
    :provider,
    :model,
    :session_ref,
    :raw,
    tool_calls: [],
    tool_results: [],
    metadata: %{}
  ]

  @spec text(t()) :: String.t()
  def text(%__MODULE__{text: text}) when is_binary(text), do: text

  def text(%__MODULE__{object: %{"instruction" => instruction}}) when is_binary(instruction),
    do: instruction

  def text(%__MODULE__{object: %{instruction: instruction}}) when is_binary(instruction),
    do: instruction

  def text(%__MODULE__{}), do: ""
end
