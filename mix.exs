defmodule LangExtract.MixProject do
  use Mix.Project

  def project do
    [
      app: :lang_extract,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:httpower, "~> 0.20"},
      {:finch, "~> 0.19"}
    ]
  end
end
