defmodule GEPA.LMTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  import ExUnit.CaptureLog

  alias GEPA.LLM.{Client, Response}

  defmodule CaptureAdapter do
    def complete(%Client{adapter_state: state}, request) do
      send(state.owner, {:lm_request, request})
      {:ok, state.response_fn.(request)}
    end
  end

  describe "new/2 upstream constructor parity" do
    test "defaults omit completion kwargs" do
      lm = GEPA.LM.new("openai/gpt-4.1")

      refute Keyword.has_key?(lm.completion_kwargs, :temperature)
      refute Keyword.has_key?(lm.completion_kwargs, :max_tokens)
    end

    test "custom params are stored as completion kwargs" do
      lm = GEPA.LM.new("openai/gpt-4.1", temperature: 0.5, max_tokens: 4096)

      assert lm.completion_kwargs[:temperature] == 0.5
      assert lm.completion_kwargs[:max_tokens] == 4096
    end

    test "extra kwargs are preserved for forwarding" do
      lm = GEPA.LM.new("openai/gpt-4.1", top_p: 0.9, stop: ["\n"])

      assert lm.completion_kwargs[:top_p] == 0.9
      assert lm.completion_kwargs[:stop] == ["\n"]
    end

    test "reasoning model params are not rewritten" do
      lm = GEPA.LM.new("openai/gpt-5-mini", temperature: 0.7, max_tokens: 4096)

      assert lm.completion_kwargs[:temperature] == 0.7
      assert lm.completion_kwargs[:max_tokens] == 4096
      refute Keyword.has_key?(lm.completion_kwargs, :max_completion_tokens)
    end
  end

  describe "complete/3 upstream call parity" do
    test "string prompt is forwarded with model and kwargs" do
      lm =
        "openai/gpt-4.1"
        |> GEPA.LM.new(
          client: client(fn _request -> %Response{text: "response text"} end),
          temperature: 0.5
        )

      assert {:ok, "response text"} = GEPA.LM.complete(lm, "hello")

      assert_received {:lm_request, request}
      assert request.input == "hello"
      assert request.model == "openai/gpt-4.1"
      assert request.temperature == 0.5
    end

    test "messages prompt is forwarded unchanged" do
      messages = [
        %{"role" => "system", "content" => "sys"},
        %{"role" => "user", "content" => "hi"}
      ]

      lm =
        GEPA.LM.new("openai/gpt-4.1",
          client: client(fn _request -> %Response{text: "chat response"} end)
        )

      assert {:ok, "chat response"} = GEPA.LM.complete(lm, messages)

      assert_received {:lm_request, request}
      assert request.input == messages
      assert request.messages == messages
    end

    test "logs warning when provider reports truncation" do
      lm =
        GEPA.LM.new("openai/gpt-4.1",
          client: client(fn _request -> %Response{text: "truncated", stop_reason: :length} end),
          max_tokens: 100
        )

      log =
        capture_log(fn ->
          assert {:ok, "truncated"} = GEPA.LM.complete(lm, "hello")
        end)

      assert log =~ "truncated"
    end
  end

  describe "batch_complete/3 upstream parity" do
    test "returns trimmed responses for each message batch" do
      lm =
        GEPA.LM.new("openai/gpt-4.1",
          client:
            client(fn request ->
              case hd(request.messages)["content"] do
                "q1" -> %Response{text: " answer1 "}
                "q2" -> %Response{text: " answer2 "}
              end
            end)
        )

      messages = [
        [%{"role" => "user", "content" => "q1"}],
        [%{"role" => "user", "content" => "q2"}]
      ]

      assert {:ok, ["answer1", "answer2"]} = GEPA.LM.batch_complete(lm, messages, max_workers: 5)

      assert_received {:lm_request, request_1}
      assert_received {:lm_request, request_2}
      assert request_1.provider_opts[:max_workers] == 5
      assert request_2.provider_opts[:max_workers] == 5
    end

    test "batch call forwards init and call kwargs" do
      lm =
        GEPA.LM.new("openai/gpt-4.1",
          client: client(fn _request -> %Response{text: "ans"} end),
          temperature: 0.5
        )

      assert {:ok, ["ans"]} =
               GEPA.LM.batch_complete(
                 lm,
                 [[%{"role" => "user", "content" => "q"}]],
                 max_workers: 3,
                 timeout: 30,
                 api_base: "https://custom.api"
               )

      assert_received {:lm_request, request}
      assert request.temperature == 0.5
      assert request.timeout == 30
      assert request.provider_opts[:max_workers] == 3
      assert request.provider_opts[:api_base] == "https://custom.api"
    end

    test "batch call kwargs override init kwargs" do
      lm =
        GEPA.LM.new("openai/gpt-4.1",
          client: client(fn _request -> %Response{text: "ans"} end),
          temperature: 0.5
        )

      assert {:ok, ["ans"]} =
               GEPA.LM.batch_complete(
                 lm,
                 [[%{"role" => "user", "content" => "q"}]],
                 temperature: 0.9
               )

      assert_received {:lm_request, request}
      assert request.temperature == 0.9
    end
  end

  describe "inspect and callable parity" do
    test "inspect includes model and completion kwargs" do
      lm = GEPA.LM.new("openai/gpt-4.1", temperature: 0.5)
      inspected = inspect(lm)

      assert inspected =~ "gpt-4.1"
      assert inspected =~ "temperature: 0.5"
    end

    test "LM wrapper remains callable through complete/3" do
      lm = GEPA.LM.new("openai/gpt-4.1", client: fn _prompt -> "ok" end)

      assert {:ok, "ok"} = GEPA.LM.complete(lm, "hello")
      assert function_exported?(GEPA.LM, :complete, 3)
    end
  end

  defp client(response_fn) when is_function(response_fn, 1) do
    %Client{
      adapter: CaptureAdapter,
      adapter_state: %{owner: self(), response_fn: response_fn}
    }
  end
end
