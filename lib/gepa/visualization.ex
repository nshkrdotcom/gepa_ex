defmodule GEPA.Visualization do
  @moduledoc """
  Candidate-lineage visualization helpers.

  This module ports upstream GEPA's candidate tree utilities to Elixir. It can
  generate either Graphviz DOT or a self-contained HTML page from raw data,
  `GEPA.State`, or `GEPA.Result`.
  """

  alias GEPA.{Result, State}
  alias GEPA.Utils.Pareto

  @doc "Generate Graphviz DOT from a `GEPA.State` or `GEPA.Result`."
  @spec candidate_tree_dot(State.t() | Result.t()) :: String.t()
  def candidate_tree_dot(%State{} = state) do
    candidate_tree_dot_from_data(
      state.program_candidates,
      state.parent_program_for_candidate,
      aggregate_scores_from_state(state),
      state.program_at_pareto_front_valset
    )
  end

  def candidate_tree_dot(%Result{} = result) do
    candidate_tree_dot_from_data(
      result.candidates,
      result.parents,
      result.val_aggregate_scores,
      result.per_val_instance_best_candidates || %{}
    )
  end

  @doc "Generate a self-contained HTML visualization from a `GEPA.State` or `GEPA.Result`."
  @spec candidate_tree_html(State.t() | Result.t()) :: String.t()
  def candidate_tree_html(%State{} = state) do
    candidate_tree_html_from_data(
      state.program_candidates,
      state.parent_program_for_candidate,
      aggregate_scores_from_state(state),
      state.program_at_pareto_front_valset
    )
  end

  def candidate_tree_html(%Result{} = result) do
    candidate_tree_html_from_data(
      result.candidates,
      result.parents,
      result.val_aggregate_scores,
      result.per_val_instance_best_candidates || %{}
    )
  end

  @doc "Generate Graphviz DOT from raw optimization data."
  @spec candidate_tree_dot_from_data([map()], list() | map(), [number()], map()) :: String.t()
  def candidate_tree_dot_from_data(candidates, parents, val_scores, pareto_front_programs)
      when is_list(candidates) and is_list(val_scores) do
    n = length(candidates)
    best_idx = best_index(val_scores)
    dominator_ids = dominator_ids(pareto_front_programs, val_scores)

    node_lines =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {candidate, idx} ->
        score = Enum.at(val_scores, idx, 0.0)
        parent_ids = parents_for(parents, idx)
        role = node_role(idx, best_idx, dominator_ids)
        color = node_color(role)
        label = "#{idx}\\n(#{format_score(score, 2)})"
        tooltip = tooltip_for(idx, score, parent_ids, candidate, role)

        "    #{idx} [label=\"#{escape_dot(label)}\", fillcolor=#{color}, tooltip=\"#{escape_dot(tooltip)}\"] ;"
      end)

    edge_lines =
      0..max(n - 1, 0)//1
      |> Enum.flat_map(fn child ->
        parents_for(parents, child)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn parent -> "    #{parent} -> #{child};" end)
      end)

    [
      "digraph G {",
      "    rankdir=TB;",
      "    node [style=filled, shape=circle, fontsize=14, width=0.6, height=0.6];"
      | node_lines ++ edge_lines ++ ["}"]
    ]
    |> Enum.join("\n")
  end

  @html_template """
  <!DOCTYPE html>
  <html lang="en">
  <head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>GEPA Candidate Tree</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { height: 100%; width: 100%; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f8f9fa; display: flex; flex-direction: column; }
    #header { background: #fff; border-bottom: 1px solid #dee2e6; padding: 12px 20px; display: flex; align-items: center; gap: 16px; flex-shrink: 0; }
    #header h1 { font-size: 18px; font-weight: 600; color: #212529; }
    .legend { display: flex; gap: 14px; font-size: 13px; color: #495057; }
    .legend-item { display: flex; align-items: center; gap: 4px; }
    .legend-dot { width: 12px; height: 12px; border-radius: 50%; border: 1px solid #adb5bd; }
    #graph-container { flex: 1 1 auto; width: 100%; overflow: auto; padding: 20px; text-align: center; }
    #graph-container svg { width: 100%; height: 100%; }
    #tooltip { display: none; position: fixed; background: #fff; border: 1px solid #dee2e6; border-radius: 8px; padding: 14px 16px; max-width: 560px; max-height: 70vh; overflow-y: auto; box-shadow: 0 4px 16px rgba(0,0,0,0.18); z-index: 1000; font-size: 13px; line-height: 1.5; }
    #tooltip .tt-header { font-weight: 700; font-size: 15px; margin-bottom: 6px; color: #212529; }
    #tooltip .tt-meta { color: #6c757d; margin-bottom: 4px; }
    #tooltip .tt-hint { color: #adb5bd; font-size: 11px; font-style: italic; margin-bottom: 10px; }
    #tooltip .tt-comp-name { font-weight: 600; color: #495057; margin-top: 10px; border-bottom: 1px solid #e9ecef; padding-bottom: 2px; }
    #tooltip .tt-comp-text { white-space: pre-wrap; word-break: break-word; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 4px; padding: 8px 10px; margin-top: 4px; font-family: "SF Mono", SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; max-height: 200px; overflow-y: auto; }
    .role-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; margin-left: 6px; }
    .role-best { background: #00e5ff33; color: #006064; }
    .role-pareto { background: #ff980033; color: #e65100; }
    .role-seed { background: #e0e0e0; color: #424242; }
  </style>
  </head>
  <body>
  <div id="header">
    <h1>GEPA Candidate Tree</h1>
    <div class="legend">
      <div class="legend-item"><div class="legend-dot" style="background:cyan"></div> Best</div>
      <div class="legend-item"><div class="legend-dot" style="background:orange"></div> Pareto Front</div>
      <div class="legend-item"><div class="legend-dot" style="background:lightgray"></div> Other</div>
    </div>
  </div>
  <div id="graph-container"><p>Loading graph&hellip;</p></div>
  <div id="tooltip"></div>

  <script type="module">
  const NODES = __NODES_JSON__;
  const DOT = `__DOT_STRING__`;
  const nodeMap = {};
  NODES.forEach(n => { nodeMap[n.idx] = n; });
  let pinnedIdx = null;
  let hoverIdx = null;

  function esc(text) { return String(text).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }
  function renderTooltip(idx) {
    const n = nodeMap[idx];
    if (!n) return "";
    let roleBadge = "";
    if (n.role === "Best") roleBadge = '<span class="role-badge role-best">BEST</span>';
    else if (n.role === "Pareto Front") roleBadge = '<span class="role-badge role-pareto">PARETO</span>';
    else if (n.role === "Seed") roleBadge = '<span class="role-badge role-seed">SEED</span>';
    let comps = "";
    for (const [name, text] of Object.entries(n.components)) {
      comps += '<div class="tt-comp-name">' + esc(name) + '</div><div class="tt-comp-text">' + esc(text) + '</div>';
    }
    return '<div class="tt-header">Candidate ' + n.idx + roleBadge + '</div>' +
      '<div class="tt-meta">Score: <strong>' + n.score + '</strong>&nbsp;&nbsp;|&nbsp;&nbsp;Parent(s): ' + esc(n.parents) + '</div>' +
      '<div class="tt-hint">' + (pinnedIdx === idx ? 'Click node again to dismiss' : 'Click to pin &amp; scroll') + '</div>' + comps;
  }
  function positionTooltip(x, y) {
    const tt = document.getElementById("tooltip");
    let tx = x + 16, ty = y + 16;
    const r = tt.getBoundingClientRect();
    if (tx + r.width > window.innerWidth - 8) tx = x - r.width - 16;
    if (ty + r.height > window.innerHeight - 8) ty = y - r.height - 16;
    if (tx < 8) tx = 8;
    if (ty < 8) ty = 8;
    tt.style.left = tx + "px";
    tt.style.top = ty + "px";
  }
  function showTooltip(idx, x, y) {
    const tt = document.getElementById("tooltip");
    tt.innerHTML = renderTooltip(idx);
    tt.style.display = "block";
    positionTooltip(x, y);
  }
  function hideTooltip() {
    pinnedIdx = null;
    hoverIdx = null;
    document.getElementById("tooltip").style.display = "none";
  }
  document.addEventListener("mousedown", function(e) {
    const tt = document.getElementById("tooltip");
    if (pinnedIdx !== null && tt.style.display === "block" && !tt.contains(e.target) && !e.target.closest(".node")) hideTooltip();
  });
  async function render() {
    const { instance } = await import("https://cdn.jsdelivr.net/npm/@viz-js/viz@3.11.0/lib/viz-standalone.mjs");
    const viz = await instance();
    const svg = viz.renderSVGElement(DOT);
    const container = document.getElementById("graph-container");
    container.innerHTML = "";
    container.appendChild(svg);
    svg.querySelectorAll(".node").forEach(node => {
      const title = node.querySelector("title");
      if (!title) return;
      const idx = parseInt(title.textContent, 10);
      if (isNaN(idx)) return;
      title.remove();
      node.style.cursor = "pointer";
      node.addEventListener("mouseenter", e => { if (pinnedIdx === null) { hoverIdx = idx; showTooltip(idx, e.clientX, e.clientY); } });
      node.addEventListener("mousemove", e => { if (pinnedIdx === null && hoverIdx === idx) positionTooltip(e.clientX, e.clientY); });
      node.addEventListener("mouseleave", () => { if (pinnedIdx === null) { hoverIdx = null; document.getElementById("tooltip").style.display = "none"; } });
      node.addEventListener("click", e => { e.stopPropagation(); if (pinnedIdx === idx) { hideTooltip(); return; } pinnedIdx = idx; showTooltip(idx, e.clientX, e.clientY); });
    });
    svg.querySelectorAll(".edge title").forEach(t => t.remove());
    const graphTitle = svg.querySelector(":scope > title");
    if (graphTitle) graphTitle.remove();
  }
  render().catch(err => {
    document.getElementById("graph-container").innerHTML = "<p style='color:red'>Failed to render graph: " + esc(err.message) + "</p><pre>" + esc(DOT) + "</pre>";
  });
  </script>
  </body>
  </html>
  """

  @doc "Generate a self-contained HTML page from raw optimization data."
  @spec candidate_tree_html_from_data([map()], list() | map(), [number()], map()) :: String.t()
  def candidate_tree_html_from_data(candidates, parents, val_scores, pareto_front_programs) do
    best_idx = best_index(val_scores)
    dominator_ids = dominator_ids(pareto_front_programs, val_scores)

    nodes =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {candidate, idx} ->
        score = Enum.at(val_scores, idx, 0.0)
        parent_ids = parents_for(parents, idx)
        role = node_role(idx, best_idx, dominator_ids)

        %{
          idx: idx,
          score: Float.round(score * 1.0, 4),
          parents: parent_label(parent_ids),
          role: role_label(role),
          components: sorted_candidate(candidate)
        }
      end)

    dot = candidate_tree_dot_from_data(candidates, parents, val_scores, pareto_front_programs)
    nodes_json = Jason.encode!(nodes)

    @html_template
    |> String.replace("__DOT_STRING__", js_template_escape(dot))
    |> String.replace("__NODES_JSON__", nodes_json)
  end

  defp aggregate_scores_from_state(%State{} = state) do
    Enum.map(state.prog_candidate_val_subscores, fn scores ->
      if map_size(scores) == 0 do
        0.0
      else
        Enum.sum(Map.values(scores)) / map_size(scores)
      end
    end)
  end

  defp best_index([]), do: 0

  defp best_index(scores) do
    scores
    |> Enum.with_index()
    |> Enum.max_by(fn {score, _idx} -> score end, fn -> {0.0, 0} end)
    |> elem(1)
  end

  defp dominator_ids(fronts, val_scores) when is_map(fronts) do
    scores = val_scores |> Enum.with_index() |> Map.new(fn {score, idx} -> {idx, score} end)
    ids = fronts |> normalize_fronts() |> Pareto.find_dominator_programs(scores)
    Map.new(ids, &{&1, true})
  end

  defp dominator_ids(_fronts, _val_scores), do: %{}

  defp normalize_fronts(fronts) do
    Map.new(fronts, fn {key, value} ->
      set =
        cond do
          is_struct(value, MapSet) -> value
          is_list(value) -> MapSet.new(value)
          true -> MapSet.new()
        end

      {key, set}
    end)
  end

  defp parents_for(parents, idx) when is_map(parents), do: Map.get(parents, idx, [])
  defp parents_for(parents, idx) when is_list(parents), do: Enum.at(parents, idx, [])
  defp parents_for(_parents, _idx), do: []

  defp node_role(idx, best_idx, dominator_ids) do
    cond do
      idx == best_idx -> :best
      Map.has_key?(dominator_ids, idx) -> :pareto
      idx == 0 -> :seed
      true -> :other
    end
  end

  defp node_color(:best), do: "cyan"
  defp node_color(:pareto), do: "orange"
  defp node_color(_role), do: "lightgray"

  defp role_label(:best), do: "Best"
  defp role_label(:pareto), do: "Pareto Front"
  defp role_label(:seed), do: "Seed"
  defp role_label(_role), do: ""

  defp tooltip_for(idx, score, parents, candidate, role) do
    role = role_label(role)

    base = [
      "Candidate #{idx}",
      "Val Score: #{format_score(score, 4)}",
      "Parent(s): #{parent_label(parents)}"
    ]

    base = if role == "", do: base, else: base ++ ["Role: #{role}"]

    component_lines =
      candidate
      |> sorted_candidate()
      |> Enum.flat_map(fn {name, text} -> ["", "--- #{name} ---", to_string(text)] end)

    Enum.join(base ++ component_lines, "\n")
  end

  defp parent_label(parents) do
    parents = Enum.reject(List.wrap(parents), &is_nil/1)

    case parents do
      [] -> "seed"
      values -> Enum.map_join(values, ", ", &to_string/1)
    end
  end

  defp sorted_candidate(candidate) when is_map(candidate) do
    candidate
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp sorted_candidate(candidate), do: %{"candidate" => inspect(candidate)}

  defp format_score(score, decimals) when is_number(score) do
    score |> Kernel.*(1.0) |> Float.round(decimals) |> :erlang.float_to_binary(decimals: decimals)
  end

  defp format_score(score, _decimals), do: to_string(score)

  defp escape_dot(text) do
    text
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp js_template_escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
    |> String.replace("${", "\\${")
  end
end
