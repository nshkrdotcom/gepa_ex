defmodule GEPA.DataLoader do
  @moduledoc """
  Protocol for data access with flexible ID types.

  DataLoader provides an abstraction over data storage, allowing GEPA
  to work with in-memory lists, databases, lazy streams, etc.

  ## Required Callbacks

  - `all_ids/1`: Return all available data IDs
  - `fetch/2`: Fetch data instances by ID
  - `size/1`: Return total count of data instances

  ## Example Implementation

      defmodule MyDatabaseLoader do
        @behaviour GEPA.DataLoader

        defstruct [:db_conn]

        @impl true
        def all_ids(%__MODULE__{db_conn: conn}) do
          DB.query!(conn, "SELECT id FROM examples")
        end

        @impl true
        def fetch(%__MODULE__{db_conn: conn}, ids) do
          DB.query!(conn, "SELECT * FROM examples WHERE id IN (?)", [ids])
        end

        @impl true
        def size(%__MODULE__{db_conn: conn}) do
          DB.query_one!(conn, "SELECT COUNT(*) FROM examples")
        end
      end
  """

  @type data_id :: term()
  @type data_inst :: term()
  @type t :: term()

  @doc """
  Return ordered list of all available data IDs.

  The order should be stable across calls.
  """
  @callback all_ids(t()) :: [data_id()]

  @doc """
  Fetch data instances for given IDs.

  Must preserve order: `fetch(loader, [id1, id2])` returns data in same order.

  ## Contract

  - `length(fetch(loader, ids)) == length(ids)`
  - Order must match input IDs
  - Missing IDs may raise or return nil - behavior is implementation-defined
  """
  @callback fetch(t(), [data_id()]) :: [data_inst()]

  @doc """
  Return total number of data instances.
  """
  @callback size(t()) :: non_neg_integer()

  @doc """
  Delegates to the implementation's all_ids/1.
  """
  @spec all_ids(t()) :: [data_id()]
  def all_ids(%module{} = loader) do
    module.all_ids(loader)
  end

  @doc """
  Delegates to the implementation's fetch/2.
  """
  @spec fetch(t(), [data_id()]) :: [data_inst()]
  def fetch(%module{} = loader, ids) do
    module.fetch(loader, ids)
  end

  @doc """
  Delegates to the implementation's size/1.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%module{} = loader) do
    module.size(loader)
  end
end

defmodule GEPA.DataLoader.List do
  @moduledoc """
  Simple in-memory list-based data loader.

  Uses integer indices as data IDs.

  ## Example

      loader = GEPA.DataLoader.List.new([
        %{input: "Q1", answer: "A1"},
        %{input: "Q2", answer: "A2"}
      ])

      GEPA.DataLoader.all_ids(loader)  # => [0, 1]
      GEPA.DataLoader.fetch(loader, [1, 0])  # => [%{input: "Q2", ...}, %{input: "Q1", ...}]
  """

  @behaviour GEPA.DataLoader

  defstruct [:items]

  @type t :: %__MODULE__{items: [term()]}

  @doc """
  Create a list-based data loader.
  """
  @spec new([term()]) :: t()
  def new(items) when is_list(items) do
    %__MODULE__{items: items}
  end

  @impl true
  def all_ids(%__MODULE__{items: items}) do
    Enum.to_list(0..(length(items) - 1))
  end

  @impl true
  def fetch(%__MODULE__{items: items}, ids) do
    Enum.map(ids, &Enum.at(items, &1))
  end

  @impl true
  def size(%__MODULE__{items: items}) do
    length(items)
  end
end
