defmodule GEPA.LLM.Tool do
  @moduledoc """
  GEPA-facing portable tool specification.

  The first shipping slice uses this for ReqLLM conversion only. ASM tool-loop
  support remains capability-gated until the shared CLI tool surface exists.
  """

  @type callback :: (map(), map() -> {:ok, term()} | {:error, term()})

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map() | keyword(),
          run: callback() | nil,
          metadata: map()
        }

  defstruct [
    :name,
    :description,
    :input_schema,
    :run,
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      description: Keyword.fetch!(opts, :description),
      input_schema: Keyword.get(opts, :input_schema, %{}),
      run: Keyword.get(opts, :run),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
