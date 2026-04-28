defmodule GEPA.Adapters.ConfidenceAdapter do
  @moduledoc "Compatibility alias for `GEPA.Adapters.Confidence`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.Confidence

  defdelegate evaluate(adapter, batch, candidate, capture_traces \\ false),
    to: GEPA.Adapters.Confidence

  defdelegate make_reflective_dataset(adapter, candidate, eval_batch, components),
    to: GEPA.Adapters.Confidence
end

defmodule GEPA.Adapters.GenericRAGAdapter do
  @moduledoc "Compatibility alias for `GEPA.Adapters.GenericRAG`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.GenericRAG

  defdelegate evaluate(adapter, batch, candidate, capture_traces \\ false),
    to: GEPA.Adapters.GenericRAG

  defdelegate make_reflective_dataset(adapter, candidate, eval_batch, components),
    to: GEPA.Adapters.GenericRAG
end

defmodule GEPA.Adapters.MCPAdapter do
  @moduledoc "Compatibility alias for `GEPA.Adapters.MCP`."
  defdelegate new(opts \\ []), to: GEPA.Adapters.MCP
  defdelegate evaluate(adapter, batch, candidate, capture_traces \\ false), to: GEPA.Adapters.MCP

  defdelegate make_reflective_dataset(adapter, candidate, eval_batch, components),
    to: GEPA.Adapters.MCP
end
