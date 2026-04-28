defmodule GEPA.Adapter.FullProgramAdapterParityTest do
  use ExUnit.Case, async: true

  alias GEPA.Adapter.Dispatch
  alias GEPA.EvaluationBatch

  defmodule FullProgramAdapter do
    @behaviour GEPA.Adapter

    defstruct [:reflection_lm, :test_pid, failure_score: 0.0]

    def new(opts \\ []) do
      struct!(
        __MODULE__,
        Keyword.put_new(opts, :reflection_lm, fn _prompt -> "generated response" end)
      )
    end

    @impl true
    def evaluate(%__MODULE__{} = adapter, batch, candidate, capture_traces) do
      case build_program(candidate["program"]) do
        :ok ->
          {:ok,
           %EvaluationBatch{
             outputs: Enum.map(batch, fn example -> %{ok: true, example: example} end),
             scores: Enum.map(batch, fn _ -> 1.0 end),
             trajectories: if(capture_traces, do: Enum.map(batch, fn _ -> %{ok: true} end))
           }}

        {:error, reason} ->
          {:ok, failed_batch(adapter, batch, reason, capture_traces)}
      end
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, eval_batch, components) do
      {:ok,
       Map.new(components, fn component ->
         {component, Enum.map(eval_batch.outputs, &%{"Generated Outputs" => &1})}
       end)}
    end

    @impl true
    def propose_new_texts(%__MODULE__{} = adapter, candidate, reflective_dataset, components) do
      prompt = %{
        curr_program: candidate["program"],
        dataset_with_feedback: reflective_dataset["program"]
      }

      response = adapter.reflection_lm.(prompt)

      if adapter.test_pid do
        send(adapter.test_pid, {:reflection_lm_called, prompt, response})
      end

      {:ok, Map.new(components, &{&1, response})}
    end

    defp build_program(program) do
      cond do
        String.contains?(program, "syntax error") -> {:error, :syntax_error}
        String.trim(program) == "x = 42" -> {:error, :missing_program_object}
        String.contains?(program, "raise RuntimeError") -> {:error, :runtime_error}
        true -> :ok
      end
    end

    defp failed_batch(adapter, batch, reason, capture_traces) do
      %EvaluationBatch{
        outputs: Enum.map(batch, fn _ -> %{error: reason} end),
        scores: Enum.map(batch, fn _ -> adapter.failure_score end),
        trajectories: if(capture_traces, do: Enum.map(batch, fn _ -> %{error: reason} end))
      }
    end
  end

  describe "upstream full-program build failure parity" do
    test "outputs is list on syntax error" do
      adapter = FullProgramAdapter.new()
      batch = make_batch(4)
      candidate = %{"program" => "def foo(  # syntax error"}

      assert {:ok, %EvaluationBatch{} = result} =
               Dispatch.evaluate(adapter, batch, candidate, false)

      assert is_list(result.outputs)
      assert length(result.outputs) == length(batch)
      assert length(result.scores) == length(batch)
      assert Enum.all?(result.scores, &(&1 == 0.0))
    end

    test "outputs is list on missing program object" do
      adapter = FullProgramAdapter.new()
      batch = make_batch(2)
      candidate = %{"program" => "x = 42"}

      assert {:ok, result} = Dispatch.evaluate(adapter, batch, candidate, false)
      assert is_list(result.outputs)
      assert length(result.outputs) == length(batch)
    end

    test "outputs is list on runtime error" do
      adapter = FullProgramAdapter.new()
      batch = make_batch(5)
      candidate = %{"program" => "raise RuntimeError('boom')"}

      assert {:ok, result} = Dispatch.evaluate(adapter, batch, candidate, false)
      assert is_list(result.outputs)
      assert length(result.outputs) == length(batch)
    end

    test "outputs zippable with example ids" do
      adapter = FullProgramAdapter.new()
      batch = make_batch(3)
      candidate = %{"program" => "def foo(  # syntax error"}

      assert {:ok, result} = Dispatch.evaluate(adapter, batch, candidate, false)

      example_ids = Enum.to_list(0..(length(batch) - 1))
      outputs_by_id = Map.new(Enum.zip(example_ids, result.outputs))
      scores_by_id = Map.new(Enum.zip(example_ids, result.scores))

      assert map_size(outputs_by_id) == length(batch)
      assert map_size(scores_by_id) == length(batch)
    end
  end

  describe "upstream reflection LM protocol parity" do
    test "lambda wrapper accepted" do
      wrapped = fn prompt -> ["response text"] |> hd() |> then(&"#{&1}: #{prompt}") end
      adapter = FullProgramAdapter.new(reflection_lm: wrapped)

      assert adapter.reflection_lm.("prompt") == "response text: prompt"
    end

    test "plain callable accepted" do
      lm = fn _prompt -> "generated response" end
      adapter = FullProgramAdapter.new(reflection_lm: lm)

      assert adapter.reflection_lm.("prompt") == "generated response"
    end

    test "propose new texts calls lm correctly" do
      test_pid = self()

      lm = fn prompt ->
        send(test_pid, {:lm_prompt, prompt})
        "import dspy\nprogram = dspy.Predict('q -> a')"
      end

      adapter = FullProgramAdapter.new(reflection_lm: lm, test_pid: test_pid)
      candidate = %{"program" => "import dspy\nprogram = dspy.Predict('q -> a')"}
      reflective_dataset = %{"program" => [%{"input" => "q1", "output" => "a1", "score" => 0.5}]}

      assert {:ok, %{"program" => new_program}, %{}, %{}} =
               Dispatch.propose_new_texts(adapter, candidate, reflective_dataset, ["program"])

      assert new_program == "import dspy\nprogram = dspy.Predict('q -> a')"

      assert_receive {:lm_prompt,
                      %{
                        curr_program: "import dspy\nprogram = dspy.Predict('q -> a')",
                        dataset_with_feedback: [
                          %{"input" => "q1", "output" => "a1", "score" => 0.5}
                        ]
                      }}

      assert_receive {:reflection_lm_called, _prompt, ^new_program}
    end
  end

  defp make_batch(n) do
    Enum.map(0..(n - 1), &%{question: "q#{&1}"})
  end
end
