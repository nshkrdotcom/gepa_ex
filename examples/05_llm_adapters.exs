#!/usr/bin/env elixir

example = [
  name: "GEPA LLM Adapter Live Smoke Example",
  script: "examples/05_llm_adapters.exs",
  summary: "Makes one real completion call through either ReqLLM or Agent Session Manager.",
  required: [:input]
]

config = GEPA.Examples.LiveCLI.parse_or_halt(System.argv(), example)
call_count = if config.stream?, do: 1, else: 1

IO.puts(
  GEPA.Examples.LiveCLI.cost_warning(example[:name], config.adapter, config.provider, call_count)
)

IO.puts("""
GEPA LLM Adapter Live Smoke Example
===================================

Adapter/provider: #{config.adapter}/#{config.provider}
Model: #{config.model || "(provider default)"}
Input: #{config.input}
Streaming: #{config.stream?}
Structured output: #{config.structured_output?}
""")

cond do
  config.stream? ->
    {:ok, stream} =
      GEPA.LLM.stream(config.client, config.input, GEPA.Examples.LiveCLI.generation_opts(config))

    IO.puts("Stream response:")
    Enum.each(stream, &IO.write(to_string(&1)))
    IO.puts("")

  config.structured_output? ->
    case GEPA.LLM.complete_structured(
           config.client,
           config.input,
           GEPA.Examples.LiveCLI.generation_opts(config)
         ) do
      {:ok, object} ->
        IO.puts("Structured response:")
        IO.puts(Jason.encode!(object, pretty: true))

      {:error, reason} ->
        raise "structured output failed for #{config.adapter}/#{config.provider}: #{inspect(reason)}"
    end

  true ->
    {:ok, response} =
      GEPA.LLM.complete(
        config.client,
        config.input,
        GEPA.Examples.LiveCLI.generation_opts(config)
      )

    IO.puts("Response:")
    IO.puts(response)
end
