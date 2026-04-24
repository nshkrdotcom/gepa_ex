defmodule GEPA.Examples.LiveCLITest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Examples.LiveCLI
  alias GEPA.LLM.Adapters

  @example [
    name: "Example Test",
    script: "examples/test.exs",
    summary: "Test help output.",
    required: [:train_jsonl, :val_jsonl]
  ]

  describe "parse/2 help and validation" do
    test "prints help for --help without building a client" do
      assert {:help, help} = LiveCLI.parse(["--help"], @example)
      assert help =~ "Usage:"
      assert help =~ "No Default Provider Or Adapter"
      assert help =~ "Default Models:"
      assert help =~ "gpt-5.4-mini"
      assert help =~ "gemini-flash-lite-latest"
      assert help =~ "--adapter asm --provider codex"
    end

    test "rejects missing adapter and provider with useful help" do
      assert {:error, message} = LiveCLI.parse([], @example)
      assert message =~ "missing required --adapter"
      assert message =~ "missing required --provider"
      assert message =~ "Usage:"
      assert message =~ "No Default Provider Or Adapter"
    end

    test "rejects missing provider even when adapter is present" do
      assert {:error, message} = LiveCLI.parse(["--adapter", "req_llm"], @example)
      assert message =~ "missing required --provider"
      assert message =~ "Usage:"
    end

    test "rejects missing ReqLLM API key" do
      assert {:error, message} =
               LiveCLI.parse(["--adapter", "req_llm", "--provider", "openai"], @example)

      assert message =~ "missing required --api-key"
      assert message =~ "--adapter req_llm --provider openai"
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
                 @example
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
                 @example
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
                 Keyword.put(@example, :required, [:input, :expected])
               )

      assert config.input == "Summarize this real repo"
      assert config.expected == "summary"
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
    path = Path.join(System.tmp_dir!(), "gepa-live-cli-#{System.unique_integer([:positive])}.jsonl")

    content =
      rows
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    File.write!(path, content <> "\n")
    path
  end
end
