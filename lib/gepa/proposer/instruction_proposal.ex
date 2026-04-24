defmodule GEPA.Proposer.InstructionProposal do
  @moduledoc """
  LLM-based instruction proposal with configurable templates.

  This module generates improved instruction texts by prompting an LLM with
  the current instruction and feedback from execution traces.

  ## Default Template

  The default template includes placeholders for:
  - `{component_name}` - Name of the component being optimized
  - `{current_instruction}` - Current instruction text
  - `{reflective_dataset}` - Formatted examples with feedback

  ## Custom Templates

      template = \"\"\"
      Improve this prompt for {component_name}:

      Current: {current_instruction}

      Examples: {reflective_dataset}

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

  @required_placeholders ["{component_name}", "{current_instruction}", "{reflective_dataset}"]

  @default_template """
  You are optimizing instructions for a language model pipeline.

  ## Current Instruction for "{component_name}"

  ```
  {current_instruction}
  ```

  ## Performance Examples

  {reflective_dataset}

  ## Task

  Based on the feedback above, propose an improved instruction that:
  1. Addresses the identified issues
  2. Maintains the core functionality
  3. Is clear and concise

  Write ONLY the new instruction, nothing else:
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
  - `:template` - Custom prompt template (default: built-in template)
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
    formatted_dataset = format_dataset(config, dataset)

    prompt =
      config.template
      |> String.replace("{component_name}", component_name)
      |> String.replace("{current_instruction}", current_instruction)
      |> String.replace("{reflective_dataset}", formatted_dataset)

    if config.structured_output do
      case GEPA.LLM.complete_structured(config.llm, prompt) do
        {:ok, result} ->
          {:ok, extract_structured_instruction(result)}

        {:error, reason} ->
          {:error, {:llm_error, reason}}
      end
    else
      case GEPA.LLM.complete(config.llm, prompt) do
        {:ok, response} ->
          {:ok, extract_instruction(config, response)}

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
    results =
      Enum.map(components, fn component ->
        current = Map.get(candidate, component, "")
        dataset = Map.get(reflective_dataset, component, [])

        case propose(config, component, current, dataset) do
          {:ok, new_text} -> {:ok, {component, new_text}}
          {:error, reason} -> {:error, {component, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      new_texts =
        results
        |> Enum.map(fn {:ok, pair} -> pair end)
        |> Enum.into(%{})

      {:ok, new_texts}
    else
      {:error, {:partial_failure, errors}}
    end
  end

  # Private functions

  defp validate_template!(template) do
    missing =
      Enum.reject(@required_placeholders, fn placeholder ->
        String.contains?(template, placeholder)
      end)

    if not Enum.empty?(missing) do
      raise ArgumentError,
            "template missing required placeholders: #{inspect(missing)}"
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
