defmodule GEPA.Image do
  @moduledoc """
  Image data wrapper for visual side-information in `GEPA.OptimizeAnything`.

  Include `%GEPA.Image{}` values anywhere inside evaluator side-info or
  reflective-dataset records. `GEPA.Proposer.InstructionProposal` detects these
  values, replaces them with `[IMAGE-N]` placeholders in the textual prompt, and
  appends OpenAI-compatible multimodal content parts to the reflection LLM call.

  Provide exactly one of `:url`, `:path`, or `:base64_data`.
  """

  @media_type_by_ext %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".bmp" => "image/bmp",
    ".svg" => "image/svg+xml"
  }

  @type t :: %__MODULE__{
          url: String.t() | nil,
          path: Path.t() | nil,
          base64_data: String.t() | nil,
          media_type: String.t() | nil
        }

  defstruct [:url, :path, :base64_data, :media_type]

  @doc "Create an image wrapper from keyword or map options."
  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts) or is_map(opts) do
    opts = Map.new(opts)

    image = %__MODULE__{
      url: Map.get(opts, :url) || Map.get(opts, "url"),
      path: Map.get(opts, :path) || Map.get(opts, "path"),
      base64_data: Map.get(opts, :base64_data) || Map.get(opts, "base64_data"),
      media_type: Map.get(opts, :media_type) || Map.get(opts, "media_type")
    }

    validate!(image)
  end

  @doc "Create an image wrapper from a URL or data URI."
  @spec from_url(String.t()) :: t()
  def from_url(url) when is_binary(url), do: new(url: url)

  @doc "Create an image wrapper from a local path."
  @spec from_path(Path.t(), String.t() | nil) :: t()
  def from_path(path, media_type \\ nil) when is_binary(path),
    do: new(path: path, media_type: media_type)

  @doc "Create an image wrapper from raw base64 bytes and a MIME type."
  @spec from_base64(String.t(), String.t()) :: t()
  def from_base64(base64_data, media_type)
      when is_binary(base64_data) and is_binary(media_type) do
    new(base64_data: base64_data, media_type: media_type)
  end

  @doc "Validate an image wrapper, raising on invalid source combinations."
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = image) do
    source_count =
      [image.url, image.path, image.base64_data]
      |> Enum.count(&present?/1)

    cond do
      source_count != 1 ->
        raise ArgumentError, "GEPA.Image requires exactly one of :url, :path, or :base64_data"

      present?(image.base64_data) and not present?(image.media_type) ->
        raise ArgumentError, "GEPA.Image requires :media_type when using :base64_data"

      true ->
        image
    end
  end

  @doc "Return the MIME type for a path-backed image, defaulting to image/png."
  @spec media_type(t()) :: String.t()
  def media_type(%__MODULE__{media_type: media_type})
      when is_binary(media_type) and media_type != "" do
    media_type
  end

  def media_type(%__MODULE__{path: path}) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&Map.get(@media_type_by_ext, &1, "image/png"))
  end

  def media_type(%__MODULE__{}), do: "image/png"

  @doc "Convert to an OpenAI-compatible multimodal `image_url` content part."
  @spec to_openai_content_part(t()) :: map()
  def to_openai_content_part(%__MODULE__{url: url} = image) when is_binary(url) and url != "" do
    validate!(image)
    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  def to_openai_content_part(%__MODULE__{path: path} = image)
      when is_binary(path) and path != "" do
    validate!(image)
    data = path |> File.read!() |> Base.encode64()

    %{
      "type" => "image_url",
      "image_url" => %{"url" => "data:#{media_type(image)};base64,#{data}"}
    }
  end

  def to_openai_content_part(%__MODULE__{base64_data: data} = image)
      when is_binary(data) and data != "" do
    validate!(image)

    %{
      "type" => "image_url",
      "image_url" => %{"url" => "data:#{media_type(image)};base64,#{data}"}
    }
  end

  defp present?(value), do: is_binary(value) and value != ""
end
