defmodule GEPA.ImportTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  test "package module loads" do
    assert {:module, GEPA} = Code.ensure_loaded(GEPA)
  end

  test "optimize entrypoint is exported" do
    Code.ensure_loaded!(GEPA)

    assert function_exported?(GEPA, :optimize, 1)
  end

  test "top-level upstream-style convenience entrypoints are exported" do
    Code.ensure_loaded!(GEPA)

    assert function_exported?(GEPA, :optimize_anything, 1)
    assert function_exported?(GEPA, :default_adapter, 1)
  end

  test "default_adapter builds the official-style default adapter" do
    adapter = GEPA.default_adapter(model: fn _messages -> "4" end)

    assert %GEPA.Adapters.Default{} = adapter
  end
end
