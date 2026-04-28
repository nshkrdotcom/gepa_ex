defmodule GEPA.Seed do
  @moduledoc """
  Helpers for upstream-compatible LLM seed candidate generation.

  This mirrors the Python `seed_candidate=None` path: when the user gives an
  objective but no initial candidate, a reflection LM is asked to produce a
  starting artifact.  The generated text is extracted from the first fenced
  block when present and stored under a caller-supplied candidate key.
  """

  @default_key "current_candidate"

  @doc "Build the seed-generation prompt sent to the reflection LM."
  @spec build_prompt(keyword() | map()) :: String.t()
  def build_prompt(opts) do
    opts = Map.new(opts)
    objective = get_opt(opts, :objective) || ""
    background = get_opt(opts, :background)
    dataset = get_opt(opts, :dataset)

    sections = [
      "## Goal\n\n#{objective}",
      background_section(background),
      sample_inputs_section(dataset),
      """
      ## Output Format

      Return a complete initial candidate as plain text inside ``` blocks.
      Do not include explanatory prose outside the candidate unless it is part of the candidate.
      """
    ]

    sections
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  @doc "Ask an LM to generate a seed candidate map."
  @spec generate(term(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def generate(lm, opts) do
    opts = Map.new(opts)
    key = Map.get(opts, :candidate_key, @default_key)
    logger = get_opt(opts, :logger)
    prompt = build_prompt(opts)

    log(logger, "Generating initial seed candidate via LLM...")

    with {:ok, text} <- GEPA.LLM.complete(lm, prompt) do
      candidate = extract_fenced_text(text)
      log(logger, "Generated seed candidate (#{String.length(candidate)} chars)")
      {:ok, %{key => candidate}}
    end
  end

  @doc "Extract content from a fenced code block, preserving raw text fallback."
  @spec extract_fenced_text(term()) :: String.t()
  def extract_fenced_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    first = :binary.match(trimmed, "```")
    last = trimmed |> :binary.matches("```") |> List.last()

    case {first, last} do
      {{start, 3}, {finish, 3}} when start < finish ->
        trimmed
        |> binary_part(start + 3, finish - start - 3)
        |> strip_optional_language()

      {{0, 3}, _} ->
        trimmed
        |> String.replace_prefix("```", "")
        |> strip_optional_language()

      {_, {finish, 3}} when finish + 3 == byte_size(trimmed) ->
        trimmed
        |> binary_part(0, finish)
        |> String.trim()

      _ ->
        trimmed
    end
  end

  def extract_fenced_text(other), do: to_string(other)

  defp get_opt(opts, key) do
    cond do
      Map.has_key?(opts, key) -> Map.get(opts, key)
      Map.has_key?(opts, Atom.to_string(key)) -> Map.get(opts, Atom.to_string(key))
      true -> nil
    end
  end

  defp log(nil, _message), do: :ok

  defp log(logger, message) when is_function(logger, 1) do
    logger.(message)
    :ok
  end

  defp log(%{log: logger}, message) when is_function(logger, 1), do: log(logger, message)
  defp log(%{"log" => logger}, message) when is_function(logger, 1), do: log(logger, message)
  defp log(_logger, _message), do: :ok

  defp background_section(nil), do: nil
  defp background_section(""), do: nil
  defp background_section(background), do: "## Domain Context & Constraints\n\n#{background}"

  defp sample_inputs_section(nil), do: nil
  defp sample_inputs_section([]), do: "## Sample Inputs\n\n_No examples were provided._"

  defp sample_inputs_section(dataset) when is_list(dataset) do
    samples =
      dataset
      |> Enum.take(3)
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {example, idx} ->
        "### Example #{idx}\n\n#{inspect(example, pretty: true, limit: :infinity)}"
      end)

    "## Sample Inputs\n\n#{samples}"
  end

  defp sample_inputs_section(dataset), do: sample_inputs_section(List.wrap(dataset))

  defp strip_optional_language(text) do
    text
    |> String.replace(~r/^\S*\n/, "", global: false)
    |> String.trim()
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false
end
