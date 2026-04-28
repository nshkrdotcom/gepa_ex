defmodule GEPA.DataLoader.List do
  @moduledoc "In-memory loader using zero-based integer IDs."

  @behaviour GEPA.DataLoader

  defstruct [:items]

  @type t :: %__MODULE__{items: [term()]}

  @spec new([term()]) :: t()
  def new(items) when is_list(items), do: %__MODULE__{items: items}

  @doc "Append items while preserving existing IDs."
  @spec add_items(t(), [term()]) :: t()
  def add_items(%__MODULE__{items: items} = loader, new_items) when is_list(new_items) do
    %{loader | items: items ++ new_items}
  end

  @impl true
  def all_ids(%__MODULE__{items: items}) do
    case length(items) do
      0 -> []
      n -> Enum.to_list(0..(n - 1))
    end
  end

  @impl true
  def fetch(%__MODULE__{items: items}, ids) when is_list(ids) do
    Enum.map(ids, &Enum.fetch!(items, &1))
  end

  @impl true
  def size(%__MODULE__{items: items}), do: length(items)
end

defmodule GEPA.DataLoader do
  @moduledoc """
  Protocol-style data access abstraction.

  The official Python implementation normalizes in-memory lists into a
  `DataLoader`. The Elixir port keeps the same seam while allowing custom
  loader structs to provide stable IDs and ordered fetches.
  """

  @type data_id :: term()
  @type data_inst :: term()
  @type t :: term()

  @callback all_ids(t()) :: [data_id()]
  @callback fetch(t(), [data_id()]) :: [data_inst()]
  @callback size(t()) :: non_neg_integer()

  @doc "Normalize raw lists into `GEPA.DataLoader.List`; pass loader structs through."
  @spec ensure([data_inst()] | t() | nil) :: t() | nil
  def ensure(nil), do: nil
  def ensure(%GEPA.DataLoader.List{} = loader), do: loader
  def ensure(items) when is_list(items), do: GEPA.DataLoader.List.new(items)

  def ensure(%module{} = loader) do
    if function_exported?(module, :all_ids, 1) and function_exported?(module, :fetch, 2) do
      loader
    else
      raise ArgumentError,
            "expected a list or DataLoader-compatible struct, got #{inspect(loader)}"
    end
  end

  def ensure(other) do
    raise ArgumentError, "expected a list or DataLoader-compatible struct, got #{inspect(other)}"
  end

  @spec all_ids(t()) :: [data_id()]
  def all_ids(items) when is_list(items), do: all_ids(GEPA.DataLoader.List.new(items))
  def all_ids(%module{} = loader), do: module.all_ids(loader)

  @spec fetch(t(), [data_id()]) :: [data_inst()]
  def fetch(items, ids) when is_list(items), do: fetch(GEPA.DataLoader.List.new(items), ids)
  def fetch(%module{} = loader, ids) when is_list(ids), do: module.fetch(loader, ids)

  @spec size(t()) :: non_neg_integer()
  def size(items) when is_list(items), do: length(items)
  def size(%module{} = loader), do: module.size(loader)
end
