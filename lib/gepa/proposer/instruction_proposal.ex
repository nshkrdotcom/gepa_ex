defmodule GEPA.Proposer.InstructionProposal do
  @moduledoc """
  LLM-based instruction proposal with configurable templates.

  This module generates improved instruction texts by prompting an LLM with
  the current instruction and feedback from execution traces.

  ## Default Template

  The default template includes placeholders for:
  - `<curr_param>` - Current instruction text
  - `<side_info>` - Formatted examples with feedback

  ## Custom Templates

      template = \"\"\"
      Improve this prompt:

      Current: <curr_param>

      Examples: <side_info>

      Better prompt:
      \"\"\"

      proposal = InstructionProposal.new(template: template, llm: llm)

  ## Example

      llm = GEPA.LLM.req_llm(:openai)
      proposal = InstructionProposal.new(llm: llm)

      dataset = [
        %{
          "Inputs" => %{"question" => "What is 2+2?"},
          "Generated Outputs" => "5",
          "Feedback" => "Wrong. Should be 4."
        }
      ]

      {:ok, improved} = InstructionProposal.propose(
        proposal,
        "math_solver",
        "Answer math questions",
        dataset
      )
  """

  defstruct [
    :template,
    :llm,
    :extract_fn,
    :format_fn,
    structured_output: false
  ]

  @type t :: %__MODULE__{
          template: String.t(),
          llm: GEPA.LLM.t(),
          extract_fn: (String.t() -> String.t()) | nil,
          format_fn: (list(map()) -> String.t()) | nil,
          structured_output: boolean()
        }

  @upstream_placeholders ["<curr_param>", "<side_info>"]
  @legacy_placeholders ["{component_name}", "{current_instruction}", "{reflective_dataset}"]

  @default_template """
  I provided an assistant with the following instructions to perform a task for me:
  ```
  <curr_param>
  ```

  The following are examples of different task inputs provided to the assistant along with the assistant's response for each of them, and some feedback on how the assistant's response could be better:
  ```
  <side_info>
  ```

  Your task is to write a new instruction for the assistant.

  Read the inputs carefully and identify the input format and infer detailed task description about the task I wish to solve with the assistant.

  Read all the assistant responses and the corresponding feedback. Identify all niche and domain specific factual information about the task and include it in the instruction, as a lot of it may not be available to the assistant in the future. The assistant may have utilized a generalizable strategy to solve the task, if so, include that in the instruction as well.

  Provide the new instructions within ``` blocks.
  """

  @doc """
  Returns the default template string.
  """
  @spec default_template() :: String.t()
  def default_template, do: @default_template

  @doc """
  Create a new instruction proposal configuration.

  ## Options

  - `:llm` - LLM configuration for proposals (required)
  - `:template` - Custom prompt template or component/template map
    (default: built-in template)
  - `:extract_fn` - Function to extract instruction from LLM response
  - `:format_fn` - Function to format reflective dataset

  ## Examples

      llm = GEPA.LLM.req_llm(:openai)
      proposal = InstructionProposal.new(llm: llm)

      # With custom template
      proposal = InstructionProposal.new(
        llm: llm,
        template: "Improve {component_name}: {current_instruction}\\n{reflective_dataset}"
      )
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    llm = opts[:llm] || raise ArgumentError, "must provide :llm"
    template = opts[:template] || @default_template

    validate_template!(template)

    %__MODULE__{
      template: template,
      llm: llm,
      extract_fn: opts[:extract_fn],
      format_fn: opts[:format_fn],
      structured_output: Keyword.get(opts, :structured_output, false)
    }
  end

  @doc """
  Propose new instruction text for a component.

  ## Parameters

  - `config` - InstructionProposal configuration
  - `component_name` - Name of the component being optimized
  - `current_instruction` - Current instruction text
  - `dataset` - List of feedback records from reflective dataset

  ## Returns

  - `{:ok, new_instruction}` - Improved instruction text
  - `{:error, reason}` - Error from LLM or processing

  ## Example

      {:ok, improved} = InstructionProposal.propose(
        proposal,
        "math_solver",
        "Answer math questions",
        [%{"Inputs" => %{}, "Generated Outputs" => "", "Feedback" => "improve"}]
      )
  """
  @spec propose(t(), String.t(), String.t(), list(map())) ::
          {:ok, String.t()} | {:error, term()}
  def propose(%__MODULE__{} = config, component_name, current_instruction, dataset) do
    case propose_with_metadata(config, component_name, current_instruction, dataset) do
      {:ok, new_instruction, _prompt, _raw_response} -> {:ok, new_instruction}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Propose new instruction text and return the rendered prompt plus raw LLM
  output for tracking.
  """
  @spec propose_with_metadata(t(), String.t(), String.t(), list(map())) ::
          {:ok, String.t(), String.t(), String.t()} | {:error, term()}
  def propose_with_metadata(%__MODULE__{} = config, component_name, current_instruction, dataset) do
    formatted_dataset = format_dataset(config, dataset)
    template = template_for_component(config.template, component_name)

    prompt = render_prompt(template, component_name, current_instruction, formatted_dataset)

    if config.structured_output do
      case GEPA.LLM.complete_structured(config.llm, prompt) do
        {:ok, result} ->
          {:ok, extract_structured_instruction(result), prompt, inspect(result)}

        {:error, reason} ->
          {:error, {:llm_error, reason}}
      end
    else
      case GEPA.LLM.complete(config.llm, prompt) do
        {:ok, response} ->
          {:ok, extract_instruction(config, response), prompt, response}

        {:error, reason} ->
          {:error, {:llm_error, reason}}
      end
    end
  end

  @doc """
  Propose new texts for multiple components.

  ## Parameters

  - `config` - InstructionProposal configuration
  - `candidate` - Current candidate (map of component name -> text)
  - `reflective_dataset` - Map of component name -> list of feedback records
  - `components` - List of component names to propose for

  ## Returns

  - `{:ok, new_texts}` - Map of component name -> new instruction text
  - `{:error, reason}` - Error details

  ## Example

      {:ok, new_texts} = InstructionProposal.propose_batch(
        proposal,
        %{"system_prompt" => "...", "user_template" => "..."},
        %{"system_prompt" => [...], "user_template" => [...]},
        ["system_prompt", "user_template"]
      )
  """
  @spec propose_batch(t(), map(), map(), list(String.t())) ::
          {:ok, map()} | {:error, term()}
  def propose_batch(%__MODULE__{} = config, candidate, reflective_dataset, components) do
    case propose_batch_with_metadata(config, candidate, reflective_dataset, components) do
      {:ok, new_texts, _prompts, _raw_outputs} -> {:ok, new_texts}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Propose new text for multiple components and retain prompt/raw-output
  metadata keyed by component.
  """
  @spec propose_batch_with_metadata(t(), map(), map(), list(String.t())) ::
          {:ok, map(), map(), map()} | {:error, term()}
  def propose_batch_with_metadata(
        %__MODULE__{} = config,
        candidate,
        reflective_dataset,
        components
      ) do
    results =
      Enum.map(components, fn component ->
        current = Map.get(candidate, component, "")
        dataset = Map.get(reflective_dataset, component, [])

        case propose_with_metadata(config, component, current, dataset) do
          {:ok, new_text, prompt, raw_output} -> {:ok, {component, new_text, prompt, raw_output}}
          {:error, reason} -> {:error, {component, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      successes = Enum.map(results, fn {:ok, value} -> value end)

      new_texts =
        Map.new(successes, fn {component, new_text, _prompt, _raw} -> {component, new_text} end)

      prompts =
        Map.new(successes, fn {component, _new_text, prompt, _raw} -> {component, prompt} end)

      raw_outputs =
        Map.new(successes, fn {component, _new_text, _prompt, raw} -> {component, raw} end)

      {:ok, new_texts, prompts, raw_outputs}
    else
      {:error, {:partial_failure, errors}}
    end
  end

  # Private functions

  defp validate_template!(template) when is_map(template) do
    Enum.each(template, fn {_component, component_template} ->
      validate_template!(component_template)
    end)
  end

  defp validate_template!(template) when is_binary(template) do
    upstream? = Enum.all?(@upstream_placeholders, &String.contains?(template, &1))
    legacy? = Enum.all?(@legacy_placeholders, &String.contains?(template, &1))

    cond do
      upstream? or legacy? ->
        :ok

      Enum.any?(@legacy_placeholders, &String.contains?(template, &1)) ->
        missing = Enum.reject(@legacy_placeholders, &String.contains?(template, &1))
        raise ArgumentError, "template missing required placeholders: #{inspect(missing)}"

      Enum.any?(@upstream_placeholders, &String.contains?(template, &1)) ->
        missing = Enum.reject(@upstream_placeholders, &String.contains?(template, &1))
        raise ArgumentError, "template missing required placeholders: #{inspect(missing)}"

      true ->
        raise ArgumentError,
              "template must include upstream placeholders #{inspect(@upstream_placeholders)} or legacy placeholders #{inspect(@legacy_placeholders)}"
    end
  end

  defp validate_template!(template) do
    raise ArgumentError,
          "template must be a string or component/template map, got: #{inspect(template)}"
  end

  defp template_for_component(template, component_name) when is_map(template) do
    Map.get(template, component_name) || Map.get(template, to_string(component_name)) ||
      @default_template
  end

  defp template_for_component(template, _component_name), do: template

  defp render_prompt(template, component_name, current_instruction, formatted_dataset) do
    if Enum.all?(@upstream_placeholders, &String.contains?(template, &1)) do
      template
      |> String.replace("<curr_param>", current_instruction)
      |> String.replace("<side_info>", formatted_dataset)
    else
      template
      |> String.replace("{component_name}", component_name)
      |> String.replace("{current_instruction}", current_instruction)
      |> String.replace("{reflective_dataset}", formatted_dataset)
    end
  end

  defp format_dataset(%__MODULE__{format_fn: nil}, dataset) do
    default_format_dataset(dataset)
  end

  defp format_dataset(%__MODULE__{format_fn: format_fn}, dataset) do
    format_fn.(dataset)
  end

  defp default_format_dataset([]) do
    "_No examples available._"
  end

  defp default_format_dataset(dataset) do
    dataset
    |> Enum.with_index(1)
    |> Enum.map_join("\n---\n", fn {item, i} ->
      inputs = item["Inputs"] || %{}
      outputs = item["Generated Outputs"] || "N/A"
      feedback = item["Feedback"] || "No feedback"

      inputs_json =
        case Jason.encode(inputs, pretty: true) do
          {:ok, json} -> json
          {:error, _} -> inspect(inputs)
        end

      """
      ### Example #{i}

      **Inputs:**
      ```json
      #{inputs_json}
      ```

      **Generated Outputs:**
      #{outputs}

      **Feedback:**
      #{feedback}
      """
    end)
  end

  defp extract_instruction(%__MODULE__{extract_fn: nil}, response) do
    extract_fenced_instruction(response)
  end

  defp extract_instruction(%__MODULE__{extract_fn: extract_fn}, response) do
    extract_fn.(response)
  end

  defp extract_structured_instruction(result) when is_map(result) do
    Map.get(result, "instruction") || Map.get(result, :instruction) || ""
  end

  defp extract_fenced_instruction(response) when is_binary(response) do
    trimmed = String.trim(response)
    first = :binary.match(trimmed, "```")
    last = reverse_match(trimmed, "```")

    case {first, last} do
      {{start, 3}, {finish, 3}} when start < finish ->
        trimmed
        |> binary_part(start + 3, finish - start - 3)
        |> strip_optional_language()

      {{0, 3}, _} ->
        trimmed
        |> strip_opening_fence()
        |> strip_optional_language()

      {_, {finish, 3}} when finish + 3 == byte_size(trimmed) ->
        trimmed
        |> binary_part(0, finish)
        |> String.trim()

      _ ->
        trimmed
    end
  end

  defp reverse_match(text, pattern) do
    text
    |> :binary.matches(pattern)
    |> List.last()
  end

  defp strip_opening_fence("```" <> rest), do: rest
  defp strip_opening_fence(text), do: text

  defp strip_optional_language(text) do
    text
    |> String.replace(~r/^\S*\n/, "", global: false)
    |> String.trim()
  end
end
