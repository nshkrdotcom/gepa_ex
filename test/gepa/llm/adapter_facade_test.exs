defmodule GEPA.LLM.AdapterFacadeTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.LLM.{Client, Request, Tool}

  defmodule FakeReqLLM do
    def put_key(_key, _value), do: :ok

    def generate_text(model_spec, prompt, opts) do
      {:ok, %{text: "text:#{model_spec}:#{prompt}", usage: %{tokens: 7}, opts: opts}}
    end

    def generate_object(model_spec, prompt, schema, opts) do
      {:ok,
       %{
         object: %{"instruction" => "structured:#{model_spec}:#{prompt}"},
         schema: schema,
         opts: opts
       }}
    end
  end

  defmodule FakeReqLLMResponse do
    def text(%{text: text}), do: text
    def unwrap_object(%{object: object}), do: {:ok, object}
  end

  defmodule FakeASM do
    def query(target, prompt, opts) do
      {:ok,
       %{
         run_id: "run-1",
         session_id: "session-1",
         text: "asm:#{inspect(target)}:#{prompt}",
         cost: %{usd: 0.0},
         stop_reason: :stop,
         metadata: %{opts: opts}
       }}
    end

    def stream(_session, _prompt, _opts), do: ["a", "b"]
    def stop_session(_session), do: :ok
  end

  describe "ReqLLM client facade" do
    test "builds a normalized client for Anthropic through ReqLLM" do
      client =
        GEPA.LLM.req_llm(:anthropic,
          api_key: "sk-test",
          req_llm_module: FakeReqLLM,
          response_module: FakeReqLLMResponse
        )

      assert %Client{} = client
      assert client.provider == :anthropic
      assert client.model == "claude-haiku-4-5"
      assert MapSet.member?(client.capabilities, :structured_output)
    end

    test "complete/3 dispatches a normalized client through the adapter" do
      client =
        GEPA.LLM.req_llm(:anthropic,
          api_key: "sk-test",
          req_llm_module: FakeReqLLM,
          response_module: FakeReqLLMResponse
        )

      assert {:ok, "text:anthropic:claude-haiku-4-5:hello"} =
               GEPA.LLM.complete(client, "hello")
    end

    test "complete_structured/3 uses ReqLLM object generation" do
      client =
        GEPA.LLM.req_llm(:openai,
          api_key: "sk-test",
          model: "gpt-test",
          req_llm_module: FakeReqLLM,
          response_module: FakeReqLLMResponse
        )

      assert {:ok, %{"instruction" => "structured:openai:gpt-test:prompt"}} =
               GEPA.LLM.complete_structured(client, "prompt")
    end

    test "converts portable tools to ReqLLM tools" do
      client =
        GEPA.LLM.req_llm(:openai,
          api_key: "sk-test",
          req_llm_module: FakeReqLLM,
          response_module: FakeReqLLMResponse
        )

      tool =
        Tool.new(
          name: "lookup",
          description: "Look up a value",
          input_schema: [query: [type: :string, required: true]],
          run: fn args, _context -> {:ok, args} end
        )

      request = Request.from_prompt("hello", tools: [tool])

      assert {:ok, response} = client.adapter.complete(client, request)
      assert [%ReqLLM.Tool{name: "lookup"}] = response.raw.opts[:tools]
    end
  end

  describe "ASM client facade" do
    test "builds a normalized agent client" do
      client = GEPA.LLM.agent(:codex, asm_module: FakeASM, lane: :core)

      assert %Client{} = client
      assert client.provider == :codex
      assert MapSet.member?(client.capabilities, :stream)
      refute MapSet.member?(client.capabilities, :structured_output)
    end

    test "complete/3 dispatches to ASM query and normalizes metadata" do
      client = GEPA.LLM.agent(:codex, asm_module: FakeASM, lane: :core)

      assert {:ok, "asm::codex:hello"} = GEPA.LLM.complete(client, "hello")

      request = Request.from_prompt("hello")
      assert {:ok, response} = client.adapter.complete(client, request)
      assert response.metadata.run_id == "run-1"
      assert response.metadata.session_id == "session-1"
      assert response.metadata.lane == :core
    end

    test "structured output fails closed for ASM" do
      client = GEPA.LLM.agent(:codex, asm_module: FakeASM, lane: :core)

      assert {:error, {:unsupported_capability, :structured_output, _}} =
               GEPA.LLM.complete_structured(client, "prompt")
    end
  end
end
