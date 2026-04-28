defmodule GEPA.Integration.GenericRAGEndToEndTest do
  use GEPA.SupertesterCase, isolation: :full_isolation, async: false

  alias GEPA.Adapters.GenericRAG
  alias GEPA.Adapters.GenericRAG.VectorStore.InMemory
  alias GEPA.Result
  alias GEPA.Strategies.EvaluationPolicy.Full

  @moduletag :integration
  @moduletag timeout: 20_000

  @preferred_dynamic_prompt "Based on the provided context, give a comprehensive and accurate answer to the question '{query}'. Context: {context}"
  @seed_prompt "Answer the question '{query}' using the provided context: {context}"
  @rag_config %{
    "retrieval_strategy" => "similarity",
    "top_k" => 3,
    "retrieval_weight" => 0.4,
    "generation_weight" => 0.6
  }

  defmodule BoostedRAGAdapter do
    @behaviour GEPA.Adapter

    defstruct [:inner, :preferred_prompt, :boost_amount, :counter]

    def new(opts) do
      vector_store = Keyword.fetch!(opts, :vector_store)
      rag_config = Keyword.fetch!(opts, :rag_config)
      llm = Keyword.fetch!(opts, :llm)

      %__MODULE__{
        inner: GenericRAG.new(vector_store: vector_store, llm: llm, rag_config: rag_config),
        preferred_prompt: Keyword.get(opts, :preferred_prompt),
        boost_amount: Keyword.get(opts, :boost_amount, 0.15),
        counter: Keyword.get(opts, :counter)
      }
    end

    @impl true
    def evaluate(adapter, batch, candidate, capture_traces) do
      with {:ok, result} <- GenericRAG.evaluate(adapter.inner, batch, candidate, capture_traces) do
        maybe_increment_val_calls(adapter.counter, batch)
        {:ok, maybe_boost_scores(adapter, result, candidate)}
      end
    end

    @impl true
    def make_reflective_dataset(adapter, candidate, eval_batch, components) do
      GenericRAG.make_reflective_dataset(adapter.inner, candidate, eval_batch, components)
    end

    defp maybe_boost_scores(%{preferred_prompt: nil}, result, _candidate), do: result

    defp maybe_boost_scores(adapter, result, candidate) do
      prompt = Map.get(candidate, "answer_generation", "")

      if is_binary(prompt) and String.contains?(prompt, adapter.preferred_prompt) do
        boosted_scores = Enum.map(result.scores, &min(1.0, &1 + adapter.boost_amount))

        boosted_trajectories =
          if result.trajectories do
            Enum.map(result.trajectories, &boost_trajectory(&1, adapter.boost_amount))
          end

        %{result | scores: boosted_scores, trajectories: boosted_trajectories}
      else
        result
      end
    end

    defp boost_trajectory(%{} = trajectory, amount) do
      metadata =
        trajectory
        |> Map.get(:execution_metadata, %{})
        |> Map.update(:overall_score, amount, &min(1.0, &1 + amount))

      %{trajectory | execution_metadata: metadata}
    end

    defp boost_trajectory(trajectory, _amount), do: trajectory

    defp maybe_increment_val_calls(nil, _batch), do: :ok
    defp maybe_increment_val_calls(_counter, []), do: :ok

    defp maybe_increment_val_calls(counter, [first | _]) do
      if val_item?(first) do
        Agent.update(counter, &Map.update!(&1, :val_calls, fn calls -> calls + 1 end))
      end
    end

    defp val_item?(%GenericRAG.DataInst{metadata: metadata}), do: metadata[:split] == "val"

    defp val_item?(%{metadata: metadata}),
      do: metadata[:split] == "val" or metadata["split"] == "val"

    defp val_item?(%{"metadata" => metadata}),
      do: metadata[:split] == "val" or metadata["split"] == "val"

    defp val_item?(_item), do: false
  end

  defmodule StagedRAGValLoader do
    defstruct [:pid]

    def start_link(initial_items, staged_unlocks) do
      with {:ok, pid} <-
             Agent.start_link(fn ->
               %{
                 items: initial_items,
                 staged_unlocks: staged_unlocks,
                 batches_served: 0,
                 unlocked_stages: 1
               }
             end) do
        {:ok, %__MODULE__{pid: pid}}
      end
    end

    def all_ids(%__MODULE__{pid: pid}) do
      Agent.get(pid, fn state ->
        case length(state.items) do
          0 -> []
          count -> Enum.to_list(0..(count - 1))
        end
      end)
    end

    def fetch(%__MODULE__{pid: pid}, ids) do
      Agent.get_and_update(pid, fn state ->
        state = state |> increment_batches_served() |> unlock_available_stages()
        {Enum.map(ids, &Enum.fetch!(state.items, &1)), state}
      end)
    end

    def size(loader), do: length(all_ids(loader))

    def batches_served(%__MODULE__{pid: pid}), do: Agent.get(pid, & &1.batches_served)
    def unlocked_stages(%__MODULE__{pid: pid}), do: Agent.get(pid, & &1.unlocked_stages)

    def stop(%__MODULE__{pid: pid}) do
      if Process.alive?(pid), do: Agent.stop(pid)
    end

    defp increment_batches_served(state) do
      %{state | batches_served: state.batches_served + 1}
    end

    defp unlock_available_stages(%{staged_unlocks: []} = state), do: state

    defp unlock_available_stages(%{staged_unlocks: [{threshold, items} | rest]} = state) do
      if state.batches_served >= threshold do
        state
        |> Map.update!(:items, &(&1 ++ items))
        |> Map.put(:staged_unlocks, rest)
        |> Map.update!(:unlocked_stages, &(&1 + 1))
        |> unlock_available_stages()
      else
        state
      end
    end
  end

  defmodule RoundRobinRAGPolicy do
    @behaviour GEPA.Strategies.EvaluationPolicy

    defstruct batch_size: 1

    def new(opts \\ []) do
      batch_size = Keyword.get(opts, :batch_size, 1)

      if batch_size <= 0 do
        raise ArgumentError, "batch_size must be a positive integer"
      end

      %__MODULE__{batch_size: batch_size}
    end

    @impl true
    def get_eval_batch(loader, state, target_program_idx) do
      new() |> get_eval_batch(loader, state, target_program_idx)
    end

    def get_eval_batch(policy, loader, state, _target_program_idx) do
      all_ids = GEPA.DataLoader.all_ids(loader)
      order_index = all_ids |> Enum.with_index() |> Map.new()

      all_ids
      |> Enum.sort_by(fn val_id ->
        {eval_count(state, val_id), Map.fetch!(order_index, val_id)}
      end)
      |> Enum.take(policy.batch_size)
    end

    @impl true
    def get_best_program(state) do
      state.prog_candidate_val_subscores
      |> Enum.with_index()
      |> Enum.map(fn {scores, idx} ->
        {avg, coverage} = Full.calculate_avg_and_coverage(scores)
        {idx, avg, coverage}
      end)
      |> Enum.max_by(fn {_idx, avg, coverage} -> {avg, coverage} end)
      |> elem(0)
    end

    @impl true
    def get_valset_score(program_idx, state) do
      state
      |> GEPA.State.get_program_average_val_subset(program_idx)
      |> elem(0)
    end

    defp eval_count(state, val_id) do
      Enum.count(state.prog_candidate_val_subscores, &Map.has_key?(&1, val_id))
    end
  end

  test "RAG end-to-end optimization completes with deterministic adapter and reflection" do
    adapter =
      BoostedRAGAdapter.new(
        vector_store: mock_vector_store(),
        rag_config: @rag_config,
        llm: &simple_rag_lm/1,
        preferred_prompt: @preferred_dynamic_prompt,
        boost_amount: 0.25
      )

    {:ok, result} =
      GEPA.optimize(
        seed_candidate: %{"answer_generation" => @seed_prompt},
        trainset: Enum.take(sample_ai_ml_dataset(), 2),
        valset: sample_ai_ml_dataset() |> Enum.drop(2) |> Enum.take(1),
        adapter: adapter,
        max_metric_calls: 8,
        reflection_lm: fn _prompt -> "```#{@preferred_dynamic_prompt}```" end,
        skip_perfect_score: false,
        progress: false
      )

    assert %Result{} = result
    assert is_map(result.best_candidate)
    assert is_binary(result.best_candidate["answer_generation"])
    assert result.best_candidate["answer_generation"] != ""
    assert result.total_num_evals > 0
    assert result.num_full_ds_evals > 0
    assert result.best_idx in 0..(length(result.val_aggregate_scores) - 1)

    assert Enum.at(result.val_aggregate_scores, result.best_idx) ==
             Enum.max(result.val_aggregate_scores)
  end

  test "RAG dynamic validation loader expands and round-robin policy covers all staged ids" do
    trainset = Enum.take(sample_ai_ml_dataset(), 2)
    initial_val_items = sample_ai_ml_dataset() |> Enum.drop(2) |> Enum.take(1)
    staged_val_items = sample_ai_ml_dataset() |> Enum.drop(3)

    {:ok, val_loader} =
      StagedRAGValLoader.start_link(initial_val_items, [
        {1, Enum.take(staged_val_items, 1)},
        {4, Enum.drop(staged_val_items, 1)}
      ])

    {:ok, counter} = Agent.start_link(fn -> %{val_calls: 0} end)

    on_exit(fn ->
      StagedRAGValLoader.stop(val_loader)
      if Process.alive?(counter), do: Agent.stop(counter)
    end)

    run_dir =
      Path.join(
        System.tmp_dir!(),
        "gepa-rag-dynamic-valset-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(run_dir) end)

    adapter =
      BoostedRAGAdapter.new(
        vector_store: mock_vector_store(),
        rag_config: @rag_config,
        llm: &simple_rag_lm/1,
        preferred_prompt: @preferred_dynamic_prompt,
        boost_amount: 0.25,
        counter: counter
      )

    {:ok, stage_one} =
      GEPA.optimize(
        seed_candidate: %{"answer_generation" => @seed_prompt},
        trainset: trainset,
        valset: val_loader,
        adapter: adapter,
        reflection_lm: fn _prompt -> "```#{@preferred_dynamic_prompt}```" end,
        candidate_selection_strategy: :current_best,
        max_metric_calls: 12,
        run_dir: run_dir,
        skip_perfect_score: false,
        val_evaluation_policy: RoundRobinRAGPolicy.new(batch_size: 1)
      )

    assert StagedRAGValLoader.unlocked_stages(val_loader) >= 2

    unlock_all_stages(val_loader)

    {:ok, stage_two} =
      GEPA.optimize(
        seed_candidate: stage_one.best_candidate,
        trainset: trainset,
        valset: val_loader,
        adapter: adapter,
        reflection_lm: fn _prompt -> "```#{@preferred_dynamic_prompt}```" end,
        candidate_selection_strategy: :current_best,
        max_metric_calls: 10,
        run_dir: Path.join(run_dir, "stage2"),
        skip_perfect_score: false,
        val_evaluation_policy: RoundRobinRAGPolicy.new(batch_size: 1)
      )

    covered_ids =
      stage_two.val_subscores
      |> Enum.flat_map(&Map.keys/1)
      |> MapSet.new()

    assert StagedRAGValLoader.unlocked_stages(val_loader) == 3
    assert StagedRAGValLoader.batches_served(val_loader) >= 4
    assert Agent.get(counter, & &1.val_calls) >= 3
    assert covered_ids == MapSet.new([0, 1, 2])
    assert stage_two.val_subscores != []
    assert stage_two.num_full_ds_evals >= 1
  end

  test "RAG adapter basic functionality returns bounded score for one example" do
    adapter =
      GenericRAG.new(
        vector_store: mock_vector_store(),
        llm: &simple_rag_lm/1,
        rag_config: @rag_config
      )

    example =
      %GenericRAG.DataInst{
        query: "What is machine learning?",
        ground_truth_answer: "Machine learning is a subset of AI.",
        relevant_doc_ids: ["doc_ml_basics"],
        metadata: %{category: "fundamentals"}
      }

    assert {:ok, result} =
             GenericRAG.evaluate(
               adapter,
               [example],
               %{"answer_generation" => "Answer: {query}"},
               false
             )

    assert length(result.scores) == 1
    assert is_float(hd(result.scores))
    assert hd(result.scores) >= 0.0 and hd(result.scores) <= 1.0
  end

  defp sample_ai_ml_dataset do
    [
      %GenericRAG.DataInst{
        query: "What is machine learning?",
        ground_truth_answer:
          "Machine learning is a subset of artificial intelligence that enables computers to learn and make decisions from data without being explicitly programmed.",
        relevant_doc_ids: ["doc_ml_basics", "doc_ai_overview"],
        metadata: %{category: "fundamentals", difficulty: "beginner", split: "train"}
      },
      %GenericRAG.DataInst{
        query: "Explain the difference between supervised and unsupervised learning.",
        ground_truth_answer:
          "Supervised learning uses labeled training data while unsupervised learning finds patterns in data without labels.",
        relevant_doc_ids: ["doc_supervised_learning", "doc_unsupervised_learning"],
        metadata: %{category: "learning_types", difficulty: "intermediate", split: "train"}
      },
      %GenericRAG.DataInst{
        query: "What are the key components of a neural network?",
        ground_truth_answer:
          "Key components include neurons, layers, weights, biases, and activation functions.",
        relevant_doc_ids: ["doc_neural_networks", "doc_deep_learning"],
        metadata: %{category: "neural_networks", difficulty: "intermediate", split: "val"}
      },
      %GenericRAG.DataInst{
        query: "How does gradient descent work in machine learning?",
        ground_truth_answer:
          "Gradient descent adjusts model parameters by moving toward lower cost function values.",
        relevant_doc_ids: ["doc_optimization", "doc_gradient_descent"],
        metadata: %{category: "optimization", difficulty: "advanced", split: "val"}
      },
      %GenericRAG.DataInst{
        query: "Define reinforcement learning.",
        ground_truth_answer:
          "Reinforcement learning trains agents with rewards and penalties through trial and error.",
        relevant_doc_ids: ["doc_reinforcement_learning"],
        metadata: %{category: "learning_types", difficulty: "advanced", split: "val"}
      }
    ]
  end

  defp mock_vector_store do
    InMemory.new(
      collection_name: "ai_ml_knowledge_base",
      documents: [
        %{
          id: "doc_ml_basics",
          content:
            "Machine learning is a subset of artificial intelligence that enables computers to learn from data.",
          metadata: %{doc_id: "doc_ml_basics", category: "fundamentals"}
        },
        %{
          id: "doc_ai_overview",
          content:
            "Artificial Intelligence creates systems that perform tasks requiring human intelligence.",
          metadata: %{doc_id: "doc_ai_overview", category: "fundamentals"}
        },
        %{
          id: "doc_supervised_learning",
          content: "Supervised learning uses labeled training data to map inputs to outputs.",
          metadata: %{doc_id: "doc_supervised_learning", category: "learning_types"}
        },
        %{
          id: "doc_unsupervised_learning",
          content: "Unsupervised learning finds patterns in data without labeled examples.",
          metadata: %{doc_id: "doc_unsupervised_learning", category: "learning_types"}
        },
        %{
          id: "doc_neural_networks",
          content:
            "Neural networks consist of neurons, layers, weights, biases, and activation functions.",
          metadata: %{doc_id: "doc_neural_networks", category: "neural_networks"}
        },
        %{
          id: "doc_deep_learning",
          content:
            "Deep learning uses neural networks with many layers to learn complex patterns.",
          metadata: %{doc_id: "doc_deep_learning", category: "neural_networks"}
        },
        %{
          id: "doc_optimization",
          content:
            "Optimization finds model parameters that minimize error or maximize performance.",
          metadata: %{doc_id: "doc_optimization", category: "optimization"}
        },
        %{
          id: "doc_gradient_descent",
          content:
            "Gradient descent iteratively adjusts parameters toward the steepest cost reduction.",
          metadata: %{doc_id: "doc_gradient_descent", category: "optimization"}
        },
        %{
          id: "doc_reinforcement_learning",
          content: "Reinforcement learning trains agents to maximize reward through interaction.",
          metadata: %{doc_id: "doc_reinforcement_learning", category: "learning_types"}
        }
      ]
    )
  end

  defp simple_rag_lm(prompt) do
    prompt = to_string(prompt)
    lower = String.downcase(prompt)

    cond do
      String.contains?(lower, "supervised") and String.contains?(lower, "unsupervised") ->
        "Supervised learning uses labeled data while unsupervised learning finds patterns in unlabeled data."

      String.contains?(lower, "neural network") ->
        "Neural networks consist of neurons, layers, weights, and activation functions."

      String.contains?(lower, "gradient descent") ->
        "Gradient descent optimizes model parameters by minimizing a cost function iteratively."

      String.contains?(lower, "reinforcement") ->
        "Reinforcement learning trains agents using rewards and penalties."

      String.contains?(lower, "machine learning") ->
        "Machine learning is a subset of artificial intelligence that enables computers to learn from data."

      true ->
        "This is a general AI and machine learning answer based on the provided context."
    end
  end

  defp unlock_all_stages(val_loader) do
    if StagedRAGValLoader.unlocked_stages(val_loader) < 3 do
      GEPA.DataLoader.fetch(val_loader, [0])
      unlock_all_stages(val_loader)
    else
      :ok
    end
  end
end
