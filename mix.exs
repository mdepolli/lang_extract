defmodule LangExtract.MixProject do
  use Mix.Project

  @version "0.6.0"
  @source_url "https://github.com/mdepolli/lang_extract"

  def project do
    [
      app: :lang_extract,
      version: @version,
      elixir: "~> 1.15",
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

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Core. JSON is the wire format (0.6.0+); yaml_elixir stays for
      # decode tolerance only — YAML responses are still accepted.
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},

      # HTTP client
      {:req, "~> 0.6"},

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
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        Core: [
          LangExtract,
          LangExtract.Client,
          LangExtract.Extraction,
          LangExtract.Template,
          LangExtract.Template.Example,
          LangExtract.WireFormat
        ],
        Prompt: [
          LangExtract.Prompt.Builder,
          LangExtract.Prompt.Validator,
          LangExtract.Prompt.Validator.Issue,
          LangExtract.Prompt.Validator.ValidationError
        ],
        Pipeline: [
          LangExtract.Orchestrator,
          LangExtract.Chunker,
          LangExtract.Chunker.Chunk,
          LangExtract.Pipeline,
          LangExtract.Pipeline.Parser,
          LangExtract.Pipeline.ChunkError
        ],
        Alignment: [
          LangExtract.Alignment.Aligner,
          LangExtract.Alignment.Span,
          LangExtract.Alignment.Token,
          LangExtract.Alignment.Tokenizer
        ],
        Providers: [
          LangExtract.Provider,
          LangExtract.Provider.Claude,
          LangExtract.Provider.OpenAI,
          LangExtract.Provider.Gemini
        ],
        Serialization: [LangExtract.Serializer]
      ]
    ]
  end
end
