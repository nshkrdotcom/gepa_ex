defmodule GEPA.Embeddings.ReqLLMTest do
  use ExUnit.Case, async: true

  alias GEPA.Embeddings
  alias GEPA.Embeddings.ReqLLM, as: ReqLLMEmbeddings

  defmodule FakeReqLLM do
    def put_key(key, value) do
      send(self(), {:put_key, key, value})
      :ok
    end

    def embed(model_spec, input, opts) do
      send(self(), {:embed, model_spec, input, opts})

      case input do
        text when is_binary(text) ->
          {:ok, vector_for(text)}

        texts when is_list(texts) ->
          {:ok, Enum.map(texts, &vector_for/1)}
      end
    end

    defp vector_for(text) do
      base = String.length(to_string(text)) * 1.0
      [base, base + 1.0, base + 2.0]
    end
  end

  test "ReqLLM-backed provider embeds one text through the behavior facade" do
    provider =
      ReqLLMEmbeddings.new!(
        api_key: "test-key",
        req_llm_module: FakeReqLLM,
        dimensions: 3
      )

    assert {:ok, [5.0, 6.0, 7.0]} = Embeddings.embed(provider, "hello")
    assert Embeddings.dimensions(provider) == 3
    assert Embeddings.model(provider) == "google:gemini-embedding-001"
    assert_received {:put_key, :google_api_key, "test-key"}
    assert_received {:embed, "google:gemini-embedding-001", "hello", opts}
    assert Keyword.get(opts, :dimensions) == 3
  end

  test "ReqLLM-backed provider embeds batches and accepts provider options" do
    provider =
      ReqLLMEmbeddings.new!(
        api_key: "test-key",
        provider_options: [task_type: "RETRIEVAL_DOCUMENT"],
        req_llm_module: FakeReqLLM
      )

    assert {:ok, [[5.0, 6.0, 7.0], [4.0, 5.0, 6.0]]} =
             Embeddings.embed_batch(provider, ["alpha", "beta"])

    assert_received {:embed, "google:gemini-embedding-001", ["alpha", "beta"], opts}
    assert Keyword.get(opts, :provider_options) == [task_type: "RETRIEVAL_DOCUMENT"]
  end

  test "ReqLLM-backed provider can read Gemini API keys from env callback" do
    provider =
      ReqLLMEmbeddings.new!(
        env: fn
          "GEMINI_API_KEY" -> "env-key"
          _name -> nil
        end,
        req_llm_module: FakeReqLLM
      )

    assert {:ok, _vector} = Embeddings.embed(provider, "hello")
    assert_received {:put_key, :google_api_key, "env-key"}
  end
end
