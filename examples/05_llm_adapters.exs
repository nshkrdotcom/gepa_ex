#!/usr/bin/env elixir

# GEPA LLM Adapter Facade And Live Smoke Test
# ===========================================
#
# Demonstrates the temporary GEPA LLM facade that can route through:
# - ReqLLM for hosted providers: OpenAI, Gemini, Anthropic
# - Agent Session Manager for local CLI/agent providers
#
# The first half is deterministic and injects fake adapter modules.
# The final section is live and makes one hosted-provider LLM call.
# It is not hidden behind a shell-variable flag and does not read shell variables.
#
# ## To run the full example:
#   mix run examples/05_llm_adapters.exs -- --provider openai --api-key sk-...
#   mix run examples/05_llm_adapters.exs -- --provider gemini --api-key ...
#   mix run examples/05_llm_adapters.exs -- --provider anthropic --api-key ...

{opts, _args, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      provider: :string,
      api_key: :string,
      model: :string
    ]
  )

if invalid != [] do
  raise ArgumentError, "invalid arguments: #{inspect(invalid)}"
end

live_provider =
  case Keyword.get(opts, :provider, "openai") do
    "openai" -> :openai
    "gemini" -> :gemini
    "anthropic" -> :anthropic
    other -> raise ArgumentError, "unsupported --provider #{inspect(other)}; use openai, gemini, or anthropic"
  end

live_api_key = Keyword.get(opts, :api_key)
live_model = Keyword.get(opts, :model)

defmodule ExampleReqLLM do
  def put_key(_key, _value), do: :ok

  def generate_text(model_spec, prompt, opts) do
    {:ok, %{text: "hosted:#{model_spec}:#{prompt}", opts: opts}}
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

defmodule ExampleReqLLMResponse do
  def text(%{text: text}), do: text
  def text(_response), do: nil

  def unwrap_object(%{object: object}), do: {:ok, object}
end

defmodule ExampleASM do
  def query(target, prompt, opts) do
    {:ok,
     %{
       text: "agent:#{inspect(target)}:#{prompt}",
       run_id: "example-run",
       session_id: "example-session",
       metadata: %{opts: opts}
     }}
  end

  def stream(_session, _prompt, _opts), do: ["agent ", "stream ", "chunks"]
  def stop_session(_session), do: :ok
end

IO.puts("""
GEPA LLM Adapter Facade And Live Smoke Test
===========================================
""")

hosted =
  GEPA.LLM.req_llm(:anthropic,
    api_key: "example-key",
    req_llm_module: ExampleReqLLM,
    response_module: ExampleReqLLMResponse
  )

{:ok, hosted_text} = GEPA.LLM.complete(hosted, "hello")
{:ok, hosted_object} = GEPA.LLM.complete_structured(hosted, "improve this instruction")

IO.puts("ReqLLM text response: #{hosted_text}")
IO.inspect(hosted_object, label: "ReqLLM structured response")

agent = GEPA.LLM.agent(:codex, asm_module: ExampleASM, lane: :core, session: :example_session)

{:ok, agent_text} = GEPA.LLM.complete(agent, "summarize the current task")
{:ok, agent_stream} = GEPA.LLM.stream(agent, "stream this")

IO.puts("ASM text response: #{agent_text}")
IO.puts("ASM stream response: #{Enum.join(agent_stream)}")

case GEPA.LLM.complete_structured(agent, "return JSON") do
  {:error, {:unsupported_capability, :structured_output, _context}} ->
    IO.puts("ASM structured output correctly fails closed.")
end

IO.puts("""

LIVE HOSTED PROVIDER CALL
=========================

This section makes exactly one live hosted-provider LLM call through the GEPA LLM facade.
Provider: #{live_provider}
Model override: #{live_model || "(adapter default)"}

Provide credentials with --api-key. This example intentionally does not read
shell variables and does not skip the live call automatically.
""")

if is_nil(live_api_key) or live_api_key == "" do
  raise ArgumentError, """
  missing required --api-key for the live hosted-provider call

  Examples:
    mix run examples/05_llm_adapters.exs -- --provider openai --api-key sk-...
    mix run examples/05_llm_adapters.exs -- --provider gemini --api-key ...
    mix run examples/05_llm_adapters.exs -- --provider anthropic --api-key ...
  """
end

live_opts = [api_key: live_api_key]
live_opts = if live_model, do: Keyword.put(live_opts, :model, live_model), else: live_opts
live_client = GEPA.LLM.req_llm(live_provider, live_opts)

{:ok, live_response} =
  GEPA.LLM.complete(live_client, "Reply with exactly: gepa adapter ok", max_tokens: 20)

IO.puts("Live response: #{live_response}")
