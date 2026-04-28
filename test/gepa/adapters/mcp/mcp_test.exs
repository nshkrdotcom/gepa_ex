defmodule GEPA.Adapters.MCPTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapters.MCP
  alias GEPA.Adapters.MCP.Client.Static

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
end
