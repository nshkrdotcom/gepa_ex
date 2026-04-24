defmodule GEPA.Adapters.Basic do
  @moduledoc """
  Basic adapter for simple Q&A tasks.

  Evaluates candidates by checking if the expected answer appears in the
  generated response. Suitable for testing and simple optimization tasks.

  Note: This is a simplified adapter for testing. For production use,
  implement the GEPA.Adapter behavior directly.
  """

  alias GEPA.LLM.Mock

  defstruct [:llm_client, :failure_score]

  @type t :: %__MODULE__{
          llm_client: module() | struct(),
          failure_score: float()
        }

  @doc """
  Create a new basic adapter.

  ## Options

  - `:llm_client` - Module implementing generate/1 (default: GEPA.LLM.Mock)
  - `:failure_score` - Score for failed evaluations (default: 0.0)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      llm_client: opts[:llm_client] || opts[:llm] || Mock,
      failure_score: opts[:failure_score] || 0.0
    }
  end

  @doc """
  Evaluate a batch of examples with the candidate program.
  """
  @spec evaluate(
          t(),
          [GEPA.Adapter.data_inst()],
          GEPA.Adapter.candidate(),
          boolean()
        ) :: {:ok, GEPA.EvaluationBatch.t()}
  def evaluate(%__MODULE__{} = adapter, batch, candidate, capture_traces) do
    # Extract instruction (assumes single component)
    instruction =
      case map_size(candidate) do
        1 -> candidate |> Map.values() |> hd()
        _ -> Map.get(candidate, "instruction", "")
      end

    # Evaluate each example
    results =
      Enum.map(batch, fn example ->
        evaluate_single(adapter, example, instruction, capture_traces)
      end)

    # Separate outputs, scores, trajectories
    {outputs, scores, trajs} =
      Enum.reduce(results, {[], [], []}, fn {:ok, output, score, traj}, {outs, scrs, trjs} ->
        {[output | outs], [score | scrs], [traj | trjs]}
      end)

    trajectories =
      if capture_traces do
        Enum.reverse(trajs)
      else
        nil
      end

    {:ok,
     %GEPA.EvaluationBatch{
       outputs: Enum.reverse(outputs),
       scores: Enum.reverse(scores),
       trajectories: trajectories
     }}
  end

  @doc """
  Build reflective dataset from evaluation results.
  """
  @spec make_reflective_dataset(
          t(),
          GEPA.Adapter.candidate(),
          GEPA.EvaluationBatch.t(),
          [String.t()]
        ) :: {:ok, GEPA.Adapter.reflective_dataset()}
  def make_reflective_dataset(%__MODULE__{}, candidate, eval_batch, components_to_update) do
    dataset =
      for component <- components_to_update, into: %{} do
        items =
          eval_batch.trajectories
          |> Enum.zip(eval_batch.scores)
          |> Enum.map(fn {traj, score} ->
            build_feedback_item(traj, score, candidate[component])
          end)

        {component, items}
      end

    {:ok, dataset}
  end

  # Private helpers

  defp evaluate_single(%__MODULE__{} = adapter, example, instruction, capture_traces) do
    # Build messages
    messages = [
      %{role: "system", content: instruction},
      %{role: "user", content: example.input}
    ]

    prompt = "#{instruction}\n\nQuestion: #{example.input}\nAnswer:"
    response = complete_with_configured_llm(adapter.llm_client, messages, prompt)

    # Check if answer appears in response
    score =
      if example[:answer] &&
           String.contains?(String.downcase(response), String.downcase(example.answer)) do
        1.0
      else
        0.0
      end

    trajectory =
      if capture_traces do
        %{
          input: example.input,
          expected: example[:answer],
          response: response,
          score: score
        }
      else
        nil
      end

    {:ok, response, score, trajectory}
  end

  defp complete_with_configured_llm(llm_client, messages, prompt) when is_atom(llm_client) do
    cond do
      function_exported?(llm_client, :complete, 1) ->
        case llm_client.complete(messages) do
          {:ok, %{content: response}} -> response
          {:ok, response} when is_binary(response) -> response
          {:error, reason} -> "LLM error: #{inspect(reason)}"
        end

      function_exported?(llm_client, :complete, 3) ->
        complete_with_facade(llm_client, prompt)

      true ->
        "LLM error: unsupported client #{inspect(llm_client)}"
    end
  end

  defp complete_with_configured_llm(llm_client, _messages, prompt) do
    complete_with_facade(llm_client, prompt)
  end

  defp complete_with_facade(llm_client, prompt) do
    case GEPA.LLM.complete(llm_client, prompt) do
      {:ok, response} -> response
      {:error, reason} -> "LLM error: #{inspect(reason)}"
    end
  end

  defp build_feedback_item(trajectory, score, _current_instruction) do
    if score >= 1.0 do
      %{
        "Inputs" => %{"question" => trajectory.input},
        "Generated Outputs" => trajectory.response,
        "Feedback" => "Correct! The answer was found in the response."
      }
    else
      %{
        "Inputs" => %{"question" => trajectory.input},
        "Generated Outputs" => trajectory.response,
        "Feedback" =>
          "Incorrect. Expected answer: #{trajectory.expected}. Please ensure the answer appears clearly in the response."
      }
    end
  end
end
