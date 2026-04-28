defmodule GepaExTest do
  use GEPA.SupertesterCase, isolation: :full_isolation, async: false

  test "compatibility facade delegates public GEPA entrypoints" do
    Code.ensure_loaded!(GepaEx)

    assert function_exported?(GepaEx, :optimize, 1)
    assert function_exported?(GepaEx, :optimize_anything, 1)
    assert function_exported?(GepaEx, :default_adapter, 1)
  end
end
