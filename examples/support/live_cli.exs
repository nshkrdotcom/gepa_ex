defmodule LiveCLI do
  @moduledoc false

  @req_llm_providers [:openai, :gemini, :anthropic]
  @asm_providers [:codex, :codex_exec, :claude, :gemini, :amp]
  @strict [
    help: :boolean,
    simple: :boolean,
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

  @req_llm_env_vars %{
    gemini: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
    openai: ["OPENAI_API_KEY"],
    anthropic: ["ANTHROPIC_API_KEY"]
  }

  @req_llm_config_keys %{
    gemini: [:gemini_api_key, :google_api_key],
    openai: [:openai_api_key],
    anthropic: [:anthropic_api_key]
  }

  def parse(argv, example) when is_list(argv) and is_list(example) do
    argv = normalize_argv(argv)

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

    Sensible Defaults:
      If --adapter/--provider are omitted, examples default to ReqLLM using the
      first configured hosted provider in this order: Gemini, OpenAI, Anthropic.
      Gemini accepts GEMINI_API_KEY first, then GOOGLE_API_KEY. Explicit CLI
      options always override defaults.

    Usage:
      mix run #{script} -- --simple
      mix run #{script} -- --provider gemini#{required_options}
      mix run #{script} -- --adapter req_llm --provider openai --api-key sk-...#{required_options}
      mix run #{script} -- --adapter req_llm --provider gemini --api-key ...#{required_options}
      mix run #{script} -- --adapter req_llm --provider anthropic --api-key ...#{required_options}
      mix run #{script} -- --adapter asm --provider codex --lane core --session gepa_example#{required_options}

    Provider Options:
      --simple                   Use defaults and built-in demo input/data where needed
      --adapter req_llm|asm      Optional when defaults can infer it
      --provider openai|gemini|anthropic for ReqLLM
      --provider codex|codex_exec|claude|gemini|amp for ASM
      --api-key VALUE            Optional override; otherwise env/config defaults are used

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
      --session VALUE            Optional ASM session id for named managed runs

    Default API Keys:
      Gemini                     GEMINI_API_KEY, then GOOGLE_API_KEY
      OpenAI                     OPENAI_API_KEY
      Anthropic                  ANTHROPIC_API_KEY

    Default Models:
      --adapter req_llm --provider openai     -> gpt-5.4-mini
      --adapter req_llm --provider gemini     -> gemini-3.1-flash-lite-preview
      --adapter req_llm --provider anthropic  -> claude-haiku-4-5
      --adapter asm --provider codex          -> ASM/Codex default unless --model is provided
      --adapter asm --provider claude         -> ASM/Claude default unless --model is provided
      --adapter asm --provider gemini         -> ASM/Gemini default unless --model is provided
      --adapter asm --provider amp            -> ASM/Amp default unless --model is provided
    """
  end

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

  defp normalize_argv(["--" | argv]), do: argv
  defp normalize_argv(argv), do: argv

  defp build_config(opts, example) do
    env = env_lookup(example)
    app_config = app_config_lookup(example)

    with {:ok, opts} <- apply_provider_defaults(opts, env, app_config),
         {:ok, adapter} <- parse_adapter(opts),
         {:ok, provider} <- parse_provider(opts, adapter),
         {:ok, lane} <- parse_lane(opts),
         api_key = req_llm_api_key(opts, provider, env, app_config),
         :ok <- validate_req_llm_key(adapter, provider, api_key),
         {:ok, data} <- load_data(opts, example),
         :ok <- validate_required(data, Keyword.get(example, :required, [])),
         {:ok, client} <- build_client(opts, adapter, provider, lane, api_key) do
      simple? = Keyword.get(opts, :simple, false)

      {:ok,
       Map.merge(data, %{
         adapter: adapter,
         provider: provider,
         client: client,
         lane: lane,
         simple?: simple?,
         session: Keyword.get(opts, :session),
         model: Keyword.get(opts, :model),
         temperature: Keyword.get(opts, :temperature),
         max_tokens: Keyword.get(opts, :max_tokens),
         timeout: Keyword.get(opts, :timeout),
         top_p: Keyword.get(opts, :top_p),
         stream?: Keyword.get(opts, :stream, false),
         structured_output?: Keyword.get(opts, :structured_output, false),
         max_metric_calls: Keyword.get(opts, :max_metric_calls, if(simple?, do: 2, else: 8)),
         minibatch_size: Keyword.get(opts, :minibatch_size, if(simple?, do: 1, else: 2))
       })}
    else
      {:error, errors} when is_list(errors) -> {:error, error_message(errors, example)}
      {:error, error} -> {:error, error_message([to_string(error)], example)}
    end
  end

  defp apply_provider_defaults(opts, env, app_config) do
    adapter = Keyword.get(opts, :adapter)
    provider = Keyword.get(opts, :provider)

    cond do
      present?(adapter) and present?(provider) ->
        {:ok, opts}

      present?(adapter) ->
        apply_provider_default_for_adapter(opts, adapter, env, app_config)

      present?(provider) ->
        apply_adapter_default_for_provider(opts, provider)

      true ->
        case default_req_llm_provider(env, app_config) do
          {:ok, provider_atom} ->
            {:ok,
             opts
             |> Keyword.put(:adapter, "req_llm")
             |> Keyword.put(:provider, Atom.to_string(provider_atom))}

          {:error, _} = error ->
            error
        end
    end
  end

  defp apply_provider_default_for_adapter(opts, "req_llm", env, app_config) do
    case default_req_llm_provider(env, app_config) do
      {:ok, provider_atom} -> {:ok, Keyword.put(opts, :provider, Atom.to_string(provider_atom))}
      {:error, _} = error -> error
    end
  end

  defp apply_provider_default_for_adapter(opts, "asm", _env, _app_config) do
    {:ok, Keyword.put(opts, :provider, "codex")}
  end

  defp apply_provider_default_for_adapter(_opts, adapter, _env, _app_config) do
    {:error, ["invalid --adapter #{inspect(adapter)}; expected req_llm or asm"]}
  end

  defp apply_adapter_default_for_provider(opts, provider) do
    cond do
      provider in provider_names(@req_llm_providers) ->
        {:ok, Keyword.put(opts, :adapter, "req_llm")}

      provider in provider_names(@asm_providers) ->
        {:ok, Keyword.put(opts, :adapter, "asm")}

      true ->
        {:error, ["invalid --provider #{inspect(provider)}; cannot infer adapter"]}
    end
  end

  defp default_req_llm_provider(env, app_config) do
    Enum.find_value([:gemini, :openai, :anthropic], fn provider ->
      if req_llm_api_key([], provider, env, app_config), do: {:ok, provider}
    end) ||
      {:error,
       [
         "could not infer a default provider; set GEMINI_API_KEY, GOOGLE_API_KEY, OPENAI_API_KEY, or ANTHROPIC_API_KEY, or pass --adapter/--provider"
       ]}
  end

  defp req_llm_api_key(opts, provider, env, app_config) when provider in @req_llm_providers do
    Keyword.get(opts, :api_key) ||
      app_config_api_key(provider, app_config) ||
      env_api_key(provider, env)
  end

  defp req_llm_api_key(_opts, _provider, _env, _app_config), do: nil

  defp app_config_api_key(provider, app_config) do
    @req_llm_config_keys
    |> Map.fetch!(provider)
    |> Enum.find_value(fn key -> present_value(app_config.(key)) end)
  end

  defp env_api_key(provider, env) do
    @req_llm_env_vars
    |> Map.fetch!(provider)
    |> Enum.find_value(fn key -> present_value(env.(key)) end)
  end

  defp validate_req_llm_key(:req_llm, provider, nil) do
    env_vars = @req_llm_env_vars |> Map.get(provider, []) |> Enum.join(" or ")

    {:error,
     [
       "missing API key for req_llm/#{provider}; pass --api-key or set #{env_vars}"
     ]}
  end

  defp validate_req_llm_key(:req_llm, _provider, _api_key), do: :ok
  defp validate_req_llm_key(:asm, _provider, _api_key), do: :ok

  defp validate_required(data, required) do
    missing =
      required
      |> Enum.reject(&required_present?(data, &1))
      |> Enum.map(&"missing required --#{option_name(&1)}")

    if missing == [], do: :ok, else: {:error, missing}
  end

  defp required_present?(data, :train_jsonl), do: present_collection?(data.trainset)
  defp required_present?(data, :val_jsonl), do: present_collection?(data.valset)
  defp required_present?(data, key), do: present?(Map.get(data, key))

  defp present_collection?(value), do: is_list(value) and value != []

  defp load_data(opts, example) do
    simple? = Keyword.get(opts, :simple, false)

    with {:ok, trainset} <- maybe_load_jsonl_or_simple(opts[:train_jsonl], simple?, example, :train),
         {:ok, valset} <- maybe_load_jsonl_or_simple(opts[:val_jsonl], simple?, example, :val) do
      {:ok,
       %{
         trainset: trainset,
         valset: valset,
         input: Keyword.get(opts, :input) || simple_input(simple?, example),
         expected: Keyword.get(opts, :expected) || simple_expected(simple?, example),
         run_dir: Keyword.get(opts, :run_dir) || simple_run_dir(simple?, example)
       }}
    end
  end

  defp maybe_load_jsonl_or_simple(path, _simple?, _example, _split)
       when is_binary(path) and path != "" do
    maybe_load_jsonl(path)
  end

  defp maybe_load_jsonl_or_simple(_path, true, example, split) do
    {:ok, simple_dataset(example, split)}
  end

  defp maybe_load_jsonl_or_simple(_path, _simple?, _example, _split), do: {:ok, nil}

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

  defp simple_dataset(example, split) do
    case Keyword.fetch!(example, :script) do
      "examples/03_custom_adapter.exs" -> simple_sentiment_dataset(split)
      "examples/02_math_problems.exs" -> simple_math_dataset(split)
      _script -> simple_qa_dataset(split)
    end
  end

  defp simple_qa_dataset(:train) do
    [
      %{input: "What does GEPA optimize?", answer: "instructions"},
      %{input: "Answer with the word ready.", answer: "ready"}
    ]
  end

  defp simple_qa_dataset(:val), do: [%{input: "Answer with the word done.", answer: "done"}]

  defp simple_math_dataset(:train) do
    [
      %{input: "What is 12 + 7?", answer: "19"},
      %{input: "What is 9 * 6?", answer: "54"}
    ]
  end

  defp simple_math_dataset(:val), do: [%{input: "What is 15 - 4?", answer: "11"}]

  defp simple_sentiment_dataset(:train) do
    [
      %{text: "The release went smoothly and the team is happy.", sentiment: "positive"},
      %{text: "The deployment failed and users are frustrated.", sentiment: "negative"}
    ]
  end

  defp simple_sentiment_dataset(:val) do
    [%{text: "The interface is acceptable but not exciting.", sentiment: "neutral"}]
  end

  defp simple_input(true, _example), do: "Reply with exactly: gepa simple ok"
  defp simple_input(_simple?, _example), do: nil

  defp simple_expected(true, _example), do: "gepa simple ok"
  defp simple_expected(_simple?, _example), do: nil

  defp simple_run_dir(true, example) do
    script =
      example
      |> Keyword.fetch!(:script)
      |> Path.basename(".exs")

    Path.join(System.tmp_dir!(), "gepa_ex_#{script}_simple")
  end

  defp simple_run_dir(_simple?, _example), do: nil

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

  defp build_client(opts, :req_llm, provider, _lane, api_key) do
    client_opts =
      [
        api_key: api_key,
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

  defp build_client(opts, :asm, provider, lane, _api_key) do
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

  defp normalize_json_map(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      normalized_key = Map.get(@json_key_map, key, key)
      {normalized_key, value}
    end
  end

  defp env_lookup(example), do: Keyword.get(example, :env, &System.get_env/1)
  defp app_config_lookup(example), do: Keyword.get(example, :app_config, &Application.get_env(:req_llm, &1))
  defp provider_names(providers), do: Enum.map(providers, &Atom.to_string/1)
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

  defp present_value(value), do: if(present?(value), do: value)
  defp option_name(option), do: option |> Atom.to_string() |> String.replace("_", "-")
  defp present?(value), do: is_binary(value) and value != ""
end
