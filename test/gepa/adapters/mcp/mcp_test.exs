defmodule GEPA.Adapters.MCPTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.MCP
  alias GEPA.Adapters.MCP.Client
  alias GEPA.Adapters.MCP.Client.{SSE, Static, Stdio, StreamableHTTP}

  defp server_params, do: %{command: "python", args: ["server.py"]}

  defp simple_metric(item, output) do
    reference = Map.get(item, :reference_answer) || Map.get(item, "reference_answer") || ""
    answer = Map.get(output, :answer) || Map.get(output, "answer") || inspect(output)

    if reference != "" and String.contains?(String.downcase(answer), String.downcase(reference)) do
      1.0
    else
      0.0
    end
  end

  defp mock_model(_messages),
    do: ~s({"action":"call_tool","tool":"read_file","arguments":{"path":"test.txt"}})

  defp helper_adapter(opts \\ []) do
    MCP.new(
      Keyword.merge(
        [
          tool_names: "read_file",
          task_model: "gpt-4o-mini",
          metric_fn: &simple_metric/2,
          server_params: server_params()
        ],
        opts
      )
    )
  end

  test "evaluates a static MCP tool call and builds reflection data" do
    client =
      Static.new(
        tools: %{
          "read_file" => %{
            description: "Read a file",
            input_schema: %{"path" => "string"},
            run: fn %{"path" => path} -> "contents of #{path}: hello" end
          }
        }
      )

    adapter = MCP.new(client: client)

    batch = [
      %{
        user_query: "What's in notes.txt?",
        expected_tool: "read_file",
        tool_arguments: %{path: "notes.txt"},
        reference_answer: "hello"
      }
    ]

    candidate = %{"tool_selection" => "Select file tools."}

    assert {:ok, eval_batch} = MCP.evaluate(adapter, batch, candidate, true)
    assert eval_batch.scores == [1.0]
    assert [%MCP.Output{selected_tool: "read_file"}] = eval_batch.outputs

    assert {:ok, dataset} =
             MCP.make_reflective_dataset(adapter, candidate, eval_batch, ["tool_selection"])

    assert [%{"Generated Outputs" => generated}] = dataset["tool_selection"]
    assert generated["selected_tool"] == "read_file"
  end

  describe "client factory upstream parity" do
    test "creates stdio client" do
      assert %Stdio{command: "python", args: ["server.py"]} =
               Client.create(server_params: server_params())
    end

    test "creates SSE client" do
      assert %SSE{url: "https://example.com/sse"} =
               Client.create(remote_url: "https://example.com/sse", remote_transport: "sse")
    end

    test "creates streamable HTTP client" do
      assert %StreamableHTTP{url: "https://example.com/mcp"} =
               Client.create(
                 remote_url: "https://example.com/mcp",
                 remote_transport: "streamable_http"
               )
    end

    test "rejects both local and remote params" do
      assert_raise ArgumentError, ~r/not both/, fn ->
        Client.create(server_params: server_params(), remote_url: "https://example.com")
      end
    end

    test "requires local or remote params" do
      assert_raise ArgumentError, ~r/must provide either/i, fn ->
        Client.create([])
      end
    end

    test "rejects unknown remote transport" do
      assert_raise ArgumentError, ~r/unknown remote transport/i, fn ->
        Client.create(remote_url: "https://example.com", remote_transport: "invalid")
      end
    end
  end

  describe "adapter initialization upstream parity" do
    test "creates adapter with single tool" do
      adapter = helper_adapter()

      assert adapter.tool_names == ["read_file"]
      assert adapter.task_model == "gpt-4o-mini"
      assert adapter.enable_two_pass == true
    end

    test "creates adapter with multiple tools" do
      adapter = helper_adapter(tool_names: ["read_file", "write_file", "list_files"])

      assert adapter.tool_names == ["read_file", "write_file", "list_files"]
      assert length(adapter.tool_names) == 3
    end

    test "creates remote SSE adapter" do
      adapter =
        MCP.new(
          tool_names: "search",
          task_model: "gpt-4o-mini",
          metric_fn: &simple_metric/2,
          remote_url: "https://example.com/sse",
          remote_transport: "sse",
          remote_headers: %{"Authorization" => "Bearer token"}
        )

      assert adapter.remote_url == "https://example.com/sse"
      assert adapter.remote_transport == "sse"
      assert adapter.remote_headers["Authorization"] == "Bearer token"
      assert %SSE{} = adapter.client
    end

    test "creates remote streamable HTTP adapter" do
      adapter =
        MCP.new(
          tool_names: "search",
          task_model: "gpt-4o-mini",
          metric_fn: &simple_metric/2,
          remote_url: "https://example.com/mcp",
          remote_transport: "streamable_http"
        )

      assert adapter.remote_transport == "streamable_http"
      assert %StreamableHTTP{} = adapter.client
    end

    test "accepts callable task model" do
      adapter = helper_adapter(task_model: &mock_model/1)

      assert is_function(adapter.task_model, 1)
    end

    test "stores custom parameters" do
      adapter =
        helper_adapter(
          base_system_prompt: "Custom prompt",
          enable_two_pass: false,
          failure_score: 0.5
        )

      assert adapter.base_system_prompt == "Custom prompt"
      assert adapter.enable_two_pass == false
      assert adapter.failure_score == 0.5
    end
  end

  describe "adapter helper upstream parity" do
    test "builds system prompt with single tool description" do
      adapter = helper_adapter()
      candidate = %{"tool_description" => "Custom description"}
      tools = [%{"name" => "read_file", "description" => "Original", "inputSchema" => %{}}]

      prompt = MCP.build_system_prompt(adapter, candidate, tools)

      assert prompt =~ "Custom description"
      assert prompt =~ "read_file"
      assert prompt =~ "call_tool"
    end

    test "builds system prompt with multiple tool descriptions" do
      adapter = helper_adapter(tool_names: ["tool1", "tool2"])

      candidate = %{
        "tool_description_tool1" => "Description 1",
        "tool_description_tool2" => "Description 2"
      }

      tools = [
        %{"name" => "tool1", "description" => "Default 1", "inputSchema" => %{}},
        %{"name" => "tool2", "description" => "Default 2", "inputSchema" => %{}}
      ]

      prompt = MCP.build_system_prompt(adapter, candidate, tools)

      assert prompt =~ "Description 1"
      assert prompt =~ "Description 2"
      assert prompt =~ "tool1"
      assert prompt =~ "tool2"
    end

    test "extracts text content from tool response" do
      result = %{
        "content" => [
          %{"type" => "text", "text" => "Line 1"},
          %{"type" => "text", "text" => "Line 2"}
        ]
      }

      assert MCP.extract_tool_response(result) == "Line 1\nLine 2"
      assert MCP.extract_tool_response(%{"content" => []}) == ""
    end

    test "extracts error tool response" do
      result = %{isError: true, content: [%{type: "text", text: "File not found"}]}

      extracted = MCP.extract_tool_response(result)
      assert extracted =~ "ERROR"
      assert extracted =~ "File not found"
    end

    test "extracts structured tool response" do
      extracted =
        MCP.extract_tool_response(%{structuredContent: %{"name" => "John", "age" => 30}})

      assert extracted =~ "John"
      assert extracted =~ "30"
    end

    test "extracts image tool response marker" do
      extracted =
        MCP.extract_tool_response(%{
          content: [%{type: "image", data: "fake_image_data", mimeType: "image/png"}]
        })

      assert extracted =~ "Image"
      assert extracted =~ "image/png"
    end

    test "generates success feedback" do
      feedback =
        MCP.generate_tool_feedback(
          %{
            user_query: "test",
            selected_tool: "read_file",
            tool_called: true,
            score: 0.8
          },
          0.8
        )

      assert feedback =~ "Good" or feedback =~ "appropriately"
    end

    test "generates failure feedback" do
      feedback =
        MCP.generate_tool_feedback(
          %{
            user_query: "test",
            selected_tool: nil,
            tool_called: false,
            score: 0.0
          },
          0.0
        )

      assert feedback =~ "Incorrect" or feedback =~ "not call"
    end
  end

  describe "evaluation and reflective dataset upstream parity" do
    test "evaluate returns configured batch structure" do
      adapter = helper_adapter(task_model: &mock_model/1)

      assert adapter.tool_names == ["read_file"]
      assert is_function(adapter.metric_fn, 2)
    end

    test "make_reflective_dataset builds tool_description examples" do
      adapter = helper_adapter()

      eval_batch = %GEPA.EvaluationBatch{
        outputs: [
          %MCP.Output{
            selected_tool: "read_file",
            tool_arguments: %{"path" => "test.txt"},
            tool_result: "resp",
            answer: "answer"
          }
        ],
        scores: [1.0],
        trajectories: [
          %MCP.Trajectory{
            user_query: "What's in the file?",
            available_tools: [%{"name" => "read_file"}],
            selected_tool: "read_file",
            tool_arguments: %{"path" => "test.txt"},
            tool_result: "content",
            answer: "The file contains...",
            score: 1.0,
            feedback: "Good"
          }
        ]
      }

      assert {:ok, reflective_data} =
               MCP.make_reflective_dataset(
                 adapter,
                 %{"tool_description" => "Read file contents from disk."},
                 eval_batch,
                 ["tool_description"]
               )

      assert [%{"Inputs" => _, "Generated Outputs" => _, "Feedback" => _}] =
               reflective_data["tool_description"]
    end

    test "make_reflective_dataset builds system_prompt examples" do
      adapter = helper_adapter()

      eval_batch = %GEPA.EvaluationBatch{
        outputs: [%{final_answer: "wrong", tool_called: false}],
        scores: [0.0],
        trajectories: [
          %{
            user_query: "Test query",
            selected_tool: nil,
            tool_called: false,
            tool_arguments: nil,
            answer: "Wrong answer",
            score: 0.0
          }
        ]
      }

      assert {:ok, reflective_data} =
               MCP.make_reflective_dataset(
                 adapter,
                 %{"tool_description" => "Read file contents from disk."},
                 eval_batch,
                 ["system_prompt"]
               )

      assert [_example] = reflective_data["system_prompt"]
    end
  end

  describe "type and import upstream parity" do
    test "MCP types can be loaded" do
      assert {:module, MCP.DataInst} = Code.ensure_loaded(MCP.DataInst)
      assert {:module, MCP.Output} = Code.ensure_loaded(MCP.Output)
      assert {:module, MCP.Trajectory} = Code.ensure_loaded(MCP.Trajectory)
    end

    test "MCP adapter compatibility alias can be loaded" do
      assert {:module, GEPA.Adapters.MCPAdapter} = Code.ensure_loaded(GEPA.Adapters.MCPAdapter)
      assert function_exported?(GEPA.Adapters.MCPAdapter, :new, 1)
    end
  end

  describe "multi-tool and two-pass upstream parity" do
    test "initializes with multiple tools" do
      tools = ["read_file", "write_file", "list_files"]
      adapter = helper_adapter(tool_names: tools)

      assert adapter.tool_names == tools
      assert length(adapter.tool_names) == 3
    end

    test "generates system prompt with multiple tools" do
      adapter = helper_adapter(tool_names: ["tool1", "tool2"])

      prompt =
        MCP.build_system_prompt(
          adapter,
          %{"tool_description_tool1" => "Desc 1", "tool_description_tool2" => "Desc 2"},
          [
            %{"name" => "tool1", "description" => "Default 1", "inputSchema" => %{}},
            %{"name" => "tool2", "description" => "Default 2", "inputSchema" => %{}}
          ]
        )

      assert prompt =~ "tool1"
      assert prompt =~ "tool2"
      assert prompt =~ "Desc 1"
      assert prompt =~ "Desc 2"
    end

    test "two-pass workflow is enabled by default" do
      assert helper_adapter().enable_two_pass == true
    end

    test "two-pass workflow can be disabled" do
      assert helper_adapter(enable_two_pass: false).enable_two_pass == false
    end
  end
end
