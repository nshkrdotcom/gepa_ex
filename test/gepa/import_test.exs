defmodule GEPA.ImportTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  test "package module loads" do
    assert {:module, GEPA} = Code.ensure_loaded(GEPA)
  end

  test "optimize entrypoint is exported" do
    assert function_exported?(GEPA, :optimize, 1)
  end
end
