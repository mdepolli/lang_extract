defmodule LangExtract.MixProject do
  use Mix.Project

  @version "0.9.0"
  @source_url "https://github.com/mdepolli/lang_extract"

  def project do
    [
      app: :lang_extract,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        ignore_modules: [
          Inspect.LangExtract.Client,
          Mix.Tasks.Benchmark.Run
        ]
      ],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "LangExtract",
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Core
      {:jason, "~> 1.4"},

      # HTTP client
      {:req, "~> 0.6.0"},

      # Observability (already transitive via Finch; explicit because we emit)
      {:telemetry, "~> 1.0"},

      # Dev/Test
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.15", only: :test}
    ]
  end

  defp description do
    """
    Extract structured data from text using LLMs with source grounding.
    Maps every extraction back to exact byte positions in the source.
    Supports Claude, OpenAI, and Gemini providers. Elixir port of google/langextract.
    """
  end

  defp package do
    [
      # Explicit list so the benchmark Mix task (which needs the local
      # benchmark/ corpus) doesn't ship in the package.
      files:
        ~w(lib/lang_extract lib/lang_extract.ex .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Marcelo De Polli"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/alignment.md",
        "guides/telemetry.md",
        "guides/production.md",
        "CHANGELOG.md"
      ],
      # Groups mirror the stability tiers (see README "Stability"): the
      # Core API group is the SemVer contract; Advanced is public but
      # best-effort; Internal carries no guarantees — docs kept for
      # maintainers and the curious.
      groups_for_modules: [
        "Core API": [
          LangExtract,
          LangExtract.ChunkError,
          LangExtract.ChunkResult,
          LangExtract.Client,
          LangExtract.Extraction,
          LangExtract.Prompt.Validator,
          LangExtract.Prompt.Validator.Issue,
          LangExtract.Prompt.Validator.ValidationError,
          LangExtract.Provider,
          LangExtract.Provider.Response,
          LangExtract.Result,
          LangExtract.Runner,
          LangExtract.Serializer,
          LangExtract.Span,
          LangExtract.Template,
          LangExtract.Template.Example
        ],
        Advanced: [
          LangExtract.Alignment.Aligner,
          LangExtract.Chunker,
          LangExtract.Chunker.Chunk,
          LangExtract.Pipeline,
          LangExtract.Prompt.Builder,
          LangExtract.WireFormat
        ],
        Providers: [
          LangExtract.Provider.Claude,
          LangExtract.Provider.OpenAI,
          LangExtract.Provider.Gemini
        ],
        Internal: [
          LangExtract.Alignment.Token,
          LangExtract.Alignment.Tokenizer,
          LangExtract.Orchestrator,
          LangExtract.Pipeline.Parser,
          LangExtract.Runner.Delivery,
          LangExtract.Runner.Limiter,
          LangExtract.Runner.Request
        ]
      ],
      # Renders ```mermaid``` fences in extras (README + guides) on HexDocs.
      # GitHub renders them natively; ExDoc needs the CDN + init hook.
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp before_closing_body_tag(:html) do
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
    """
  end

  defp before_closing_body_tag(_), do: ""
end
