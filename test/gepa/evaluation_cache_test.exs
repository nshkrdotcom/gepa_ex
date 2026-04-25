defmodule GEPA.EvaluationCacheTest do
  use GEPA.SupertesterCase, isolation: :full_isolation

  alias GEPA.EvaluationCache

  describe "cache operations" do
    test "stores and retrieves candidate/example evaluations" do
      cache = EvaluationCache.new()

      cache =
        EvaluationCache.put(cache, %{"instruction" => "seed"}, 10, "output", 0.8, %{
          "accuracy" => 0.8
        })

      assert {:ok, entry} = EvaluationCache.get(cache, %{"instruction" => "seed"}, 10)
      assert entry.output == "output"
      assert entry.score == 0.8
      assert entry.objective_scores == %{"accuracy" => 0.8}
      assert :miss = EvaluationCache.get(cache, %{"instruction" => "other"}, 10)
    end

    test "splits cached and uncached ids in requested order" do
      cache =
        EvaluationCache.new()
        |> EvaluationCache.put(%{"instruction" => "seed"}, :a, "a-out", 0.1)
        |> EvaluationCache.put(%{"instruction" => "seed"}, :c, "c-out", 0.3)

      assert {cached, uncached} =
               EvaluationCache.get_batch(cache, %{"instruction" => "seed"}, [:a, :b, :c])

      assert MapSet.new(Map.keys(cached)) == MapSet.new([:a, :c])
      assert uncached == [:b]
    end
  end
end
