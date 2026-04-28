# LLM and Adapters

GEPA has two adapter layers with different responsibilities:

- `GEPA.LLM` adapters call language-model backends and normalize provider responses.
- `GEPA.Adapter` task adapters evaluate candidates, build reflective datasets, and optionally own task-specific proposal logic.

Use "provider" for the selected model backend, such as `:openai` or `:codex`. Use "adapter" for the Elixir module that connects GEPA to that backend or task boundary.

## LLM Facade

`GEPA.LLM` is the public model-access facade. It returns either a normalized `GEPA.LLM.Client` or a backward-compatible struct that still dispatches through the same adapter code.

- `GEPA.LLM.req_llm/2` builds a hosted-provider client backed by ReqLLM.
- `GEPA.LLM.agent/2` builds a local CLI/agent client backed by Agent Session Manager.
- `GEPA.LLM.new/2` builds either adapter family from `:req_llm`, `:agent_session_manager`, or `:asm`.
- `GEPA.LLM.complete/3` runs plain text completion.
- `GEPA.LLM.complete_structured/3` requests structured output.
- `GEPA.LLM.stream/3` streams token output when the selected client supports streaming.
- `GEPA.LLM.default/0` reads `:gepa_ex, :llm` application config and builds the default ReqLLM-backed provider.

The normalized request and response structs are `GEPA.LLM.Request` and `GEPA.LLM.Response`. Optimizer and proposer code should depend on the facade, not on provider-native response shapes.

## Hosted Providers

Hosted providers go through `GEPA.LLM.Adapters.ReqLLM`.

| Provider | Builder | Default model | API key lookup | Capabilities |
| --- | --- | --- | --- | --- |
| OpenAI | `GEPA.LLM.req_llm(:openai, opts)` | `gpt-5.4-mini` | `OPENAI_API_KEY` | text, messages, structured output, tools, cost metadata |
| Gemini | `GEPA.LLM.req_llm(:gemini, opts)` | `gemini-3.1-flash-lite-preview` | `GEMINI_API_KEY`, then `GOOGLE_API_KEY` | text, messages, structured output, tools, cost metadata |
| Anthropic | `GEPA.LLM.req_llm(:anthropic, opts)` | `claude-haiku-4-5` | `ANTHROPIC_API_KEY` | text, messages, structured output, tools, cost metadata |

Examples:

```elixir
openai = GEPA.LLM.req_llm(:openai)
gemini = GEPA.LLM.req_llm(:gemini, model: "gemini-3.1-flash-lite-preview")
anthropic = GEPA.LLM.req_llm(:anthropic, model: "claude-haiku-4-5")

{:ok, text} = GEPA.LLM.complete(openai, "Explain GEPA in one sentence.")
```

You can override common generation options per client or per call:

```elixir
llm =
  GEPA.LLM.req_llm(:anthropic,
    temperature: 0.2,
    max_tokens: 800,
    timeout: 60_000
  )

{:ok, text} =
  GEPA.LLM.complete(llm, "Summarize this trace.", temperature: 0.0)
```

Provider-specific generation options belong in `:provider_opts`; shared ReqLLM request options belong in `:req_options`.

```elixir
llm =
  GEPA.LLM.req_llm(:openai,
    provider_opts: [reasoning_effort: "low"],
    req_options: [receive_timeout: 90_000]
  )
```

## Local Agent Providers

Local CLI-backed providers go through `GEPA.LLM.Adapters.AgentSessionManager`.

| Provider | Builder | Default model | Lanes | Capabilities |
| --- | --- | --- | --- | --- |
| Codex | `GEPA.LLM.agent(:codex, opts)` | `gpt-5.4-mini` | `:auto`, `:core`, `:sdk` | text, stream, session, session resume, cost metadata |
| Codex Exec | `GEPA.LLM.agent(:codex_exec, opts)` | ASM default unless `:model` is provided | `:auto`, `:core`, `:sdk` | text, stream, session, session resume, cost metadata |
| Claude | `GEPA.LLM.agent(:claude, opts)` | ASM default unless `:model` is provided | `:auto`, `:core`, `:sdk` | text, stream, session, session resume, cost metadata |
| Gemini | `GEPA.LLM.agent(:gemini, opts)` | `gemini-3.1-flash-lite-preview` | `:auto`, `:core`, `:sdk` | text, stream, session, session resume, cost metadata |
| Amp | `GEPA.LLM.agent(:amp, opts)` | ASM default unless `:model` is provided | `:auto`, `:core`, `:sdk` | text, stream, session, session resume, cost metadata |

Example:

```elixir
agent =
  GEPA.LLM.agent(:gemini,
    lane: :core,
    session: "gepa-reflection",
    provider_opts: [model: "gemini-3.1-flash-lite-preview"]
  )

{:ok, text} = GEPA.LLM.complete(agent, "Rewrite this prompt.")
```

Streaming is exposed on the ASM path:

```elixir
{:ok, stream} = GEPA.LLM.stream(agent, "Stream a short answer.")
Enum.each(stream, &IO.write/1)
```

ASM structured output is intentionally unsupported until ASM exposes a native structured-output contract. `GEPA.LLM.complete_structured/3` fails closed with `{:unsupported_capability, :structured_output, context}` for ASM clients.

## Embeddings

Embeddings use a separate facade from text inference:

```elixir
embedder =
  GEPA.Embeddings.ReqLLM.new!(
    provider: :gemini,
    model: "gemini-embedding-001"
  )

{:ok, vector} = GEPA.Embeddings.embed(embedder, "Index this document.")
```

The default Generic RAG integration uses ReqLLM/Gemini embeddings and
Agent Session Manager/Gemini inference. Qdrant stores and searches vectors; it
does not create embeddings.

