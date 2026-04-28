defmodule GEPA.OptimizeAnythingParityExpansionTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.OptimizeAnything
  alias GEPA.OptimizeAnything.{Config, EngineConfig, ReflectionConfig, TrackingConfig}

  test "config structs accept upstream-style expanded engine, reflection, and tracking fields" do
    config =
      Config.new(
        seed_candidate: "seed",
        evaluator: fn _candidate -> 1.0 end,
        engine: %{
          max_metric_calls: 3,
          max_reflection_cost: 1.5,
          display_progress_bar: true,
          capture_stdio: true,
          candidate_selection_strategy: :current_best,
          val_evaluation_policy: :full_eval,
          acceptance_criterion: :improvement_or_equal,
          num_parallel_proposals: "auto"
        },
        reflection: %{
          reflection_minibatch_size: 1,
          batch_sampler: :epoch_shuffled,
          module_selector: :all,
          reflection_lm_kwargs: %{temperature: 0.1},
          reflection_prompt_template: "Current:\n<curr_param>\nData:\n<side_info>"
        },
        tracking: %{
          wandb_step_metric: "gepa/iteration",
          key_prefix: "gepa/test/"
        }
      )

    assert %EngineConfig{max_reflection_cost: 1.5, capture_stdio: true} = config.engine
    assert config.engine.candidate_selection_strategy == :current_best

    assert %ReflectionConfig{module_selector: :all, reflection_minibatch_size: 1} =
             config.reflection

    assert config.reflection.reflection_lm_kwargs == %{temperature: 0.1}

    assert %TrackingConfig{wandb_step_metric: "gepa/iteration", key_prefix: "gepa/test/"} =
             config.tracking
  end

  test "seedless mode asks the reflection LLM for the initial candidate and unwraps string results" do
    passthrough_proposer = fn candidate, _dataset, components ->
      Map.new(components, &{&1, candidate[&1]})
    end

    {:ok, result} =
      OptimizeAnything.optimize_anything(
        evaluator: fn candidate -> if candidate == "generated seed", do: 1.0, else: 0.0 end,
        objective: "Generate a useful string.",
        engine: %{max_metric_calls: 1, reflection_minibatch_size: 1},
        reflection: %{
          reflection_lm: fn _prompt -> "```text\ngenerated seed\n```" end,
          custom_candidate_proposer: passthrough_proposer,
          skip_perfect_score: false
        }
      )

    assert GEPA.Result.best_candidate(result) == "generated seed"
    assert Enum.all?(result.candidates, &is_binary/1)
  end

  test "objective/background and custom reflection templates are mutually exclusive at runtime" do
    assert {:error, %ArgumentError{message: message}} =
             OptimizeAnything.optimize_anything(
               seed_candidate: "seed",
               evaluator: fn _candidate -> 1.0 end,
               objective: "maximize score",
               engine: %{max_metric_calls: 1, reflection_minibatch_size: 1},
               reflection: %{
                 reflection_lm: fn _prompt -> "unused" end,
                 reflection_prompt_template: "Current <curr_param>\nSide <side_info>",
                 custom_candidate_proposer: fn candidate, _dataset, components ->
                   Map.new(components, &{&1, candidate[&1]})
                 end
               }
             )

    assert message =~ "objective/background"
  end
end
