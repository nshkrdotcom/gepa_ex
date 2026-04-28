defmodule GEPA.CodeExecution.Result do
  @moduledoc "Structured result returned by `GEPA.CodeExecution.execute_code/2`."

  @type t :: %__MODULE__{
          success: boolean(),
          stdout: String.t(),
          stderr: String.t(),
          result: term(),
          error: String.t(),
          traceback: String.t(),
          variables: map(),
          execution_time: float(),
          code_hash: String.t()
        }

  defstruct success: false,
            stdout: "",
            stderr: "",
            result: nil,
            error: "",
            traceback: "",
            variables: %{},
            execution_time: 0.0,
            code_hash: ""

  @doc "Convert execution details into evaluator side-info."
  @spec to_side_info_dict(t()) :: map()
  def to_side_info_dict(%__MODULE__{} = result) do
    %{
      "Stdout" => result.stdout,
      "Stderr" => result.stderr
    }
    |> maybe_put("Error", result.error)
    |> maybe_put("Traceback", result.traceback)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule GEPA.CodeExecution do
  @moduledoc """
  Utilities for evaluating Elixir code snippets with captured outputs.

  The module keeps the original `execute/2` map-returning API while adding the
  upstream-style `execute_code/2` API with timeout support, captured stdout and
  stderr, code hashes, variable capture, and optional entry-point invocation.
  """

  alias GEPA.CodeExecution.Result

  @type mode :: :in_process | :subprocess

  @type result :: %{
          required(:ok) => boolean(),
          optional(:result) => term(),
          optional(:stdout) => String.t(),
          optional(:stderr) => String.t(),
          optional(:error) => term(),
          optional(:bindings) => keyword()
        }

  @doc "Execute Elixir code and return the legacy map result."
  @spec execute(String.t(), keyword()) :: result()
  def execute(code, opts \\ []) when is_binary(code) do
    result = execute_code(code, opts)

    if result.success do
      base = %{
        ok: true,
        result: Map.get(result.variables, "__return__"),
        stdout: result.stdout,
        stderr: result.stderr
      }

      if Keyword.get(opts, :return_bindings, false) do
        Map.put(base, :bindings, result.variables)
      else
        base
      end
    else
      %{
        ok: false,
        error: if(result.error != "", do: result.error, else: result.traceback),
        stdout: result.stdout,
        stderr: result.stderr
      }
    end
  end

  @doc "Execute Elixir code and return a rich structured result."
  @spec execute_code(String.t(), keyword()) :: Result.t()
  def execute_code(code, opts \\ []) when is_binary(code) do
    case Keyword.get(opts, :mode, :in_process) do
      :in_process -> execute_in_process_struct(code, opts)
      :subprocess -> execute_subprocess_struct(code, opts)
      other -> failure_result(code, {:unsupported_mode, other}, "")
    end
  end

  @doc "Return a deterministic hash for normalized source code."
  @spec get_code_hash(String.t(), pos_integer()) :: String.t()
  def get_code_hash(code, length \\ 8) when is_binary(code) do
    code
    |> normalized_code_hash()
    |> binary_part(0, min(length, 64))
  end

  @doc "Convert side-info values into serializable values suitable for prompts."
  @spec side_info_to_data(term()) :: term()
  def side_info_to_data(%GEPA.Image{} = image), do: image

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

  defp execute_in_process_struct(code, opts) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, 5_000))
    started = System.monotonic_time(:microsecond)

    task =
      Task.async(fn ->
        do_execute_in_process(code, opts, started)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, %Result{} = result} ->
        result

      {:exit, reason} ->
        failure_result(code, {:exit, reason}, elapsed_seconds(started))

      nil ->
        failure_result(code, "Timeout: execution exceeded #{timeout}ms", elapsed_seconds(started))
    end
  end

  defp do_execute_in_process(code, opts, started) do
    hash = normalized_code_hash(code)
    bindings = bindings_from_opts(opts)
    seed_random(Keyword.get(opts, :seed))

    {payload, stdout} =
      capture_io(fn ->
        try do
          {value, final_bindings} =
            Code.eval_string(code, bindings, file: "gepa_code_execution.exs")

          {value, final_bindings} = maybe_call_entry_point(value, final_bindings, opts)
          {:ok, value, final_bindings}
        rescue
          exception ->
            {:error, Exception.message(exception),
             Exception.format(:error, exception, __STACKTRACE__)}
        catch
          kind, reason ->
            {:error, inspect(reason), Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    case payload do
      {:ok, value, final_bindings} ->
        %Result{
          success: true,
          stdout: stdout,
          stderr: "",
          result: value,
          variables: capture_variables(final_bindings, value, opts),
          execution_time: elapsed_seconds(started),
          code_hash: hash
        }

      {:error, error, traceback} ->
        %Result{
          success: false,
          stdout: stdout,
          stderr: "",
          error: error,
          traceback: traceback,
          execution_time: elapsed_seconds(started),
          code_hash: hash
        }
    end
  end

  defp execute_subprocess_struct(code, opts) do
    timeout = normalize_timeout(Keyword.get(opts, :timeout, 5_000))
    started = System.monotonic_time(:microsecond)
    hash = normalized_code_hash(code)
    path = Path.join(System.tmp_dir!(), "gepa_code_#{System.unique_integer([:positive])}.exs")
    File.write!(path, code)

    try do
      task = Task.async(fn -> System.cmd("elixir", [path], stderr_to_stdout: true) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        nil ->
          %Result{
            success: false,
            error: "Timeout: execution exceeded #{timeout}ms",
            execution_time: elapsed_seconds(started),
            code_hash: hash
          }

        {:exit, reason} ->
          %Result{
            success: false,
            error: inspect(reason),
            execution_time: elapsed_seconds(started),
            code_hash: hash
          }

        {:ok, {output, 0}} ->
          %Result{
            success: true,
            stdout: output,
            result: output,
            execution_time: elapsed_seconds(started),
            code_hash: hash
          }

        {:ok, {output, status}} ->
          %Result{
            success: false,
            stdout: output,
            error: "Exit status #{status}",
            execution_time: elapsed_seconds(started),
            code_hash: hash
          }
      end
    catch
      :exit, reason ->
        %Result{
          success: false,
          error: inspect(reason),
          execution_time: elapsed_seconds(started),
          code_hash: hash
        }
    after
      File.rm(path)
    end
  end

  defp maybe_call_entry_point(value, bindings, opts) do
    case Keyword.get(opts, :entry_point) do
      nil ->
        {value, bindings}

      {module, function} when is_atom(module) and is_atom(function) ->
        result = apply(module, function, Keyword.get(opts, :entry_point_args, []))
        {result, Keyword.put(bindings, :__return__, result)}

      name when is_atom(name) or is_binary(name) ->
        atom_name = if is_atom(name), do: name, else: String.to_atom(name)

        case Keyword.get(bindings, atom_name) do
          fun when is_function(fun) ->
            result = apply(fun, Keyword.get(opts, :entry_point_args, []))
            {result, Keyword.put(bindings, :__return__, result)}

          _ ->
            {value, bindings}
        end
    end
  end

  defp capture_variables(bindings, value, opts) do
    variables =
      case Keyword.get(opts, :capture_variables) do
        nil -> Map.new(bindings, fn {key, val} -> {to_string(key), safe_term(val)} end)
        names -> Map.new(names, &capture_one_variable(bindings, &1))
      end

    Map.put_new(variables, "__return__", safe_term(Keyword.get(bindings, :__return__, value)))
  end

  defp capture_one_variable(bindings, name) do
    key = if is_atom(name), do: name, else: String.to_atom(to_string(name))
    {to_string(name), safe_term(Keyword.get(bindings, key))}
  end

  defp bindings_from_opts(opts) do
    bindings = Keyword.get(opts, :bindings, [])
    globals = Keyword.get(opts, :global_vars, %{})

    globals
    |> Enum.reduce(bindings, fn {key, value}, acc ->
      Keyword.put(acc, normalize_binding_key(key), value)
    end)
  end

  defp normalize_binding_key(key) when is_atom(key), do: key
  defp normalize_binding_key(key), do: String.to_atom(to_string(key))

  defp safe_term(term), do: term

  defp seed_random(nil), do: :ok

  defp seed_random(seed) when is_integer(seed) do
    :rand.seed(:exsss, {seed + 1, seed * 2 + 3, seed * 3 + 5})
    :ok
  end

  defp normalized_code_hash(code) do
    code
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_timeout(timeout) when is_integer(timeout), do: timeout
  defp normalize_timeout(timeout) when is_float(timeout), do: round(timeout * 1000)
  defp normalize_timeout(_timeout), do: 5_000

  defp elapsed_seconds(started_us) when is_integer(started_us) do
    (System.monotonic_time(:microsecond) - started_us) / 1_000_000
  end

  defp failure_result(code, reason, elapsed) do
    %Result{
      success: false,
      error: inspect(reason),
      stdout: "",
      stderr: "",
      execution_time: elapsed_time(elapsed),
      code_hash: normalized_code_hash(code)
    }
  end

  defp elapsed_time(value) when is_number(value), do: value * 1.0
  defp elapsed_time(_value), do: 0.0

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
