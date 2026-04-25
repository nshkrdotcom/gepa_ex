defmodule GEPA.Adapters.Default do
  @moduledoc """
  Official-style default adapter for simple text-in/text-out tasks.

  The adapter calls a task model with chat messages, evaluates the response,
  and builds reflective records from captured trajectories. It is useful when
  users want to optimize one prompt without writing a custom adapter first.
  """

  @behaviour GEPA.Adapter

  defstruct [:model, :evaluator, :failure_score]

  @type evaluator_result ::
          float()
          | {float(), String.t()}
          | {float(), String.t(), %{String.t() => float()} | nil}
          | %{
              score: float(),
              feedback: String.t(),
              objective_scores: %{String.t() => float()} | nil
            }

  @type t :: %__MODULE__{
          model: function() | GEPA.LLM.t(),
          evaluator: (map(), String.t() -> evaluator_result()) | nil,
          failure_score: float()
        }

  @doc """
  Create a default adapter.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      model: Keyword.fetch!(opts, :model),
      evaluator: opts[:evaluator],
      failure_score: Keyword.get(opts, :failure_score, 0.0)
    }
  end

  @impl true
  def evaluate(%__MODULE__{} = adapter, batch, candidate, capture_traces) do
    system_content = candidate |> Map.values() |> List.first() || ""

    results =
      Enum.map(batch, fn data ->
        messages = [
          %{role: "system", content: system_content},
          %{role: "user", content: input_text(data)}
        ]

        response = complete(adapter.model, messages)
        {score, feedback, objective_scores} = evaluate_response(adapter, data, response)

        output = %{full_assistant_response: response}

        trajectory =
          if capture_traces do
            %{
              data: data,
              full_assistant_response: response,
              feedback: feedback
            }
          end

        {output, score, trajectory, objective_scores}
      end)

    {outputs, scores, trajectories, objective_scores} =
      Enum.reduce(results, {[], [], [], []}, fn {output, score, trajectory, objective_scores},
                                                {outputs, scores, trajectories,
                                                 objective_scores_acc} ->
        {
          [output | outputs],
          [score | scores],
          [trajectory | trajectories],
          [objective_scores | objective_scores_acc]
        }
      end)

    {:ok,
     %GEPA.EvaluationBatch{
       outputs: Enum.reverse(outputs),
       scores: Enum.reverse(scores),
       trajectories: if(capture_traces, do: Enum.reverse(trajectories)),
       objective_scores: normalize_objective_scores(Enum.reverse(objective_scores)),
       num_metric_calls: length(batch)
     }}
  end

  @impl true
  def make_reflective_dataset(%__MODULE__{}, _candidate, eval_batch, components_to_update) do
    trajectories = eval_batch.trajectories || []

    if trajectories == [] do
      {:error, :missing_trajectories}
    else
      {:ok,
       Map.new(components_to_update, fn component ->
         items =
           Enum.map(trajectories, fn trajectory ->
             %{
               "Inputs" => input_text(trajectory.data),
               "Generated Outputs" => trajectory.full_assistant_response,
               "Feedback" => trajectory.feedback
             }
           end)

         {component, items}
       end)}
    end
  end

  defp complete(model, messages) when is_function(model, 1), do: model.(messages)

  defp complete(model, messages) do
    prompt =
      messages
      |> Enum.map_join("\n\n", fn message -> "#{message.role}: #{message.content}" end)

    case GEPA.LLM.complete(model, prompt) do
      {:ok, response} -> response
      {:error, reason} -> "LLM error: #{inspect(reason)}"
    end
  end

  defp evaluate_response(%__MODULE__{evaluator: nil} = adapter, data, response) do
    answer = answer_text(data)

    if answer != nil and String.contains?(response, answer) do
      {1.0,
       "The generated response is correct. The response includes the correct answer '#{answer}'.",
       nil}
    else
      {adapter.failure_score,
       "The generated response is incorrect. The correct answer is '#{answer}'. Ensure that the correct answer is included in the response exactly as it is.",
       nil}
    end
  end

  defp evaluate_response(%__MODULE__{evaluator: evaluator}, data, response)
       when is_function(evaluator, 2) do
    normalize_evaluator_result(evaluator.(data, response))
  end

  defp normalize_evaluator_result(score) when is_number(score), do: {score * 1.0, "", nil}
  defp normalize_evaluator_result({score, feedback}), do: {score * 1.0, feedback, nil}

  defp normalize_evaluator_result({score, feedback, objective_scores}),
    do: {score * 1.0, feedback, objective_scores}

  defp normalize_evaluator_result(%{score: score, feedback: feedback} = result) do
    {score * 1.0, feedback, Map.get(result, :objective_scores)}
  end

  defp normalize_objective_scores(scores) do
    cond do
      Enum.all?(scores, &is_nil/1) -> nil
      Enum.all?(scores, &is_map/1) -> scores
      true -> raise ArgumentError, "objective scores must either be all nil or all maps"
    end
  end

  defp input_text(data), do: data[:input] || data["input"] || to_string(data)
  defp answer_text(data), do: data[:answer] || data["answer"]
end
