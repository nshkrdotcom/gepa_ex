# LLM Adapter Design

## Current Direction

GEPA now uses a small, migration-safe LLM facade instead of wiring optimizer code directly to provider libraries.

The goal is pragmatic:

- Ship a functional GEPA port now.
- Route hosted providers through ReqLLM.
- Route local/CLI providers through Agent Session Manager.
- Keep GEPA internals dependent on a stable `GEPA.LLM.Client` boundary so the facade can later move into a shared inference package without rewriting GEPA.

## Public Surface

```elixir
# Hosted providers through ReqLLM
client = GEPA.LLM.req_llm(:openai)
client = GEPA.LLM.req_llm(:gemini)
client = GEPA.LLM.req_llm(:anthropic)

{:ok, text} = GEPA.LLM.complete(client, "Explain GEPA")
{:ok, object} = GEPA.LLM.complete_structured(client, "Improve this instruction")

# Local/CLI providers through Agent Session Manager
agent = GEPA.LLM.agent(:codex, lane: :core, session: :my_session)
{:ok, text} = GEPA.LLM.complete(agent, "Summarize this run")
```

Backward-compatible `GEPA.LLM.ReqLLM.new/1` remains available, but new code should prefer `GEPA.LLM.req_llm/2`.

## Core Types

- `GEPA.LLM.Client`: normalized client struct containing adapter module, adapter state, provider, model, defaults, capabilities, and metadata.
- `GEPA.LLM.Request`: normalized request struct for prompt/message input, structured schema, tools, generation options, session, and provider options.
- `GEPA.LLM.Response`: normalized response struct for text, structured object, usage/cost metadata, tool calls, session references, raw provider payload, and adapter metadata.
- `GEPA.LLM.Capabilities`: helper for explicit capability checks.
- `GEPA.LLM.Tool`: portable tool definition used by the facade. The first implemented slice converts tools for ReqLLM; full ASM tool-loop integration remains a later stack-level concern.

## Adapter Responsibilities

### ReqLLM Adapter

Module: `GEPA.LLM.Adapters.ReqLLM`

Responsibilities:

- Provider mapping:
  - `:openai` -> `openai:MODEL`
  - `:gemini` -> `google:MODEL`
  - `:anthropic` -> `anthropic:MODEL`
- API-key handling from explicit opts only.
- Text completion via `ReqLLM.generate_text/3`.
- Structured output via `ReqLLM.generate_object/4`.
- Response normalization into `GEPA.LLM.Response`.
- Test injection seams through `:req_llm_module` and `:response_module`.

Anthropic is intentionally routed through ReqLLM. There is no direct Anthropic HTTP client in `gepa_ex`.

### Agent Session Manager Adapter

Module: `GEPA.LLM.Adapters.AgentSessionManager`

Responsibilities:

- Provider mapping for ASM-supported local/CLI providers:
  - `:claude`
  - `:codex`
  - `:codex_exec`
  - `:gemini`
  - `:amp`
- Lane selection with `:auto`, `:core`, or `:sdk`.
- Text completion through `ASM.query/3`.
- Streaming through `ASM.stream/3` when a session is available.
- Session close through `ASM.stop_session/1`.
- Response normalization into `GEPA.LLM.Response`.
- Test injection seam through `:asm_module`.

Structured output fails closed for ASM until a real structured-output contract exists in the local agent stack.

## Basic Adapter Integration

`GEPA.Adapters.Basic` now honors configured LLM clients:

```elixir
llm = GEPA.LLM.req_llm(:openai)
adapter = GEPA.Adapters.Basic.new(llm: llm)
```

For backward compatibility, the default remains the legacy `GEPA.LLM.Mock` module path. Passing `:llm` or `:llm_client` can use any facade-compatible client or legacy module.

## Structured Instruction Extraction

`GEPA.Proposer.InstructionProposal` supports both paths:

- `structured_output: true` uses `GEPA.LLM.complete_structured/3`.
- The default text path extracts the outer fenced code block, matching the official Python implementation more closely than the previous first-regex-block behavior.

## Testing Strategy

The facade is tested without provider credentials by injecting fake ReqLLM and ASM modules. This keeps the TDD loop deterministic while proving that GEPA routes through the adapter boundary.

Relevant examples:

- `examples/01_quick_start.exs`: no-key deterministic mock path.
- `examples/05_llm_adapters.exs`: no-key facade demonstration followed by one explicit live hosted-provider call using CLI args.

## Quality Gates

Required local gates:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix docs
```

Additional architectural checks:

```bash
# Direct Anthropic HTTP/client references should not appear outside historical docs.
# Provider library names should not appear in optimizer/proposer/strategy code.
```

Both greps should return no matches. Provider-specific code belongs under `lib/gepa/llm/adapters/`.
