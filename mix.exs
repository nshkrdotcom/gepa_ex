defmodule GepaEx.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/nshkrdotcom/gepa_ex"

  def project do
    [
      app: :gepa_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "GEPA",
      source_url: @source_url,
      homepage_url: @source_url,
      description: description(),
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {GEPA.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core dependencies
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},

      # LLM integration
      {:req_llm, "~> 1.0.0-rc.7"},
      {:req, "~> 0.5.0"},

      # Development and testing
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Elixir implementation of the GEPA (Genetic-Pareto) optimizer that combines LLM-powered reflection with Pareto search to evolve text-based system components.
    """
  end

  defp docs do
    [
      main: "readme-1",
      name: "GEPA",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      assets: %{"assets" => "assets"},
      logo: "assets/gepa_ex.svg",
      extras: [
        {"README.md", title: "Overview"},
        "docs/PROJECT_SUMMARY.md",
        "docs/TECHNICAL_DESIGN.md",
        "docs/llm_adapter_design.md",
        {"examples/README.md", title: "Examples"},
        {"livebooks/README.md", title: "Livebooks"},
        "LICENSE"
      ],
      groups_for_extras: [
        Overview: ["README.md", "docs/PROJECT_SUMMARY.md"],
        "Design Docs": [
          "docs/TECHNICAL_DESIGN.md",
          "docs/llm_adapter_design.md"
        ],
        Examples: [
          "examples/README.md",
          "livebooks/README.md"
        ]
      ],
      groups_for_modules: [
        "Public API": [
          GEPA,
          GEPA.Result,
          GEPA.DataLoader,
          GEPA.Adapter
        ],
        "Engine & Workflow": [
          GEPA.Engine,
          GEPA.State,
          GEPA.Proposer,
          GEPA.Proposer.Merge,
          GEPA.Proposer.MergeUtils,
          GEPA.Proposer.Reflective,
          GEPA.CandidateProposal,
          GEPA.EvaluationBatch
        ],
        Strategies: [
          GEPA.Strategies.CandidateSelector,
          GEPA.Strategies.CandidateSelector.Pareto,
          GEPA.Strategies.CandidateSelector.CurrentBest,
          GEPA.Strategies.ComponentSelector,
          GEPA.Strategies.ComponentSelector.RoundRobin,
          GEPA.Strategies.ComponentSelector.All,
          GEPA.Strategies.EvaluationPolicy,
          GEPA.Strategies.EvaluationPolicy.Full,
          GEPA.Strategies.EvaluationPolicy.Incremental,
          GEPA.Strategies.BatchSampler,
          GEPA.Strategies.BatchSampler.Simple,
          GEPA.Strategies.BatchSampler.EpochShuffled
        ],
        "Stop Conditions": [
          GEPA.StopCondition,
          GEPA.StopCondition.Composite,
          GEPA.StopCondition.Timeout,
          GEPA.StopCondition.NoImprovement,
          GEPA.StopCondition.MaxCalls
        ],
        "LLM & Adapters": [
          GEPA.LLM,
          GEPA.LLM.ReqLLM,
          GEPA.LLM.Mock,
          GEPA.Adapters.Basic
        ],
        Utilities: [
          GEPA.Utils,
          GEPA.Utils.Pareto,
          GEPA.Types
        ],
        Application: [
          GEPA.Application
        ]
      ],
      before_closing_head_tag: fn
        :html ->
          """
          <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
          <script>
            let initialized = false;

            window.addEventListener("exdoc:loaded", () => {
              if (!initialized) {
                mermaid.initialize({
                  startOnLoad: false,
                  theme: document.body.className.includes("dark") ? "dark" : "default"
                });
                initialized = true;
              }

              let id = 0;
              for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
                const preEl = codeEl.parentElement;
                const graphDefinition = codeEl.textContent;
                const graphEl = document.createElement("div");
                const graphId = "mermaid-graph-" + id++;
                mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
                  graphEl.innerHTML = svg;
                  bindFunctions?.(graphEl);
                  preEl.insertAdjacentElement("afterend", graphEl);
                  preEl.remove();
                });
              }
            });
          </script>
          <script>
            if (location.hostname === "hexdocs.pm") {
              var script = document.createElement("script");
              script.src = "https://plausible.io/js/script.js";
              script.setAttribute("data-domain", "hexdocs.pm");
              document.head.appendChild(script);
            }
          </script>
          """

        _ ->
          ""
      end
    ]
  end

  defp package do
    [
      name: "gepa_ex",
      description: description(),
      files:
        ~w(lib mix.exs README.md LICENSE docs examples livebooks gepa/LICENSE gepa/README.md assets),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Online documentation" => "https://hexdocs.pm/gepa_ex",
        "Python reference implementation" => "https://github.com/gepa-ai/gepa"
      },
      maintainers: ["Lakshya A Agrawal"],
      exclude_patterns: [
        "priv/plts",
        ".DS_Store"
      ]
    ]
  end
end
