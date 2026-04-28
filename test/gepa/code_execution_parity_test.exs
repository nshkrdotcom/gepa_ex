defmodule GEPA.CodeExecutionParityTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.CodeExecution
  alias GEPA.CodeExecution.Result

  test "execute_code/2 returns a rich result with stdout, variables, result and code hash" do
    result =
      CodeExecution.execute_code(
        """
        IO.puts("hello")
        x = 40
        x + 2
        """,
        capture_variables: [:x]
      )

    assert %Result{} = result
    assert result.success
    assert result.stdout =~ "hello"
    assert result.result == 42
    assert result.variables["x"] == 40
    assert result.variables["__return__"] == 42
    assert byte_size(result.code_hash) == 64
  end

  test "execute_code/2 can call a named entry point from final bindings" do
    result =
      CodeExecution.execute_code(
        """
        solve = fn x -> x * 2 end
        :ok
        """,
        entry_point: :solve,
        entry_point_args: [21]
      )

    assert result.success
    assert result.variables["__return__"] == 42
  end

  test "execution result converts to reflective side info" do
    result = %Result{
      success: false,
      stdout: "out",
      stderr: "err",
      error: "boom",
      traceback: "trace"
    }

    assert CodeExecution.Result.to_side_info_dict(result) == %{
             "Stdout" => "out",
             "Stderr" => "err",
             "Error" => "boom",
             "Traceback" => "trace"
           }
  end
end
