defmodule GEPA.ImageTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  describe "new/1" do
    test "converts base64 image data to OpenAI-compatible content parts" do
      image = GEPA.Image.from_base64(Base.encode64("png-bytes"), "image/png")

      assert %{
               "type" => "image_url",
               "image_url" => %{"url" => url}
             } = GEPA.Image.to_openai_content_part(image)

      assert String.starts_with?(url, "data:image/png;base64,")
      assert url =~ Base.encode64("png-bytes")
    end

    test "infers media type from file path" do
      path = Path.join(System.tmp_dir!(), "gepa-image-#{System.unique_integer([:positive])}.svg")
      File.write!(path, "<svg></svg>")
      on_exit(fn -> File.rm(path) end)

      image = GEPA.Image.from_path(path)

      assert GEPA.Image.media_type(image) == "image/svg+xml"

      assert get_in(GEPA.Image.to_openai_content_part(image), ["image_url", "url"]) =~
               "data:image/svg+xml;base64,"
    end

    test "accepts URL images without re-encoding" do
      image = GEPA.Image.from_url("https://example.com/render.png")

      assert GEPA.Image.to_openai_content_part(image) == %{
               "type" => "image_url",
               "image_url" => %{"url" => "https://example.com/render.png"}
             }
    end

    test "requires exactly one source" do
      assert_raise ArgumentError, fn -> GEPA.Image.new([]) end

      assert_raise ArgumentError, fn ->
        GEPA.Image.new(
          url: "https://example.com/a.png",
          base64_data: "abc",
          media_type: "image/png"
        )
      end
    end

    test "requires media_type for raw base64 data" do
      assert_raise ArgumentError, fn -> GEPA.Image.new(base64_data: "abc") end
    end
  end
end
