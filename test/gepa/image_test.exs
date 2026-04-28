defmodule GEPA.ImageTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Image
  alias GEPA.OptimizeAnything
  alias GEPA.Proposer.InstructionProposal

  @tiny_png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
  @tiny_png_bytes Base.decode64!(@tiny_png_b64)

  describe "new/1" do
    test "constructs from url" do
      image = Image.new(url: "https://example.com/img.png")

      assert image.url == "https://example.com/img.png"
      assert image.path == nil
      assert image.base64_data == nil
    end

    test "constructs from path" do
      image = Image.new(path: "/tmp/img.png")
      assert image.path == "/tmp/img.png"
    end

    test "constructs from base64 data" do
      image = Image.new(base64_data: @tiny_png_b64, media_type: "image/png")
      assert image.base64_data == @tiny_png_b64
    end

    test "converts base64 image data to OpenAI-compatible content parts" do
      image = Image.from_base64(Base.encode64("png-bytes"), "image/png")

      assert %{
               "type" => "image_url",
               "image_url" => %{"url" => url}
             } = Image.to_openai_content_part(image)

      assert String.starts_with?(url, "data:image/png;base64,")
      assert url =~ Base.encode64("png-bytes")
    end

    test "infers media type from file path" do
      path = Path.join(System.tmp_dir!(), "gepa-image-#{System.unique_integer([:positive])}.svg")
      File.write!(path, "<svg></svg>")
      on_exit(fn -> File.rm(path) end)

      image = Image.from_path(path)

      assert Image.media_type(image) == "image/svg+xml"

      assert get_in(Image.to_openai_content_part(image), ["image_url", "url"]) =~
               "data:image/svg+xml;base64,"
    end

    test "accepts URL images without re-encoding" do
      image = Image.from_url("https://example.com/render.png")

      assert Image.to_openai_content_part(image) == %{
               "type" => "image_url",
               "image_url" => %{"url" => "https://example.com/render.png"}
             }
    end

    test "requires exactly one source" do
      assert_raise ArgumentError, ~r/exactly one/i, fn -> Image.new([]) end

      assert_raise ArgumentError, ~r/exactly one/i, fn ->
        Image.new(
          url: "https://example.com/a.png",
          base64_data: "abc",
          media_type: "image/png"
        )
      end
    end

    test "requires media_type for raw base64 data" do
      assert_raise ArgumentError, ~r/media_type/, fn -> Image.new(base64_data: "abc") end
    end
  end

  describe "to_openai_content_part/1 upstream parity" do
    test "url image" do
      part = Image.new(url: "https://example.com/photo.jpg") |> Image.to_openai_content_part()

      assert part == %{
               "type" => "image_url",
               "image_url" => %{"url" => "https://example.com/photo.jpg"}
             }
    end

    test "data uri" do
      data_uri = "data:image/png;base64,#{@tiny_png_b64}"
      part = Image.new(url: data_uri) |> Image.to_openai_content_part()

      assert part["image_url"]["url"] == data_uri
    end

    test "path image embeds bytes as data uri" do
      path = write_tmp_image(".png", @tiny_png_bytes)
      image = Image.new(path: path)
      part = Image.to_openai_content_part(image)

      assert part["type"] == "image_url"
      url = part["image_url"]["url"]
      assert String.starts_with?(url, "data:image/png;base64,")

      encoded = url |> String.split(",", parts: 2) |> List.last()
      assert Base.decode64!(encoded) == @tiny_png_bytes
    end

    test "path jpeg media type inferred" do
      path = write_tmp_image(".jpg", "not-really-a-jpeg")
      part = Image.new(path: path) |> Image.to_openai_content_part()

      assert String.starts_with?(part["image_url"]["url"], "data:image/jpeg;base64,")
    end

    test "path explicit media type override" do
      path = write_tmp_image(".png", @tiny_png_bytes)
      part = Image.new(path: path, media_type: "image/webp") |> Image.to_openai_content_part()

      assert String.starts_with?(part["image_url"]["url"], "data:image/webp;base64,")
    end

    test "base64 image" do
      part =
        Image.new(base64_data: @tiny_png_b64, media_type: "image/png")
        |> Image.to_openai_content_part()

      assert part == %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/png;base64,#{@tiny_png_b64}"}
             }
    end

    test "content part schema shape" do
      for image <- [
            Image.new(url: "https://x.com/a.png"),
            Image.new(base64_data: @tiny_png_b64, media_type: "image/png")
          ] do
        part = Image.to_openai_content_part(image)

        assert MapSet.new(Map.keys(part)) == MapSet.new(["type", "image_url"])
        assert part["type"] == "image_url"
        assert is_map(part["image_url"])
        assert is_binary(part["image_url"]["url"])
      end
    end
  end

  describe "prompt renderer image parity" do
    test "no images returns string" do
      prompt = render_prompt([%{"Input" => "hello", "Score" => 0.5}])

      assert is_binary(prompt)
      assert prompt =~ "hello"
    end

    test "with images returns messages list" do
      image = Image.new(base64_data: @tiny_png_b64, media_type: "image/png")
      prompt = render_prompt([%{"Input" => "hello", "Visual" => image}])

      assert [%{"role" => "user", "content" => content}] = prompt

      assert [%{"type" => "text", "text" => text}, %{"type" => "image_url"} = image_part] =
               content

      assert text =~ "Do the thing."
      assert text =~ "[IMAGE-1"
      assert String.starts_with?(image_part["image_url"]["url"], "data:image/png;base64,")
    end

    test "multiple images" do
      image_1 = Image.new(url: "https://example.com/a.png")
      image_2 = Image.new(base64_data: @tiny_png_b64, media_type: "image/png")

      prompt =
        render_prompt([
          %{"Input" => "x", "Chart" => image_1},
          %{"Input" => "y", "Plot" => image_2}
        ])

      assert [%{"content" => [text_part, image_part_1, image_part_2]}] = prompt
      assert text_part["text"] =~ "[IMAGE-1"
      assert text_part["text"] =~ "[IMAGE-2"
      assert image_part_1["type"] == "image_url"
      assert image_part_2["type"] == "image_url"
    end

    test "nested images" do
      image = Image.new(base64_data: @tiny_png_b64, media_type: "image/png")
      prompt = render_prompt([%{"Data" => %{"nested" => %{"deep" => image}}}])

      assert [%{"content" => [text_part, %{"type" => "image_url"}]}] = prompt
      assert text_part["text"] =~ "[IMAGE-1"
    end

    test "images in list values" do
      image = Image.new(base64_data: @tiny_png_b64, media_type: "image/png")
      prompt = render_prompt([%{"Frames" => [image, image]}])

      assert [%{"content" => [text_part, image_part_1, image_part_2]}] = prompt
      assert text_part["text"] =~ "[IMAGE-1"
      assert text_part["text"] =~ "[IMAGE-2"
      assert image_part_1["type"] == "image_url"
      assert image_part_2["type"] == "image_url"
    end

    test "image count header" do
      image = Image.new(url: "https://example.com/x.png")
      prompt = render_prompt([%{"A" => image}])

      assert [%{"content" => [%{"text" => text}, %{"type" => "image_url"}]}] = prompt
      assert text =~ "1 image(s)"
    end

    test "mixed images and text" do
      image = Image.new(base64_data: @tiny_png_b64, media_type: "image/png")
      prompt = render_prompt([%{"Feedback" => "too dark", "Screenshot" => image, "Score" => 0.3}])

      assert [%{"content" => [%{"text" => text}, %{"type" => "image_url"}]}] = prompt
      assert text =~ "too dark"
      assert text =~ "0.3"
    end
  end

  describe "optimize_anything image integration parity" do
    test "image reaches reflection lm" do
      parent = self()
      image = Image.new(base64_data: @tiny_png_b64, media_type: "image/png")

      reflection_lm = fn prompt ->
        send(parent, {:reflection_prompt, prompt})
        "```\nimproved prompt\n```"
      end

      evaluator = fn candidate ->
        score = if String.contains?(candidate["instructions"], "improved"), do: 1.0, else: 0.5

        {score,
         %{
           "Input" => "draw a red circle",
           "Rendering" => image,
           "Feedback" => "Circle is blue instead of red"
         }}
      end

      assert {:ok, _result} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: %{"instructions" => "draw shapes"},
                 evaluator: evaluator,
                 engine: %{max_metric_calls: 2, cache_evaluation: false},
                 reflection: %{
                   reflection_lm: reflection_lm,
                   reflection_minibatch_size: 1,
                   skip_perfect_score: false
                 }
               )

      prompts = collect_reflection_prompts()
      multimodal_prompt = Enum.find(prompts, &is_list/1)
      assert [%{"role" => "user", "content" => content}] = multimodal_prompt
      text_part = Enum.find(content, &(&1["type"] == "text"))
      image_part = Enum.find(content, &(&1["type"] == "image_url"))

      assert text_part["text"] =~ "draw shapes"
      assert text_part["text"] =~ "Circle is blue"
      assert text_part["text"] =~ "[IMAGE-"
      assert String.starts_with?(image_part["image_url"]["url"], "data:image/png;base64,")
    end

    test "no image backward compat" do
      parent = self()

      reflection_lm = fn prompt ->
        send(parent, {:reflection_prompt, prompt})
        "```\nimproved\n```"
      end

      evaluator = fn _candidate -> {0.5, %{"Feedback" => "needs work"}} end

      assert {:ok, _result} =
               OptimizeAnything.optimize_anything(
                 seed_candidate: %{"instructions" => "do stuff"},
                 evaluator: evaluator,
                 engine: %{max_metric_calls: 2, cache_evaluation: false},
                 reflection: %{
                   reflection_lm: reflection_lm,
                   reflection_minibatch_size: 1,
                   skip_perfect_score: false
                 }
               )

      assert collect_reflection_prompts() |> Enum.all?(&is_binary/1)
    end
  end

  defp render_prompt(dataset) do
    llm = fn _prompt -> "```\nimproved\n```" end

    proposal =
      InstructionProposal.new(
        llm: llm,
        template: "Instruction:\n<curr_param>\n\nFeedback:\n<side_info>"
      )

    assert {:ok, _new_text, prompt, _raw} =
             InstructionProposal.propose_with_metadata(
               proposal,
               "instructions",
               "Do the thing.",
               dataset
             )

    prompt
  end

  defp write_tmp_image(suffix, bytes) do
    path =
      Path.join(System.tmp_dir!(), "gepa-image-#{System.unique_integer([:positive])}#{suffix}")

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp collect_reflection_prompts(acc \\ []) do
    receive do
      {:reflection_prompt, prompt} -> collect_reflection_prompts([prompt | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
