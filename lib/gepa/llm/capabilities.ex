defmodule GEPA.LLM.Capabilities do
  @moduledoc """
  Capability helpers for GEPA LLM adapters.
  """

  alias GEPA.LLM.Client

  @type capability :: atom()

  @spec has?(Client.t() | MapSet.t(atom()) | [atom()], capability()) :: boolean()
  def has?(%Client{capabilities: capabilities}, capability), do: has?(capabilities, capability)
  def has?(%MapSet{} = capabilities, capability), do: MapSet.member?(capabilities, capability)
  def has?(capabilities, capability) when is_list(capabilities), do: capability in capabilities
  def has?(_, _), do: false

  @spec ensure(Client.t(), capability(), term()) ::
          :ok | {:error, {:unsupported_capability, atom(), term()}}
  def ensure(%Client{} = client, capability, context \\ %{}) do
    if has?(client, capability) do
      :ok
    else
      {:error, {:unsupported_capability, capability, context}}
    end
  end
end
