defmodule GEPA.LLM.Client do
  @moduledoc """
  Normalized LLM client used by the GEPA LLM facade.

  This struct is intentionally small. Adapter-specific clients, sessions, and
  provider-native structs belong in `adapter_state`, not in GEPA optimizer code.
  """

  @type t :: %__MODULE__{
          adapter: module(),
          adapter_state: term(),
          provider: atom() | nil,
          model: String.t() | nil,
          defaults: keyword(),
          capabilities: MapSet.t(atom()),
          metadata: map()
        }

  defstruct [
    :adapter,
    :adapter_state,
    :provider,
    :model,
    defaults: [],
    capabilities: MapSet.new(),
    metadata: %{}
  ]
end
