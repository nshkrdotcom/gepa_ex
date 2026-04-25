defmodule GEPA.LLM.AdapterFacadeTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.LLM.{Client, Request, Tool}

  defmodule FakeReqLLM do
    def put_key(key, value) do
      send(self(), {:put_key, key, value})
      :ok
    end

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
    def query(provider, prompt, opts) when is_atom(provider) and is_binary(prompt) do
      {:ok,
       %{
         run_id: "run-1",
         session_id: "session-1",
         text: "asm:#{inspect(provider)}:#{prompt}",
         cost: %{usd: 0.0},
         stop_reason: :stop,
         metadata: %{target: provider, opts: opts}
       }}
    end

    def query(session, prompt, opts) when is_pid(session) and is_binary(prompt) do
      {:ok,
       %{
         run_id: "run-1",
         session_id: "session-1",
         text: "asm:pid:#{prompt}",
         cost: %{usd: 0.0},
         stop_reason: :stop,
         metadata: %{target: session, opts: opts}
       }}
    end

    def start_session(opts) do
      send(self(), {:start_session, opts})
      {:ok, self()}
    end

    def stream(session, _prompt, _opts) when is_pid(session) do
      [
        %ASM.Event{
          id: "event-1",
          run_id: "run-1",
          session_id: "session-1",
          provider: :codex,
          kind: :assistant_delta,
          payload: %CliSubprocessCore.Payload.AssistantDelta{content: "a", metadata: %{}},
          timestamp: DateTime.utc_now()
        },
        %ASM.Event{
          id: "event-2",
          run_id: "run-1",
          session_id: "session-1",
          provider: :codex,
          kind: :run_started,
          payload: nil,
          timestamp: DateTime.utc_now()
        },
        "b"
      ]
    end

    def stop_session(session) do
      send(self(), {:stop_session, session})
      :ok
    end
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

    test "Gemini resolves GEMINI_API_KEY alias and writes ReqLLM Google key config" do
      client =
        GEPA.LLM.req_llm(:gemini,
          req_llm_module: FakeReqLLM,
          response_module: FakeReqLLMResponse,
          env: fn
            "GEMINI_API_KEY" -> "gemini-env-key"
            _key -> nil
          end
        )

      request = Request.from_prompt("hello")

      assert {:ok, response} = client.adapter.complete(client, request)
      assert response.raw.opts[:api_key] == "gemini-env-key"
      assert_received {:put_key, :google_api_key, "gemini-env-key"}
    end

    test "explicit API key overrides ReqLLM provider key aliases" do
      client =
        GEPA.LLM.req_llm(:gemini,
          api_key: "explicit-key",
          req_llm_module: FakeReqLLM,
          response_module: FakeReqLLMResponse,
          env: fn
            "GEMINI_API_KEY" -> "gemini-env-key"
            _key -> nil
          end
        )

      request = Request.from_prompt("hello")

      assert {:ok, response} = client.adapter.complete(client, request)
      assert response.raw.opts[:api_key] == "explicit-key"
      assert_received {:put_key, :google_api_key, "explicit-key"}
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
      assert client.model == "gpt-5.4-mini"
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
      assert response.metadata.opts[:model] == "gpt-5.4-mini"
    end

    test "per-call ASM model overrides the Codex default model" do
      client = GEPA.LLM.agent(:codex, asm_module: FakeASM, lane: :core)
      request = Request.from_prompt("hello", model: "gpt-explicit")

      assert {:ok, response} = client.adapter.complete(client, request)
      assert response.metadata.opts[:model] == "gpt-explicit"
    end

    test "complete/3 passes named ASM sessions as session_id query options" do
      client = GEPA.LLM.agent(:codex, asm_module: FakeASM, lane: :core, session: "gepa-test")
      request = Request.from_prompt("hello")

      assert {:ok, response} = client.adapter.complete(client, request)
      assert response.text == "asm::codex:hello"
      assert response.session_ref == "gepa-test"
      assert response.metadata.opts[:session_id] == "gepa-test"
      assert response.metadata.opts[:model] == "gpt-5.4-mini"
      assert response.metadata.target == :codex
    end

    test "stream/3 starts and closes a managed ASM session for named sessions" do
      client = GEPA.LLM.agent(:codex, asm_module: FakeASM, lane: :core, session: "gepa-stream")

      assert {:ok, stream} = GEPA.LLM.stream(client, "hello")
      assert Enum.to_list(stream) == ["a", "b"]
      assert_received {:start_session, opts}
      assert opts[:provider] == :codex
      assert opts[:session_id] == "gepa-stream"
      assert opts[:lane] == :core
      assert_received {:stop_session, pid} when pid == self()
    end

    test "structured output fails closed for ASM" do
      client = GEPA.LLM.agent(:codex, asm_module: FakeASM, lane: :core)

      assert {:error, {:unsupported_capability, :structured_output, _}} =
               GEPA.LLM.complete_structured(client, "prompt")
    end
  end
end
