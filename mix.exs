defmodule LangExtract.MixProject do
  use Mix.Project

  @version "0.2.2"
  @source_url "https://github.com/mdepolli/lang_extract"

  def project do
    [
      app: :lang_extract,
      version: @version,
      elixir: "~> 1.14",
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
      # Core
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:ymlr, "~> 5.0"},

      # HTTP client
      {:req, "~> 0.5"},

      # Dev/Test
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
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
        "CHANGELOG.md"
      ]
    ]
  end
end
