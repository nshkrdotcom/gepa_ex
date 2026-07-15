defmodule GEPA.Adapters.MCP.DataInst do
  @moduledoc "Task instance for `GEPA.Adapters.MCP`."
  defstruct user_query: nil,
            tool_arguments: %{},
            reference_answer: nil,
            expected_tool: nil,
            metadata: %{}

  @type t :: %__MODULE__{}
end

defmodule GEPA.Adapters.MCP.Output do
  @moduledoc "Output emitted by `GEPA.Adapters.MCP`."
  defstruct [:selected_tool, :tool_arguments, :tool_result, :answer]

  @type t :: %__MODULE__{}
end

defmodule GEPA.Adapters.MCP.Trajectory do
  @moduledoc "Trace emitted by `GEPA.Adapters.MCP` when `capture_traces` is true."
  defstruct [
    :user_query,
    :available_tools,
    :selected_tool,
    :tool_arguments,
    :tool_result,
    :answer,
    :reference_answer,
    :score,
    :feedback
  ]

  @type t :: %__MODULE__{}
end

defmodule GEPA.Adapters.MCP do
  @moduledoc """
  MCP tool-use adapter.

  The adapter optimizes tool descriptions/system prompts for tasks that require
  a model to choose and call MCP tools.  It supports dependency-free testing via
  `GEPA.Adapters.MCP.Client.Static`, while the transport boundary is represented
  by `GEPA.Adapters.MCP.Client`.
  """

  @behaviour GEPA.Adapter

  alias GEPA.Adapters.MCP.{Client, DataInst, Output, Trajectory}

  defstruct [
    :client,
    :model,
    :task_model,
    :tool_names,
    :tool_selector,
    :answer_generator,
    :scoring_fn,
    :metric_fn,
    :server_params,
    :remote_url,
    :remote_transport,
    :remote_headers,
    :base_system_prompt,
    :enable_two_pass,
    failure_score: 0.0,
    two_pass?: true
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = Map.new(opts)
    client = Map.get(opts, :client) || Client.create(opts)
    model = Map.get(opts, :model, Map.get(opts, :task_model))
    scoring_fn = Map.get(opts, :scoring_fn, Map.get(opts, :metric_fn))
    two_pass? = Map.get(opts, :two_pass?, Map.get(opts, :enable_two_pass, true))

    %__MODULE__{
      client: client,
      model: model,
      task_model: model,
      tool_names: normalize_tool_names(Map.get(opts, :tool_names, [])),
      tool_selector: Map.get(opts, :tool_selector),
      answer_generator: Map.get(opts, :answer_generator),
      scoring_fn: scoring_fn,
      metric_fn: scoring_fn,
      server_params: Map.get(opts, :server_params),
      remote_url: Map.get(opts, :remote_url),
      remote_transport: Map.get(opts, :remote_transport),
      remote_headers: Map.get(opts, :remote_headers, %{}),
      base_system_prompt:
        Map.get(opts, :base_system_prompt, "You are an MCP tool-use assistant."),
      enable_two_pass: two_pass?,
      failure_score: Map.get(opts, :failure_score, 0.0) * 1.0,
      two_pass?: two_pass?
    }
  end

  @doc "Build the tool-use system prompt for a candidate and available tool schemas."
  @spec build_system_prompt(t(), map(), [map()]) :: String.t()
  def build_system_prompt(%__MODULE__{} = adapter, candidate, tools) do
    tool_blocks =
      Enum.map_join(tools, "\n", fn tool ->
        name = tool_name(tool)
        description = candidate_tool_description(candidate, name, tool)

        schema =
          Map.get(tool, "inputSchema") || Map.get(tool, "input_schema") ||
            Map.get(tool, :inputSchema) || Map.get(tool, :input_schema) || %{}

        """
        Tool: #{name}
        Description: #{description}
        Input schema: #{inspect(schema, pretty: true)}
        """
      end)

    """
    #{adapter.base_system_prompt}

    Available tools:
    #{tool_blocks}

    Select an appropriate tool and respond with JSON using the action "call_tool".
    """
  end

  @doc "Extract a plain-text result from common MCP tool response shapes."
  @spec extract_tool_response(term()) :: String.t()
  def extract_tool_response(%{isError: true} = result) do
    "ERROR: " <> extract_content_text(Map.get(result, :content, []))
  end

  def extract_tool_response(%{"isError" => true} = result) do
    "ERROR: " <> extract_content_text(Map.get(result, "content", []))
  end

  def extract_tool_response(%{structuredContent: structured}) when not is_nil(structured) do
    inspect(structured, pretty: true)
  end

  def extract_tool_response(%{"structuredContent" => structured}) when not is_nil(structured) do
    inspect(structured, pretty: true)
  end

  def extract_tool_response(%{content: content}), do: extract_content_text(content)
  def extract_tool_response(%{"content" => content}), do: extract_content_text(content)
  def extract_tool_response(result) when is_binary(result), do: result
  def extract_tool_response(result), do: inspect(result, pretty: true)

  @doc "Generate reflective feedback for an MCP tool-use trajectory."
  @spec generate_tool_feedback(map() | Trajectory.t(), number()) :: String.t()
  def generate_tool_feedback(trajectory, score) do
    tool_called =
      trajectory_value(trajectory, :tool_called) ||
        not is_nil(trajectory_value(trajectory, :selected_tool))

    cond do
      score >= 0.75 and tool_called ->
        "Good tool use: selected #{inspect(trajectory_value(trajectory, :selected_tool))} appropriately."

      not tool_called ->
        "Incorrect: the model did not call a tool when one was needed."

      true ->
        "Incorrect tool result or final answer. Selected #{inspect(trajectory_value(trajectory, :selected_tool))} with score #{score}."
    end
  end

  @impl true
  def evaluate(%__MODULE__{} = adapter, batch, candidate, capture_traces) do
    results = Enum.map(batch, &evaluate_one(adapter, normalize_example(&1), candidate))

    {:ok,
     %GEPA.EvaluationBatch{
       outputs: Enum.map(results, & &1.output),
       scores: Enum.map(results, & &1.score),
       trajectories: if(capture_traces, do: Enum.map(results, & &1.trajectory)),
       objective_scores: Enum.map(results, & &1.objective_scores),
       num_metric_calls: length(batch)
     }}
  end

  @impl true
  def make_reflective_dataset(_adapter, _candidate, eval_batch, components_to_update) do
    trajectories = eval_batch.trajectories || []

    if trajectories == [] do
      {:error, :missing_trajectories}
    else
      {:ok,
       Map.new(components_to_update, fn component ->
         rows =
           Enum.map(trajectories, fn trajectory ->
             %{
               "Inputs" => %{"user_query" => trajectory_value(trajectory, :user_query)},
               "Generated Outputs" => %{
                 "selected_tool" => trajectory_value(trajectory, :selected_tool),
                 "tool_arguments" => trajectory_value(trajectory, :tool_arguments),
                 "answer" => trajectory_value(trajectory, :answer)
               },
               "Feedback" =>
                 trajectory_value(trajectory, :feedback) ||
                   generate_tool_feedback(trajectory, trajectory_value(trajectory, :score) || 0.0),
               "Available Tools" => trajectory_value(trajectory, :available_tools)
             }
           end)

         {component, rows}
       end)}
    end
  end

  defp evaluate_one(%__MODULE__{} = adapter, example, candidate) do
    with {:ok, tools} <- Client.list_tools(adapter.client),
         {:ok, selected_tool, arguments} <- select_tool(adapter, example, tools, candidate),
         {:ok, tool_result} <- Client.call_tool(adapter.client, selected_tool, arguments),
         {:ok, answer} <- generate_answer(adapter, example, selected_tool, tool_result, candidate) do
      output = %Output{
        selected_tool: selected_tool,
        tool_arguments: arguments,
        tool_result: tool_result,
        answer: answer
      }

      score = score_output(adapter, example, output)

      objective_scores = %{
        "accuracy" => score,
        "tool_selection" => tool_score(example, selected_tool)
      }

      trajectory = %Trajectory{
        user_query: example.user_query,
        available_tools: tools,
        selected_tool: selected_tool,
        tool_arguments: arguments,
        tool_result: tool_result,
        answer: answer,
        reference_answer: example.reference_answer,
        score: score,
        feedback: feedback(example, output, score)
      }

      %{output: output, score: score, objective_scores: objective_scores, trajectory: trajectory}
    else
      {:error, reason} -> failure(adapter, example, reason)
    end
  end

  defp select_tool(%__MODULE__{tool_selector: selector}, example, tools, candidate)
       when is_function(selector, 3) do
    selector.(example, tools, candidate) |> normalize_tool_selection()
  end

  defp select_tool(%__MODULE__{} = adapter, example, tools, candidate) do
    expected = example.expected_tool

    cond do
      is_binary(expected) ->
        {:ok, expected, stringify_map(example.tool_arguments || %{})}

      length(tools) == 1 ->
        tool = hd(tools)
        {:ok, tool_name(tool), stringify_map(example.tool_arguments || %{})}

      adapter.model != nil ->
        prompt = tool_selection_prompt(example, tools, candidate)

        case GEPA.LLM.complete(adapter.model, prompt) do
          {:ok, raw} -> parse_tool_json(raw)
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :no_tool_selector}
    end
  end

  defp generate_answer(
         %__MODULE__{answer_generator: generator},
         example,
         selected_tool,
         tool_result,
         candidate
       )
       when is_function(generator, 4) do
    {:ok, generator.(example, selected_tool, tool_result, candidate)}
  end

  defp generate_answer(%__MODULE__{model: nil}, _example, _selected_tool, tool_result, _candidate) do
    {:ok, result_to_answer(tool_result)}
  end

  defp generate_answer(%__MODULE__{model: model}, example, selected_tool, tool_result, candidate) do
    prompt =
      Map.get(candidate, "answer_prompt") ||
        "Use the tool result to answer the user query.\nQuery: {query}\nTool: {tool}\nResult: {result}"

    prompt =
      prompt
      |> String.replace("{query}", to_string(example.user_query))
      |> String.replace("{tool}", to_string(selected_tool))
      |> String.replace("{result}", inspect(tool_result, pretty: true))

    GEPA.LLM.complete(model, prompt)
  end

  defp score_output(%__MODULE__{scoring_fn: scoring_fn}, example, output)
       when is_function(scoring_fn, 2) do
    scoring_fn.(example, output) * 1.0
  end

  defp score_output(_adapter, example, %Output{} = output) do
    cond do
      is_nil(example.reference_answer) ->
        tool_score(example, output.selected_tool)

      String.contains?(
        String.downcase(to_string(output.answer)),
        String.downcase(to_string(example.reference_answer))
      ) ->
        1.0

      true ->
        0.0
    end
  end

  defp tool_score(%{expected_tool: expected}, selected) when is_binary(expected) do
    if expected == selected, do: 1.0, else: 0.0
  end

  defp tool_score(_example, _selected), do: 1.0

  defp failure(%__MODULE__{} = adapter, example, reason) do
    output = %Output{answer: "MCP error: #{inspect(reason)}"}

    trajectory = %Trajectory{
      user_query: example.user_query,
      selected_tool: nil,
      tool_arguments: %{},
      tool_result: nil,
      answer: output.answer,
      reference_answer: example.reference_answer,
      score: adapter.failure_score,
      feedback: "Evaluation failed: #{inspect(reason)}"
    }

    %{
      output: output,
      score: adapter.failure_score,
      objective_scores: %{"accuracy" => adapter.failure_score},
      trajectory: trajectory
    }
  end

  defp feedback(example, %Output{} = output, score) do
    "Score: #{score}. Selected tool #{inspect(output.selected_tool)} with arguments #{inspect(output.tool_arguments)}. Reference answer: #{inspect(example.reference_answer)}. Answer: #{inspect(output.answer)}"
  end

  defp tool_selection_prompt(example, tools, candidate) do
    instructions =
      Map.get(candidate, "tool_selection") || Map.get(candidate, "system_prompt") ||
        "Choose the best tool."

    """
    #{instructions}

    User query: #{example.user_query}

    Available tools:
    #{Jason.encode!(tools, pretty: true)}

    Return JSON: {"tool": "tool_name", "arguments": {...}}
    """
  end

  defp parse_tool_json(raw) do
    cleaned =
      raw
      |> to_string()
      |> String.trim()
      |> String.replace(~r/^```\S*\n?/, "", global: false)
      |> String.replace(~r/```$/, "", global: false)
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{} = map} ->
        {:ok, Map.get(map, "tool") || Map.get(map, "name"),
         stringify_map(Map.get(map, "arguments", %{}))}

      other ->
        {:error, {:invalid_tool_selection, other}}
    end
  end

  defp normalize_tool_selection({:ok, tool, args}),
    do: {:ok, to_string(tool), stringify_map(args || %{})}

  defp normalize_tool_selection({:error, reason}), do: {:error, reason}

  defp normalize_tool_selection({tool, args}),
    do: {:ok, to_string(tool), stringify_map(args || %{})}

  defp normalize_tool_selection(tool) when is_binary(tool), do: {:ok, tool, %{}}

  defp normalize_example(%DataInst{} = example), do: Map.from_struct(example)

  defp normalize_example(example) when is_map(example) do
    %{
      user_query: get_any_key(example, [:user_query, "user_query", :input, "input"]),
      tool_arguments: get_any_key(example, [:tool_arguments, "tool_arguments"]) || %{},
      reference_answer:
        get_any_key(example, [:reference_answer, "reference_answer", :answer, "answer"]),
      expected_tool: get_any_key(example, [:expected_tool, "expected_tool"]),
      metadata: get_any_key(example, [:metadata, "metadata"]) || %{}
    }
  end

  defp get_any_key(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp result_to_answer(result) when is_binary(result), do: result
  defp result_to_answer(result), do: inspect(result, pretty: true)

  defp tool_name(tool), do: Map.get(tool, "name") || Map.get(tool, :name)

  defp stringify_map(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify_map(_), do: %{}

  defp normalize_tool_names(names) when is_list(names), do: Enum.map(names, &to_string/1)
  defp normalize_tool_names(name) when is_binary(name) or is_atom(name), do: [to_string(name)]
  defp normalize_tool_names(_names), do: []

  defp candidate_tool_description(candidate, name, tool) do
    Map.get(candidate, "tool_description_#{name}") ||
      Map.get(candidate, "tool_description") ||
      Map.get(tool, "description") ||
      Map.get(tool, :description) ||
      ""
  end

  defp extract_content_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      %{type: "text", text: text} -> text
      %{"type" => "image", "mimeType" => mime_type} -> "[Image: #{mime_type}]"
      %{type: "image", mimeType: mime_type} -> "[Image: #{mime_type}]"
      %{"type" => "image", "mime_type" => mime_type} -> "[Image: #{mime_type}]"
      %{type: "image", mime_type: mime_type} -> "[Image: #{mime_type}]"
      other -> inspect(other, pretty: true)
    end)
  end

  defp extract_content_text(content), do: to_string(content)

  defp trajectory_value(%Trajectory{} = trajectory, key), do: Map.get(trajectory, key)

  defp trajectory_value(%{} = trajectory, key),
    do: get_any_key(trajectory, [key, Atom.to_string(key)])
end
