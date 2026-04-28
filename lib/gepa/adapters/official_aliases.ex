defmodule GEPA.Adapters.ConfidenceAdapter do
  @moduledoc "Compatibility alias for `GEPA.Adapters.Confidence`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.Confidence

  @doc false
  defdelegate evaluate(adapter, batch, candidate, capture_traces \\ false),
    to: GEPA.Adapters.Confidence

  @doc false
  defdelegate make_reflective_dataset(adapter, candidate, eval_batch, components),
    to: GEPA.Adapters.Confidence
end

defmodule GEPA.Adapters.GenericRAGAdapter do
  @moduledoc "Compatibility alias for `GEPA.Adapters.GenericRAG`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.GenericRAG

  @doc false
  defdelegate evaluate(adapter, batch, candidate, capture_traces \\ false),
    to: GEPA.Adapters.GenericRAG

  @doc false
  defdelegate make_reflective_dataset(adapter, candidate, eval_batch, components),
    to: GEPA.Adapters.GenericRAG
end

defmodule GEPA.Adapters.MCPAdapter do
  @moduledoc "Compatibility alias for `GEPA.Adapters.MCP`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.MCP

  @doc false
  defdelegate evaluate(adapter, batch, candidate, capture_traces \\ false), to: GEPA.Adapters.MCP

  @doc false
  defdelegate make_reflective_dataset(adapter, candidate, eval_batch, components),
    to: GEPA.Adapters.MCP
end
