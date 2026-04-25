defmodule GEPA.CodeExecution do
  @moduledoc """
  Utilities for evaluating Elixir code snippets with captured outputs.

  The upstream Python project exposes code-execution helpers for
  `optimize_anything`. This module provides the Elixir equivalent with two
  execution modes:

    * `:in_process` evaluates code in the current BEAM process with `Code.eval_string/3`.
    * `:subprocess` evaluates code in a separate `elixir` OS process.

  Both modes return a structured result map instead of raising for user-code
  failures.
  """

  @type mode :: :in_process | :subprocess

  @type result :: %{
          required(:ok) => boolean(),
          optional(:result) => term(),
          optional(:stdout) => String.t(),
          optional(:stderr) => String.t(),
          optional(:error) => term(),
          optional(:bindings) => keyword()
        }

  @doc """
  Execute Elixir code and return a structured result.

  ## Options

    * `:mode` - `:in_process` or `:subprocess` (default: `:in_process`)
    * `:timeout` - timeout in milliseconds for subprocess execution (default: `5000`)
    * `:bindings` - bindings passed to `Code.eval_string/3` in-process
    * `:return_bindings` - include final bindings in the result (default: `false`)
  """
  @spec execute(String.t(), keyword()) :: result()
  def execute(code, opts \\ []) when is_binary(code) do
    case Keyword.get(opts, :mode, :in_process) do
      :in_process -> execute_in_process(code, opts)
      :subprocess -> execute_subprocess(code, opts)
      other -> %{ok: false, error: {:unsupported_mode, other}, stdout: "", stderr: ""}
    end
  end

  @doc """
  Convert side-info values into serializable values suitable for prompts.
  """
  @spec side_info_to_data(term()) :: term()
  def side_info_to_data(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {to_string(key), side_info_to_data(val)} end)
  end

  def side_info_to_data(value) when is_list(value), do: Enum.map(value, &side_info_to_data/1)

  def side_info_to_data(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> side_info_to_data()

  def side_info_to_data(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  def side_info_to_data(nil), do: nil
  def side_info_to_data(value), do: inspect(value)

  defp execute_in_process(code, opts) do
    bindings = Keyword.get(opts, :bindings, [])

    {io_result, stdout} =
      capture_io(fn ->
        try do
          {result, final_bindings} =
            Code.eval_string(code, bindings, file: "gepa_code_execution.exs")

          {:ok, result, final_bindings}
        rescue
          exception ->
            {:error, Exception.format(:error, exception, __STACKTRACE__)}
        catch
          kind, reason ->
            {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    case io_result do
      {:ok, result, final_bindings} ->
        base = %{ok: true, result: result, stdout: stdout, stderr: ""}

        if Keyword.get(opts, :return_bindings, false) do
          Map.put(base, :bindings, final_bindings)
        else
          base
        end

      {:error, error} ->
        %{ok: false, error: error, stdout: stdout, stderr: ""}
    end
  end

  defp execute_subprocess(code, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    dir = System.tmp_dir!()
    path = Path.join(dir, "gepa_code_#{System.unique_integer([:positive])}.exs")
    File.write!(path, code)

    try do
      task = Task.async(fn -> System.cmd("elixir", [path], stderr_to_stdout: true) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        nil ->
          %{ok: false, error: :timeout, stdout: "", stderr: ""}

        {:ok, {output, 0}} ->
          %{ok: true, result: nil, stdout: output, stderr: ""}

        {:ok, {output, status}} ->
          %{ok: false, error: {:exit_status, status}, stdout: output, stderr: ""}
      end
    catch
      :exit, reason ->
        %{ok: false, error: reason, stdout: "", stderr: ""}
    after
      File.rm(path)
    end
  end

  defp capture_io(fun) do
    {:ok, io} = StringIO.open("")
    previous = Process.group_leader()
    Process.group_leader(self(), io)

    try do
      result = fun.()
      {_input, output} = StringIO.contents(io)
      {result, output}
    after
      Process.group_leader(self(), previous)
    end
  end
end
