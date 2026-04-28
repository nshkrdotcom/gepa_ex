defmodule GEPA.OfficialMergeSemanticsTest do
  use ExUnit.Case, async: true

  alias GEPA.CandidateProposal
  alias GEPA.Strategies.Acceptance

  test "merge acceptance compares against the better parent, not the summed parents" do
    proposal = %CandidateProposal{
      candidate: %{"instruction" => "merged"},
      parent_program_ids: [1, 2],
      tag: "merge",
      subsample_scores_before: [5.0, 3.0],
      subsample_scores_after: [2.5, 2.5]
    }

    assert Acceptance.should_accept?(proposal, fn _proposal, _state -> false end, nil)
  end

  test "merge is rejected when it underperforms the better parent" do
    proposal = %CandidateProposal{
      candidate: %{"instruction" => "merged"},
      parent_program_ids: [1, 2],
      tag: "merge",
      subsample_scores_before: [5.0, 3.0],
      subsample_scores_after: [2.0, 2.0]
    }

    refute Acceptance.should_accept?(proposal, :improvement_or_equal, nil)
  end

  test "reflective mutations still obey pluggable acceptance criteria" do
    proposal = %CandidateProposal{
      candidate: %{"instruction" => "mutated"},
      parent_program_ids: [1],
      tag: "reflective_mutation",
      subsample_scores_before: [0.5],
      subsample_scores_after: [0.5]
    }

    refute Acceptance.should_accept?(proposal, :strict_improvement, nil)
    assert Acceptance.should_accept?(proposal, :improvement_or_equal, nil)
  end
end
