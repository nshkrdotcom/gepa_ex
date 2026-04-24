defmodule GEPA.Examples.LiveCLI do
  @moduledoc false

  @req_llm_providers [:openai, :gemini, :anthropic]
  @asm_providers [:codex, :codex_exec, :claude, :gemini, :amp]
  @strict [
    help: :boolean,
    adapter: :string,
    provider: :string,
    api_key: :string,
    model: :string,
    lane: :string,
    session: :string,
    train_jsonl: :string,
    val_jsonl: :string,
    input: :string,
    expected: :string,
    run_dir: :string,
    max_metric_calls: :integer,
    minibatch_size: :integer,
    temperature: :float,
    max_tokens: :integer,
    timeout: :integer,
    top_p: :float,
    stream: :boolean,
    structured_output: :boolean
  ]

  @json_key_map %{
    "answer" => :answer,
    "expected" => :expected,
    "input" => :input,
    "sentiment" => :sentiment,
    "text" => :text
  }

  @type parse_result :: {:ok, map()} | {:help, String.t()} | {:error, String.t()}

  @spec parse([String.t()], keyword()) :: parse_result()
  def parse(argv, example) when is_list(argv) and is_list(example) do
    case OptionParser.parse(argv, strict: @strict) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          {:help, help(example)}
        else
          build_config(opts, example)
        end

      {_opts, extra_args, invalid} ->
        errors =
          Enum.map(invalid, fn {arg, _value} -> "invalid option #{arg}" end) ++
            Enum.map(extra_args, &"unexpected argument #{inspect(&1)}")

        {:error, error_message(errors, example)}
    end
  end

  @spec parse_or_halt([String.t()], keyword()) :: map()
  def parse_or_halt(argv, example) do
    case parse(argv, example) do
      {:ok, config} ->
        config

      {:help, help} ->
        IO.puts(help)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(64)
    end
  end

  @spec help(keyword()) :: String.t()
  def help(example) do
    script = Keyword.fetch!(example, :script)
    name = Keyword.fetch!(example, :name)
    summary = Keyword.get(example, :summary, "")
    required = Keyword.get(example, :required, [])
    required_options = required_options(required)

    """
    #{name}
    #{String.duplicate("=", String.length(name))}

    #{summary}

    LIVE LLM CALL WARNING:
      This example makes real calls to the selected provider. Those calls may incur
      provider costs and may execute through local CLI agents when ASM is selected.

    No Default Provider Or Adapter:
      There is intentionally no default --adapter and no default --provider.
      You must choose both so live paid/provider-backed execution is explicit.

    Usage:
      mix run #{script} -- --adapter req_llm --provider openai --api-key sk-...#{required_options}
      mix run #{script} -- --adapter req_llm --provider gemini --api-key ...#{required_options}
      mix run #{script} -- --adapter req_llm --provider anthropic --api-key ...#{required_options}
      mix run #{script} -- --adapter asm --provider codex --lane core --session gepa_example#{required_options}

    Required Provider Options:
      --adapter req_llm|asm
      --provider openai|gemini|anthropic for ReqLLM
      --provider codex|codex_exec|claude|gemini|amp for ASM
      --api-key VALUE is required only for --adapter req_llm

    Common Options:
      --model VALUE              Override the provider-keyed default model
      --temperature FLOAT        Generation temperature
      --max-tokens INTEGER       Max completion tokens
      --timeout INTEGER          Request timeout in milliseconds
      --top-p FLOAT              Nucleus sampling value
      --max-metric-calls INTEGER Optimization/evaluation call budget
      --minibatch-size INTEGER   Reflection minibatch size
      --structured-output        Use structured instruction proposal when supported

    Data/Input Options:
      --train-jsonl PATH         JSONL training data for optimization examples
      --val-jsonl PATH           JSONL validation data for optimization examples
      --input TEXT               User-provided live input for single-call examples
      --expected TEXT            User-provided expected text/label where required
      --run-dir PATH             State persistence directory where required

    ASM Options:
      --lane auto|core|sdk       ASM lane, defaults to auto when omitted
      --session VALUE            ASM session identifier when session/streaming is needed

    Default Models:
      --adapter req_llm --provider openai     -> gpt-5.4-mini
      --adapter req_llm --provider gemini     -> gemini-flash-lite-latest
      --adapter req_llm --provider anthropic  -> claude-haiku-4-5
      --adapter asm --provider codex          -> ASM/Codex default unless --model is provided
      --adapter asm --provider claude         -> ASM/Claude default unless --model is provided
      --adapter asm --provider gemini         -> ASM/Gemini default unless --model is provided
      --adapter asm --provider amp            -> ASM/Amp default unless --model is provided
    """
  end

  @spec cost_warning(String.t(), atom(), atom(), pos_integer()) :: String.t()
  def cost_warning(example_name, adapter, provider, max_calls) do
    """
    LIVE LLM CALL WARNING
    =====================

    Example: #{example_name}
    Adapter/provider: #{adapter}/#{provider}
    Expected live calls: up to #{max_calls}

    This run uses the real configured provider. It may incur provider costs and,
    for ASM providers, may use local CLI agent sessions. Stop now if that is not
    what you intend.
    """
  end

  @spec generation_opts(map()) :: keyword()
  def generation_opts(config) when is_map(config) do
    [
      model: Map.get(config, :model),
      temperature: Map.get(config, :temperature),
      max_tokens: Map.get(config, :max_tokens),
      timeout: Map.get(config, :timeout),
      top_p: Map.get(config, :top_p)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp build_config(opts, example) do
    with :ok <- validate_adapter_provider_presence(opts),
         {:ok, adapter} <- parse_adapter(opts),
         {:ok, provider} <- parse_provider(opts, adapter),
         {:ok, lane} <- parse_lane(opts),
         :ok <- validate_req_llm_key(opts, adapter),
         :ok <- validate_required(opts, Keyword.get(example, :required, [])),
         {:ok, data} <- load_data(opts),
         {:ok, client} <- build_client(opts, adapter, provider, lane) do
      {:ok,
       data
       |> Map.merge(%{
         adapter: adapter,
         provider: provider,
         client: client,
         lane: lane,
         session: Keyword.get(opts, :session),
         model: Keyword.get(opts, :model),
         temperature: Keyword.get(opts, :temperature),
         max_tokens: Keyword.get(opts, :max_tokens),
         timeout: Keyword.get(opts, :timeout),
         top_p: Keyword.get(opts, :top_p),
         stream?: Keyword.get(opts, :stream, false),
         structured_output?: Keyword.get(opts, :structured_output, false),
         max_metric_calls: Keyword.get(opts, :max_metric_calls, 8),
         minibatch_size: Keyword.get(opts, :minibatch_size, 2)
       })}
    else
      {:error, errors} when is_list(errors) -> {:error, error_message(errors, example)}
      {:error, error} -> {:error, error_message([to_string(error)], example)}
    end
  end

  defp validate_adapter_provider_presence(opts) do
    errors =
      []
      |> maybe_missing(opts, :adapter)
      |> maybe_missing(opts, :provider)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp maybe_missing(errors, opts, key) do
    if present?(Keyword.get(opts, key)) do
      errors
    else
      ["missing required --#{option_name(key)}" | errors]
    end
  end

  defp parse_adapter(opts) do
    case Keyword.get(opts, :adapter) do
      nil -> {:error, ["missing required --adapter"]}
      "req_llm" -> {:ok, :req_llm}
      "asm" -> {:ok, :asm}
      adapter -> {:error, ["invalid --adapter #{inspect(adapter)}; expected req_llm or asm"]}
    end
  end

  defp parse_provider(opts, adapter) do
    case Keyword.get(opts, :provider) do
      nil ->
        {:error, ["missing required --provider"]}

      provider ->
        valid_providers = providers_for(adapter)

        case Enum.find(valid_providers, &(Atom.to_string(&1) == provider)) do
          nil ->
            {:error,
             [
               "invalid --provider #{inspect(provider)} for --adapter #{adapter}; expected one of #{Enum.join(valid_providers, ", ")}"
             ]}

          provider_atom ->
            {:ok, provider_atom}
        end
    end
  end

  defp parse_lane(opts) do
    case Keyword.get(opts, :lane, "auto") do
      "auto" -> {:ok, :auto}
      "core" -> {:ok, :core}
      "sdk" -> {:ok, :sdk}
      lane -> {:error, ["invalid --lane #{inspect(lane)}; expected auto, core, or sdk"]}
    end
  end

  defp validate_req_llm_key(opts, :req_llm) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> :ok
      _ -> {:error, ["missing required --api-key for --adapter req_llm"]}
    end
  end

  defp validate_req_llm_key(_opts, :asm), do: :ok

  defp validate_required(opts, required) do
    missing =
      required
      |> Enum.reject(&present?(Keyword.get(opts, &1)))
      |> Enum.map(&"missing required --#{option_name(&1)}")

    if missing == [], do: :ok, else: {:error, missing}
  end

  defp load_data(opts) do
    with {:ok, trainset} <- maybe_load_jsonl(opts[:train_jsonl]),
         {:ok, valset} <- maybe_load_jsonl(opts[:val_jsonl]) do
      {:ok,
       %{
         trainset: trainset,
         valset: valset,
         input: Keyword.get(opts, :input),
         expected: Keyword.get(opts, :expected),
         run_dir: Keyword.get(opts, :run_dir)
       }}
    end
  end

  defp maybe_load_jsonl(nil), do: {:ok, nil}

  defp maybe_load_jsonl(path) do
    rows =
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        line
        |> Jason.decode!()
        |> normalize_json_map()
      end)

    {:ok, rows}
  rescue
    error -> {:error, "failed to load JSONL #{inspect(path)}: #{Exception.message(error)}"}
  end

  defp normalize_json_map(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      normalized_key = Map.get(@json_key_map, key, key)
      {normalized_key, value}
    end
  end

  defp build_client(opts, :req_llm, provider, _lane) do
    client_opts =
      [
        api_key: Keyword.get(opts, :api_key),
        model: Keyword.get(opts, :model),
        temperature: Keyword.get(opts, :temperature),
        max_tokens: Keyword.get(opts, :max_tokens),
        timeout: Keyword.get(opts, :timeout),
        top_p: Keyword.get(opts, :top_p)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    {:ok, GEPA.LLM.req_llm(provider, client_opts)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp build_client(opts, :asm, provider, lane) do
    provider_opts =
      [
        model: Keyword.get(opts, :model),
        temperature: Keyword.get(opts, :temperature),
        max_tokens: Keyword.get(opts, :max_tokens),
        timeout: Keyword.get(opts, :timeout),
        top_p: Keyword.get(opts, :top_p)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    client_opts = [
      lane: lane,
      session: Keyword.get(opts, :session),
      provider_opts: provider_opts
    ]

    {:ok, GEPA.LLM.agent(provider, client_opts)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp providers_for(:req_llm), do: @req_llm_providers
  defp providers_for(:asm), do: @asm_providers

  defp required_options([]), do: ""

  defp required_options(required) do
    Enum.map_join(required, "", &" --#{option_name(&1)} ...")
  end

  defp error_message(errors, example) do
    """
    Error:
      #{Enum.join(errors, "\n  ")}

    #{help(example)}
    """
  end

  defp option_name(option), do: option |> Atom.to_string() |> String.replace("_", "-")

  defp present?(value), do: is_binary(value) and value != ""
end
