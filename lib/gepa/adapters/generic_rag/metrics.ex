defmodule GEPA.Adapters.GenericRAG.Metrics do
  @moduledoc """
  Deterministic retrieval and generation metrics for the Generic RAG adapter.
  """

  @spec evaluate_retrieval([map()], [term()]) :: map()
  def evaluate_retrieval(retrieved_docs, relevant_doc_ids) do
    relevant = MapSet.new(Enum.map(relevant_doc_ids || [], &to_string/1))
    retrieved = Enum.map(retrieved_docs || [], &doc_id/1)
    retrieved_set = MapSet.new(Enum.map(retrieved, &to_string/1))
    hits = MapSet.size(MapSet.intersection(retrieved_set, relevant))

    precision = safe_div(hits, length(retrieved))
    recall = safe_div(hits, MapSet.size(relevant))

    f1 =
      if precision + recall == 0.0, do: 0.0, else: 2.0 * precision * recall / (precision + recall)

    mrr =
      retrieved
      |> Enum.with_index(1)
      |> Enum.find_value(0.0, fn {id, rank} ->
        if MapSet.member?(relevant, to_string(id)), do: 1.0 / rank, else: nil
      end)

    %{
      "retrieval_precision" => precision,
      "retrieval_recall" => recall,
      "retrieval_f1" => f1,
      "retrieval_mrr" => mrr
    }
  end

  @spec evaluate_generation(String.t(), String.t(), String.t()) :: map()
  def evaluate_generation(generated_answer, ground_truth, context \\ "") do
    %{
      "exact_match" => if(exact_match?(generated_answer, ground_truth), do: 1.0, else: 0.0),
      "token_f1" => token_f1(generated_answer, ground_truth),
      "bleu_score" => simple_bleu(generated_answer, ground_truth),
      "answer_relevance" => answer_relevance(generated_answer, context),
      "faithfulness" => faithfulness(generated_answer, context),
      "answer_confidence" => answer_confidence(generated_answer)
    }
  end

  @spec combined_rag_score(map(), map(), keyword()) :: float()
  def combined_rag_score(retrieval_metrics, generation_metrics, opts \\ []) do
    retrieval_weight = Keyword.get(opts, :retrieval_weight, 0.3) * 1.0
    generation_weight = Keyword.get(opts, :generation_weight, 0.7) * 1.0

    retrieval_score = Map.get(retrieval_metrics, "retrieval_f1", 0.0)

    generation_score =
      0.4 * Map.get(generation_metrics, "token_f1", 0.0) +
        0.3 * Map.get(generation_metrics, "answer_relevance", 0.0) +
        0.3 * Map.get(generation_metrics, "faithfulness", 0.0)

    retrieval_weight * retrieval_score + generation_weight * generation_score
  end

  def exact_match?(generated, truth) do
    normalize_text(generated) == normalize_text(truth)
  end

  def token_f1(generated, truth) do
    generated_tokens = token_list(generated)
    truth_tokens = token_list(truth)

    cond do
      generated_tokens == [] and truth_tokens == [] ->
        1.0

      generated_tokens == [] or truth_tokens == [] ->
        0.0

      true ->
        generated_counts = Enum.frequencies(generated_tokens)
        truth_counts = Enum.frequencies(truth_tokens)

        common =
          Enum.reduce(generated_counts, 0, fn {token, count}, acc ->
            acc + min(count, Map.get(truth_counts, token, 0))
          end)

        precision = safe_div(common, length(generated_tokens))
        recall = safe_div(common, length(truth_tokens))

        if precision + recall == 0.0,
          do: 0.0,
          else: 2.0 * precision * recall / (precision + recall)
    end
  end

  def simple_bleu(generated, truth) do
    generated_tokens = token_list(generated)
    truth_tokens = MapSet.new(token_list(truth))

    if generated_tokens == [] do
      0.0
    else
      hits = Enum.count(generated_tokens, &MapSet.member?(truth_tokens, &1))
      hits / length(generated_tokens)
    end
  end

  def answer_relevance(answer, context) do
    answer_tokens = MapSet.new(token_list(answer))
    context_tokens = MapSet.new(token_list(context))

    if MapSet.size(answer_tokens) == 0 do
      0.0
    else
      MapSet.size(MapSet.intersection(answer_tokens, context_tokens)) / MapSet.size(answer_tokens)
    end
  end

  def faithfulness("", _context), do: 1.0
  def faithfulness(answer, context), do: answer_relevance(answer, context)

  def answer_confidence(answer) do
    if String.trim(to_string(answer)) == "", do: 0.0, else: 1.0
  end

  @doc "Normalize text for exact-match style comparisons."
  @spec normalize_text(term()) :: String.t()
  def normalize_text(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]+/, " ")
    |> String.trim()
    |> String.split(" ", trim: true)
    |> Enum.join(" ")
  end

  @doc "Extract simple contiguous two- and three-token phrases."
  @spec extract_phrases(term()) :: MapSet.t(String.t())
  def extract_phrases(text) do
    tokens = token_list(text)

    tokens
    |> ngrams(2)
    |> Kernel.++(ngrams(tokens, 3))
    |> MapSet.new()
  end

  defp doc_id(doc) do
    metadata = Map.get(doc, :metadata) || Map.get(doc, "metadata") || %{}

    Map.get(metadata, :doc_id) || Map.get(metadata, "doc_id") || Map.get(metadata, :id) ||
      Map.get(metadata, "id") || Map.get(doc, :id) || Map.get(doc, "id")
  end

  defp token_list(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]]+/, trim: true)
  end

  defp safe_div(_num, 0), do: 0.0
  defp safe_div(num, den), do: num / den

  defp ngrams(tokens, n) when length(tokens) < n, do: []

  defp ngrams(tokens, n) do
    tokens
    |> Enum.chunk_every(n, 1, :discard)
    |> Enum.map(&Enum.join(&1, " "))
  end
end
