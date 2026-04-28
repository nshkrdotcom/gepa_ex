defmodule GEPA.Proposer.InstructionProposal do
  @moduledoc """
  LLM-based instruction proposal with configurable templates.

  This module generates improved instruction texts by prompting an LLM with the
  current instruction and feedback from execution traces. It supports the
  upstream `<curr_param>` / `<side_info>` template contract and Elixir's legacy
  `{component_name}` / `{current_instruction}` / `{reflective_dataset}` form.

  Reflective dataset records may include `%GEPA.Image{}` values. Images are
  rendered as `[IMAGE-N]` markers in the text and sent as multimodal content
  parts to compatible reflection LLMs.
  """

  alias GEPA.LLM.Request

  defstruct [
    :template,
    :llm,
    :extract_fn,
    :format_fn,
    structured_output: false
  ]

  @type prompt :: String.t() | [map()]

  @type t :: %__MODULE__{
          template: String.t() | %{String.t() => String.t()},
          llm: GEPA.LLM.t(),
          extract_fn: (String.t() -> String.t()) | nil,
          format_fn:
            (list(map()) -> String.t() | {String.t(), [GEPA.Image.t()]} | prompt()) | nil,
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

  @doc "Returns the default template string."
  @spec default_template() :: String.t()
  def default_template, do: @default_template

  @doc "Create a new instruction proposal configuration."
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

  @doc "Propose new instruction text for one component."
  @spec propose(t(), String.t(), String.t(), list(map())) :: {:ok, String.t()} | {:error, term()}
  def propose(%__MODULE__{} = config, component_name, current_instruction, dataset) do
    case propose_with_metadata(config, component_name, current_instruction, dataset) do
      {:ok, new_instruction, _prompt, _raw_response} -> {:ok, new_instruction}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Propose new instruction text and retain rendered prompt plus raw LLM output."
  @spec propose_with_metadata(t(), String.t(), String.t(), list(map())) ::
          {:ok, String.t(), prompt(), String.t()} | {:error, term()}
  def propose_with_metadata(%__MODULE__{} = config, component_name, current_instruction, dataset) do
    {formatted_dataset, images} = format_dataset(config, dataset)
    template = template_for_component(config.template, component_name)

    prompt_text = render_prompt(template, component_name, current_instruction, formatted_dataset)
    prompt = maybe_multimodal_prompt(prompt_text, images)

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
          response = String.trim(response)
          {:ok, extract_instruction(config, response), prompt, response}

        {:error, reason} ->
          {:error, {:llm_error, reason}}
      end
    end
  end

  @doc "Propose new texts for multiple components."
  @spec propose_batch(t(), map(), map(), list(String.t())) :: {:ok, map()} | {:error, term()}
  def propose_batch(%__MODULE__{} = config, candidate, reflective_dataset, components) do
    case propose_batch_with_metadata(config, candidate, reflective_dataset, components) do
      {:ok, new_texts, _prompts, _raw_outputs} -> {:ok, new_texts}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Propose new text for multiple components and retain prompt/raw-output metadata."
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

  defp format_dataset(%__MODULE__{format_fn: nil}, dataset), do: default_format_dataset(dataset)

  defp format_dataset(%__MODULE__{format_fn: format_fn}, dataset) do
    case format_fn.(dataset) do
      {text, images} when is_binary(text) and is_list(images) ->
        {text, images}

      messages when is_list(messages) ->
        {Request.to_text(messages) || inspect(messages), []}

      text when is_binary(text) ->
        {text, []}

      other ->
        {inspect(other), []}
    end
  end

  defp default_format_dataset([]), do: {"_No examples available._", []}

  defp default_format_dataset(dataset) do
    {blocks, images} =
      dataset
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {item, i}, image_acc ->
        {body, image_acc} = render_value(item, image_acc, 2)
        {"# Example #{i}\n#{body}", image_acc}
      end)

    text = Enum.join(blocks, "\n\n---\n\n")

    text =
      if images == [] do
        text
      else
        "The evaluation data below includes visual content (#{length(images)} image(s)). Analyze both the text and images when suggesting improvements.\n\n" <>
          text
      end

    {text, images}
  end

  defp render_value(%GEPA.Image{} = image, images, _level) do
    images = images ++ [image]
    {"[IMAGE-#{length(images)} — see visual content]\n\n", images}
  end

  defp render_value(%{} = map, images, level) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_reduce(images, fn {key, value}, image_acc ->
      {rendered, image_acc} = render_value(value, image_acc, min(level + 1, 6))
      header = String.duplicate("#", level) <> " " <> to_string(key)
      {header <> "\n" <> rendered, image_acc}
    end)
    |> then(fn {parts, image_acc} -> {Enum.join(parts, "\n"), image_acc} end)
  end

  defp render_value(list, images, level) when is_list(list) do
    list
    |> Enum.with_index(1)
    |> Enum.map_reduce(images, fn {value, idx}, image_acc ->
      {rendered, image_acc} = render_value(value, image_acc, min(level + 1, 6))
      header = String.duplicate("#", level) <> " Item #{idx}"
      {header <> "\n" <> rendered, image_acc}
    end)
    |> then(fn {parts, image_acc} -> {Enum.join(parts, "\n"), image_acc} end)
  end

  defp render_value(value, images, _level), do: {to_string_value(value) <> "\n\n", images}

  defp to_string_value(value) when is_binary(value), do: String.trim(value)
  defp to_string_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp to_string_value(nil), do: "nil"
  defp to_string_value(value), do: inspect(value)

  defp maybe_multimodal_prompt(text, []), do: text

  defp maybe_multimodal_prompt(text, images) do
    content =
      [%{"type" => "text", "text" => text}] ++
        Enum.map(images, &GEPA.Image.to_openai_content_part/1)

    [%{"role" => "user", "content" => content}]
  end

  defp extract_instruction(%__MODULE__{extract_fn: nil}, response),
    do: extract_fenced_instruction(response)

  defp extract_instruction(%__MODULE__{extract_fn: extract_fn}, response),
    do: extract_fn.(response)

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