## Live Smoke Commands

ReqLLM/Gemini text:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter req_llm \
  --provider gemini \
  --input "Reply with exactly: req_llm gemini ok"
```

Agent Session Manager/Gemini text:

```bash
mix run examples/05_llm_adapters.exs -- \
  --adapter asm \
  --provider gemini \
  --model gemini-3.1-flash-lite-preview \
  --input "Reply with exactly: asm gemini ok"
```

## Compatibility APIs

`GEPA.LLM.ReqLLM` is kept for older code that expects a provider struct:

```elixir
llm = GEPA.LLM.ReqLLM.new(provider: :gemini)
{:ok, text} = GEPA.LLM.complete(llm, "Hello")
```

New code should prefer `GEPA.LLM.req_llm/2`, because it returns the normalized `GEPA.LLM.Client` shape and exposes capabilities consistently.

`GEPA.LLM.Mock` is for tests and deterministic local exercises. The public examples are live-only and use real backends through the facade.

## Structured Output

`GEPA.LLM.complete_structured/3` asks the selected LLM adapter for a map. Hosted providers use ReqLLM object generation and default to the instruction proposal schema:

```elixir
{:ok, %{"instruction" => instruction}} =
  GEPA.LLM.complete_structured(
    GEPA.LLM.req_llm(:gemini),
    "Return an improved instruction for a concise QA assistant."
  )
```

You can provide a custom schema when calling the facade directly:

```elixir
schema = [
  instruction: [type: :string, required: true],
  rationale: [type: :string, required: false]
]

{:ok, object} = GEPA.LLM.complete_structured(llm, prompt, schema: schema)
```

`GEPA.Proposer.InstructionProposal` uses this path when `structured_output: true` is set on `GEPA.optimize/1`, `GEPA.Proposer.InstructionProposal.new/1`, or `GEPA.OptimizeAnything` reflection config. If an older behavior implementation does not define `complete_structured/3`, GEPA falls back to calling `complete/3`, parsing JSON when possible, and wrapping plain text as `%{"instruction" => text}`.

## Tools

`GEPA.LLM.Tool` is the GEPA-facing portable tool shape. The ReqLLM adapter converts these tools to ReqLLM tools and passes them to hosted providers:

```elixir
tool =
  GEPA.LLM.Tool.new(
    name: "lookup",
    description: "Look up a value by key",
    input_schema: [key: [type: :string, required: true]],
    run: fn args, _context -> {:ok, %{"value" => args["key"]}} end
  )

{:ok, text} = GEPA.LLM.complete(llm, "Use the lookup tool.", tools: [tool])
```

Tool execution support depends on the selected ReqLLM provider and model. ASM tool-loop support is not exposed by GEPA yet and remains capability-gated.

## Task Adapter Contract

A `GEPA.Adapter` connects the optimizer to your task. It is not the same thing as an LLM adapter.

Required callbacks:

- `evaluate(adapter, batch, candidate, capture_traces)` returns `{:ok, %GEPA.EvaluationBatch{}}` or `{:error, reason}`.
- `make_reflective_dataset(adapter, candidate, eval_batch, components_to_update)` returns per-component feedback records.

Optional callbacks:

- `propose_new_texts(candidate, reflective_dataset, components_to_update)` for legacy custom proposal logic.
- `propose_new_texts(adapter, candidate, reflective_dataset, components_to_update)` for stateful custom proposal logic.
- `get_adapter_state(adapter)` and `set_adapter_state(adapter, state)` for run persistence and resume.

Reflective records should be JSON-serializable maps. The conventional keys are:

```elixir
%{
  "Inputs" => %{...},
  "Generated Outputs" => "...",
  "Feedback" => "..."
}
```

## Shipped Task Adapters

`GEPA.Adapters.Basic` is a small Q&A adapter. It accepts `:llm` or `:llm_client`, calls the model through `GEPA.LLM.complete/3`, and scores an example as correct when the expected answer appears in the response.

```elixir
llm = GEPA.LLM.req_llm(:openai)
adapter = GEPA.Adapters.Basic.new(llm: llm)
```

`GEPA.Adapters.Default` is the prompt-only/chat-style adapter. It takes a task model callable or a `GEPA.LLM` client and an optional evaluator.

```elixir
adapter =
  GEPA.Adapters.Default.new(
    model: GEPA.LLM.req_llm(:gemini),
    evaluator: fn example, response ->
      if String.contains?(response, example.answer), do: {1.0, "correct"}, else: {0.0, "missing answer"}
    end
  )
```

Use a custom `GEPA.Adapter` when your task has its own execution environment, trace format, scoring rules, or proposal rules.

## Configuration Defaults

`GEPA.LLM.default/0` reads:

```elixir
config :gepa_ex, :llm,
  provider: :openai,
  model: "gpt-5.4-mini",
  temperature: 0.7
```

Supported default providers are `:openai`, `:gemini`, `:anthropic`, and `:mock`. Hosted provider keys are resolved the same way as `GEPA.LLM.req_llm/2`.

The example CLI has its own provider inference so scripts can run without application config. See [Examples and Livebooks](examples_and_livebooks.md) and `examples/README.md` for that matrix.

## Choosing The Right Piece

- Use `GEPA.LLM.req_llm/2` for hosted APIs and structured instruction proposals.
- Use `GEPA.LLM.agent/2` when inference should happen through a local CLI or persistent agent session.
- Use `GEPA.Adapters.Basic` for small Q&A experiments.
- Use `GEPA.Adapters.Default` for single-prompt or chat-style tasks.
- Implement `GEPA.Adapter` directly for production tasks with domain-specific evaluation or trace capture.
- Add adapter-owned `propose_new_texts/4` only when the generic reflective proposal is not expressive enough for the task.
