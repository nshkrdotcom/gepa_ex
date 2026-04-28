defmodule GEPA.Examples.LiveCLITest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.LLM.Adapters

  Code.require_file("../../../examples/support/live_cli.exs", __DIR__)

  @example [
    name: "Example Test",
    script: "examples/test.exs",
    summary: "Test help output.",
    required: [:train_jsonl, :val_jsonl]
  ]

  @prompt_example [
    name: "Prompt Example Test",
    script: "examples/prompt_test.exs",
    summary: "Test prompt help output.",
    required: [:input]
  ]

  describe "parse/2 help and validation" do
    test "prints help for --help without building a client" do
      assert {:help, help} = LiveCLI.parse(["--help"], no_env(@example))
      assert help =~ "Usage:"
      assert help =~ "Sensible Defaults"
      assert help =~ "--simple"
      assert help =~ "Default Models:"
      assert help =~ "gpt-5.4-mini"
      assert help =~ "gemini-3.1-flash-lite-preview"
      assert help =~ "--adapter asm --provider codex          -> gpt-5.4-mini"
      assert help =~ "GEMINI_API_KEY"
      assert help =~ "--adapter asm --provider codex"
    end

    test "accepts the Mix argv separator before --help" do
      assert {:help, help} = LiveCLI.parse(["--", "--help"], no_env(@example))
      assert help =~ "Usage:"
    end

    test "rejects missing defaults with useful help" do
      assert {:error, message} = LiveCLI.parse([], no_env(@example))
      assert message =~ "could not infer a default provider"
      assert message =~ "Usage:"
      assert message =~ "Sensible Defaults"
    end

    test "rejects missing ReqLLM key when no explicit key or default env key is available" do
      assert {:error, message} =
               LiveCLI.parse(
                 ["--adapter", "req_llm", "--provider", "gemini", "--input", "hello"],
                 no_env(@prompt_example)
               )

      assert message =~ "missing API key for req_llm/gemini"
      assert message =~ "GEMINI_API_KEY or GOOGLE_API_KEY"
    end

    test "rejects missing provider even when req_llm adapter is explicit and no key-backed default exists" do
      assert {:error, message} =
               LiveCLI.parse(["--adapter", "req_llm"], no_env(@prompt_example))

      assert message =~ "could not infer a default provider"
      assert message =~ "Usage:"
    end
  end

  describe "parse/2 client construction" do
    test "builds a ReqLLM client from explicit args" do
      train = jsonl_fixture([%{input: "real question", answer: "real answer"}])
      val = jsonl_fixture([%{input: "real validation", answer: "real answer"}])

      assert {:ok, config} =
               LiveCLI.parse(
                 [
                   "--adapter",
                   "req_llm",
                   "--provider",
                   "openai",
                   "--api-key",
                   "explicit-key",
                   "--train-jsonl",
                   train,
                   "--val-jsonl",
                   val
                 ],
                 no_env(@example)
               )

      assert config.adapter == :req_llm
      assert config.provider == :openai
      assert config.client.adapter == Adapters.ReqLLM
      assert config.client.model == "gpt-5.4-mini"
      assert config.trainset == [%{input: "real question", answer: "real answer"}]
      assert config.valset == [%{input: "real validation", answer: "real answer"}]
    end

    test "builds an ASM client from explicit args" do
      train = jsonl_fixture([%{input: "real question", answer: "real answer"}])
      val = jsonl_fixture([%{input: "real validation", answer: "real answer"}])

      assert {:ok, config} =
               LiveCLI.parse(
                 [
                   "--adapter",
                   "asm",
                   "--provider",
                   "codex",
                   "--lane",
                   "core",
                   "--session",
                   "gepa-test",
                   "--model",
                   "codex-model",
                   "--train-jsonl",
                   train,
                   "--val-jsonl",
                   val
                 ],
                 no_env(@example)
               )

      assert config.adapter == :asm
      assert config.provider == :codex
      assert config.client.adapter == Adapters.AgentSessionManager
      assert config.client.model == "codex-model"
      assert config.lane == :core
      assert config.session == "gepa-test"
    end

    test "supports inline prompt and expected output as user-provided data" do
      assert {:ok, config} =
               LiveCLI.parse(
                 [
                   "--adapter",
                   "asm",
                   "--provider",
                   "codex",
                   "--input",
                   "Summarize this real repo",
                   "--expected",
                   "summary"
                 ],
                 no_env(Keyword.put(@example, :required, [:input, :expected]))
               )

      assert config.input == "Summarize this real repo"
      assert config.expected == "summary"
    end

    test "simple mode defaults to ReqLLM Gemini from GEMINI_API_KEY" do
      assert {:ok, config} =
               LiveCLI.parse(["--simple"], with_env(@prompt_example, %{"GEMINI_API_KEY" => "g"}))

      assert config.simple?
      assert config.adapter == :req_llm
      assert config.provider == :gemini
      assert config.input =~ "Reply with exactly"
      assert config.client.adapter == Adapters.ReqLLM
      assert config.client.provider == :gemini
      assert config.client.adapter_state.api_key == "g"
    end

    test "simple mode defaults to ReqLLM Gemini from GOOGLE_API_KEY when GEMINI_API_KEY is absent" do
      assert {:ok, config} =
               LiveCLI.parse(["--simple"], with_env(@prompt_example, %{"GOOGLE_API_KEY" => "g"}))

      assert config.adapter == :req_llm
      assert config.provider == :gemini
      assert config.client.adapter_state.api_key == "g"
    end

    test "simple mode falls back to OpenAI when Gemini keys are absent" do
      assert {:ok, config} =
               LiveCLI.parse(["--simple"], with_env(@prompt_example, %{"OPENAI_API_KEY" => "o"}))

      assert config.adapter == :req_llm
      assert config.provider == :openai
      assert config.client.adapter_state.api_key == "o"
    end

    test "explicit CLI API key overrides default env key" do
      assert {:ok, config} =
               LiveCLI.parse(
                 [
                   "--simple",
                   "--provider",
                   "gemini",
                   "--api-key",
                   "explicit"
                 ],
                 with_env(@prompt_example, %{"GEMINI_API_KEY" => "env"})
               )

      assert config.provider == :gemini
      assert config.client.adapter_state.api_key == "explicit"
    end

    test "explicit ASM provider infers ASM adapter" do
      assert {:ok, config} =
               LiveCLI.parse(
                 ["--provider", "codex", "--input", "Summarize this real repo"],
                 no_env(@prompt_example)
               )

      assert config.adapter == :asm
      assert config.provider == :codex
      assert config.model == "gpt-5.4-mini"
      assert config.client.model == "gpt-5.4-mini"
    end

    test "simple mode supplies built-in live demo data for optimization examples" do
      assert {:ok, config} =
               LiveCLI.parse(["--simple"], with_env(@example, %{"GEMINI_API_KEY" => "g"}))

      assert config.simple?
      assert [%{input: _, answer: _} | _] = config.trainset
      assert [%{input: _, answer: _} | _] = config.valset
      assert config.max_metric_calls == 2
      assert config.minibatch_size == 1
    end

    test "simple mode supplies ARC grid fixtures for the ARC example" do
      example = Keyword.put(@example, :script, "examples/14_arc_grid.exs")

      assert {:ok, config} =
               LiveCLI.parse(["--simple"], with_env(example, %{"GEMINI_API_KEY" => "g"}))

      assert [%{input: input, answer: answer} | _] = config.trainset
      assert input =~ "ARC"
      assert input =~ "[["
      assert answer =~ "[["
    end

    test "simple ASM Codex uses gpt-5.4-mini without --model" do
      assert {:ok, config} =
               LiveCLI.parse(
                 ["--simple", "--adapter", "asm", "--provider", "codex"],
                 no_env(@prompt_example)
               )

      assert config.adapter == :asm
      assert config.provider == :codex
      assert config.model == "gpt-5.4-mini"
      assert config.client.model == "gpt-5.4-mini"
    end
  end

  describe "messages" do
    test "cost warning names the example and adapter" do
      warning = LiveCLI.cost_warning("Example Test", :asm, :codex, 7)
      assert warning =~ "LIVE LLM CALL WARNING"
      assert warning =~ "Example Test"
      assert warning =~ "asm/codex"
      assert warning =~ "up to 7"
    end
  end

  defp jsonl_fixture(rows) do
    path =
      Path.join(System.tmp_dir!(), "gepa-live-cli-#{System.unique_integer([:positive])}.jsonl")

    content =
      rows
      |> Enum.map_join("\n", &Jason.encode!/1)

    File.write!(path, content <> "\n")
    path
  end

  defp no_env(example), do: with_env(example, %{})

  defp with_env(example, env) do
    example
    |> Keyword.put(:env, fn key -> Map.get(env, key) end)
    |> Keyword.put(:app_config, fn _key -> nil end)
  end
end
