defmodule GepaEx do
  @moduledoc false

  defdelegate optimize(opts), to: GEPA
  defdelegate optimize_anything(opts), to: GEPA
  defdelegate default_adapter(opts), to: GEPA
end
