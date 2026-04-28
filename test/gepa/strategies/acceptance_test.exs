defmodule GEPA.Strategies.AcceptanceTest do
  use ExUnit.Case, async: true

  alias GEPA.CandidateProposal
  alias GEPA.CandidateProposal.SubsampleEvaluation
  alias GEPA.State
  alias GEPA.Strategies.Acceptance

  defmodule ObjectiveImprovementAcceptance do
    defstruct [:objective]

    def should_accept(%__MODULE__{objective: objective}, proposal, _state) do
      with %SubsampleEvaluation{objective_scores: before_scores} when is_list(before_scores) <-
             proposal.eval_before,
           %SubsampleEvaluation{objective_scores: after_scores} when is_list(after_scores) <-
             proposal.eval_after do
        new_obj = Enum.sum(Enum.map(after_scores, &Map.get(&1, objective, 0.0)))
        old_obj = Enum.sum(Enum.map(before_scores, &Map.get(&1, objective, 0.0)))
        new_obj > old_obj
      else
        _ -> false
      end
    end
  end

  defmodule RejectEmptyOutputs do
    def should_accept(proposal, _state) do
      case proposal.eval_after do
        %SubsampleEvaluation{outputs: outputs} -> Enum.all?(outputs, &(&1 != ""))
        _ -> false
      end
    end
  end

  defmodule RejectIfNoTrajectories do
    def should_accept(proposal, _state) do
      case proposal.eval_before do
        %SubsampleEvaluation{trajectories: trajectories}
        when is_list(trajectories) and trajectories != [] ->
          Enum.sum(proposal.subsample_scores_after || []) >
            Enum.sum(proposal.subsample_scores_before || [])

        _ ->
          false
      end
    end
  end

  defmodule AcceptOnlyEarlyIterations do
    defstruct [:lenient_until]

    def should_accept(%__MODULE__{lenient_until: lenient_until}, proposal, %State{} = state) do
      old_sum = Enum.sum(proposal.subsample_scores_before || [])
      new_sum = Enum.sum(proposal.subsample_scores_after || [])

      if state.i < lenient_until do
        new_sum >= old_sum
      else
        new_sum > old_sum
      end
    end
  end

  describe "strict improvement acceptance" do
    test "accepts strict improvement" do
      assert Acceptance.should_accept?(
               proposal([0.5, 0.3], [0.6, 0.4]),
               :strict_improvement,
               minimal_state()
             )
    end

    test "rejects equal scores" do
      refute Acceptance.should_accept?(
               proposal([0.5, 0.3], [0.5, 0.3]),
               :strict_improvement,
               minimal_state()
             )
    end

    test "rejects worse scores" do
      refute Acceptance.should_accept?(
               proposal([0.5, 0.3], [0.4, 0.2]),
               :strict_improvement,
               minimal_state()
             )
    end

    test "handles nil scores" do
      proposal = %CandidateProposal{
        candidate: %{"instructions" => "test"},
        parent_program_ids: [0],
        tag: "reflective_mutation",
        subsample_scores_before: nil,
        subsample_scores_after: nil
      }

      refute Acceptance.should_accept?(proposal, :strict_improvement, minimal_state())
    end

    test "accepts marginal improvement" do
      assert Acceptance.should_accept?(
               proposal([0.5, 0.3], [0.5, 0.3001]),
               :strict_improvement,
               minimal_state()
             )
    end
  end

  describe "improvement or equal acceptance" do
    test "accepts improvement" do
      assert Acceptance.should_accept?(
               proposal([0.5, 0.3], [0.6, 0.4]),
               :improvement_or_equal,
               minimal_state()
             )
    end

    test "accepts equal scores" do
      assert Acceptance.should_accept?(
               proposal([0.5, 0.3], [0.5, 0.3]),
               :improvement_or_equal,
               minimal_state()
             )
    end

    test "rejects worse scores" do
      refute Acceptance.should_accept?(
               proposal([0.5, 0.3], [0.4, 0.2]),
               :improvement_or_equal,
               minimal_state()
             )
    end
  end

  describe "custom acceptance criteria" do
    test "strict and improvement-or-equal criteria conform to acceptance callback shape" do
      assert Acceptance.should_accept?(
               proposal([0.5], [0.6]),
               GEPA.Strategies.Acceptance.StrictImprovement,
               minimal_state()
             )

      assert Acceptance.should_accept?(
               proposal([0.5], [0.5]),
               GEPA.Strategies.Acceptance.ImprovementOrEqual,
               minimal_state()
             )
    end

    test "custom criterion can use objective scores" do
      proposal = %CandidateProposal{
        candidate: %{"instructions" => "test"},
        parent_program_ids: [0],
        tag: "reflective_mutation",
        subsample_scores_before: [0.5],
        subsample_scores_after: [0.5],
        eval_before: %SubsampleEvaluation{
          scores: [0.5],
          outputs: ["old"],
          objective_scores: [%{"accuracy" => 0.4, "speed" => 0.9}]
        },
        eval_after: %SubsampleEvaluation{
          scores: [0.5],
          outputs: ["new"],
          objective_scores: [%{"accuracy" => 0.6, "speed" => 0.7}]
        }
      }

      assert Acceptance.should_accept?(
               proposal,
               %ObjectiveImprovementAcceptance{objective: "accuracy"},
               minimal_state()
             )
    end

    test "custom criterion can inspect outputs" do
      proposal = %CandidateProposal{
        candidate: %{"instructions" => "test"},
        parent_program_ids: [0],
        tag: "reflective_mutation",
        subsample_scores_before: [0.5],
        subsample_scores_after: [1.0],
        eval_before: %SubsampleEvaluation{scores: [0.5], outputs: ["ok"]},
        eval_after: %SubsampleEvaluation{scores: [1.0], outputs: [""]}
      }

      refute Acceptance.should_accept?(proposal, RejectEmptyOutputs, minimal_state())
    end

    test "custom criterion can inspect trajectories" do
      proposal_with_trace = %CandidateProposal{
        candidate: %{"instructions" => "test"},
        parent_program_ids: [0],
        tag: "reflective_mutation",
        subsample_scores_before: [0.5],
        subsample_scores_after: [0.6],
        eval_before: %SubsampleEvaluation{
          scores: [0.5],
          outputs: ["ok"],
          trajectories: ["trace1"]
        },
        eval_after: %SubsampleEvaluation{scores: [0.6], outputs: ["ok"]}
      }

      proposal_without_trace = %{
        proposal_with_trace
        | eval_before: %SubsampleEvaluation{
            scores: [0.5],
            outputs: ["ok"],
            trajectories: nil
          }
      }

      assert Acceptance.should_accept?(
               proposal_with_trace,
               RejectIfNoTrajectories,
               minimal_state()
             )

      refute Acceptance.should_accept?(
               proposal_without_trace,
               RejectIfNoTrajectories,
               minimal_state()
             )
    end

    test "custom criterion can use state" do
      proposal = proposal([0.5], [0.5])
      criterion = %AcceptOnlyEarlyIterations{lenient_until: 5}

      assert Acceptance.should_accept?(proposal, criterion, %{minimal_state() | i: 0})
      refute Acceptance.should_accept?(proposal, criterion, %{minimal_state() | i: 10})
    end
  end

  describe "SubsampleEvaluation" do
    test "defaults optional fields" do
      evaluation = %SubsampleEvaluation{scores: [0.5]}

      assert evaluation.scores == [0.5]
      assert evaluation.outputs == []
      assert evaluation.objective_scores == nil
      assert evaluation.trajectories == nil
    end

    test "supports full construction" do
      evaluation = %SubsampleEvaluation{
        scores: [0.5, 0.7],
        outputs: ["a", "b"],
        objective_scores: [%{"acc" => 0.5}, %{"acc" => 0.7}],
        trajectories: ["t1", "t2"]
      }

      assert evaluation.scores == [0.5, 0.7]
      assert evaluation.outputs == ["a", "b"]
      assert evaluation.objective_scores == [%{"acc" => 0.5}, %{"acc" => 0.7}]
      assert evaluation.trajectories == ["t1", "t2"]
    end
  end

  defp proposal(scores_before, scores_after) do
    %CandidateProposal{
      candidate: %{"instructions" => "test"},
      parent_program_ids: [0],
      tag: "reflective_mutation",
      subsample_scores_before: scores_before,
      subsample_scores_after: scores_after,
      eval_before: %SubsampleEvaluation{
        scores: scores_before,
        outputs: List.duplicate("out", length(scores_before))
      },
      eval_after: %SubsampleEvaluation{
        scores: scores_after,
        outputs: List.duplicate("out", length(scores_after))
      }
    }
  end

  defp minimal_state do
    %State{
      program_candidates: [%{"instructions" => "test"}],
      parent_program_for_candidate: [[nil]],
      prog_candidate_val_subscores: [%{0 => 0.5}],
      pareto_front_valset: %{0 => 0.5},
      program_at_pareto_front_valset: %{0 => MapSet.new([0])},
      list_of_named_predictors: ["instructions"]
    }
  end
end
