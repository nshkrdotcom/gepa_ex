defmodule GEPA.CandidateProposalTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  describe "new/1" do
    test "creates proposal with required fields" do
      proposal = %GEPA.CandidateProposal{
        candidate: %{"instruction" => "new instruction"},
        parent_program_ids: [0],
        tag: "reflective_mutation"
      }

      assert proposal.candidate == %{"instruction" => "new instruction"}
      assert proposal.parent_program_ids == [0]
      assert proposal.tag == "reflective_mutation"
      assert proposal.metadata == %{}
    end

    test "creates proposal with all fields" do
      proposal = %GEPA.CandidateProposal{
        candidate: %{"comp1" => "text1"},
        parent_program_ids: [1, 2],
        subsample_indices: [0, 1, 2],
        subsample_scores_before: [0.7, 0.8],
        subsample_scores_after: [0.9, 0.95],
        tag: "merge",
        metadata: %{ancestor: 0}
      }

      assert proposal.subsample_indices == [0, 1, 2]
      assert proposal.subsample_scores_before == [0.7, 0.8]
      assert proposal.subsample_scores_after == [0.9, 0.95]
      assert proposal.metadata == %{ancestor: 0}
    end
  end

  describe "should_accept?/1" do
    test "returns true when new scores sum higher than old scores" do
      proposal = %GEPA.CandidateProposal{
        candidate: %{},
        parent_program_ids: [0],
        tag: "test",
        subsample_scores_before: [0.5, 0.6],
        subsample_scores_after: [0.7, 0.8]
      }

      assert GEPA.CandidateProposal.should_accept?(proposal)
    end

    test "returns false when new scores sum equal to old scores" do
      proposal = %GEPA.CandidateProposal{
        candidate: %{},
        parent_program_ids: [0],
        tag: "test",
        subsample_scores_before: [0.5, 0.5],
        subsample_scores_after: [0.6, 0.4]
      }

      refute GEPA.CandidateProposal.should_accept?(proposal)
    end

    test "returns false when new scores sum lower than old scores" do
      proposal = %GEPA.CandidateProposal{
        candidate: %{},
        parent_program_ids: [0],
        tag: "test",
        subsample_scores_before: [0.8, 0.9],
        subsample_scores_after: [0.5, 0.6]
      }

      refute GEPA.CandidateProposal.should_accept?(proposal)
    end

    test "returns false when scores are nil" do
      proposal = %GEPA.CandidateProposal{
        candidate: %{},
        parent_program_ids: [0],
        tag: "test"
      }

      refute GEPA.CandidateProposal.should_accept?(proposal)
    end

    test "supports improvement-or-equal acceptance criterion" do
      proposal = %GEPA.CandidateProposal{
        candidate: %{},
        parent_program_ids: [0],
        tag: "test",
        subsample_scores_before: [0.5, 0.5],
        subsample_scores_after: [0.6, 0.4]
      }

      assert GEPA.CandidateProposal.should_accept?(proposal, :improvement_or_equal, %GEPA.State{
               program_candidates: [%{}],
               parent_program_for_candidate: [[nil]],
               prog_candidate_val_subscores: [%{}],
               pareto_front_valset: %{},
               program_at_pareto_front_valset: %{},
               list_of_named_predictors: []
             })
    end

    test "supports custom acceptance functions" do
      proposal = %GEPA.CandidateProposal{
        candidate: %{},
        parent_program_ids: [0],
        tag: "test",
        subsample_scores_before: [1.0],
        subsample_scores_after: [0.0]
      }

      criterion = fn candidate_proposal, _state ->
        candidate_proposal.tag == "test"
      end

      assert GEPA.CandidateProposal.should_accept?(proposal, criterion, nil)
    end
  end
end
