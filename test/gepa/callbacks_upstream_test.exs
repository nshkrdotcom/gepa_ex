defmodule GEPA.CallbacksUpstreamTest do
  use ExUnit.Case, async: true

  defmodule Recorder do
    defstruct [:pid]

    def on_iteration_end(%__MODULE__{pid: pid}, event) do
      send(pid, {:on_iteration_end, event})
    end
  end

  test "callbacks may implement upstream-style on_* methods" do
    callback = %Recorder{pid: self()}

    assert :ok = GEPA.Callbacks.notify([callback], :iteration_end, %{iteration: 7})
    assert_receive {:on_iteration_end, %{iteration: 7}}
  end
end
