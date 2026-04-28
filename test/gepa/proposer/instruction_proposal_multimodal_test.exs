defmodule GEPA.Proposer.InstructionProposalMultimodalTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.Proposer.InstructionProposal

  test "renders Image values as multimodal message content for reflection LMs" do
    parent = self()

    lm = fn prompt ->
      send(parent, {:prompt, prompt})
      "```\nimproved visual instruction\n```"
    end

    proposal = InstructionProposal.new(llm: lm)

    dataset = [
      %{
        "Inputs" => %{
          "render" => GEPA.Image.from_base64(Base.encode64("image-bytes"), "image/png")
        },
        "Generated Outputs" => "rendered output",
        "Feedback" => "The rendered artifact is too dark."
      }
    ]

    assert {:ok, "improved visual instruction"} =
             InstructionProposal.propose(proposal, "prompt", "old instruction", dataset)

    assert_receive {:prompt, [%{"role" => "user", "content" => content}]}
    assert [%{"type" => "text", "text" => text}, %{"type" => "image_url"} = image_part] = content
    assert text =~ "[IMAGE-1"
    assert text =~ "too dark"
    assert get_in(image_part, ["image_url", "url"]) =~ "data:image/png;base64,"
  end

  test "preserves text-only prompt rendering when no images are present" do
    parent = self()

    lm = fn prompt ->
      send(parent, {:prompt, prompt})
      "better"
    end

    proposal = InstructionProposal.new(llm: lm)

    assert {:ok, "better"} =
             InstructionProposal.propose(proposal, "prompt", "old", [
               %{"Inputs" => %{"question" => "Q"}, "Feedback" => "fix it"}
             ])

    assert_receive {:prompt, prompt}
    assert is_binary(prompt)
    assert prompt =~ "# Example 1"
    assert prompt =~ "fix it"
  end
end
