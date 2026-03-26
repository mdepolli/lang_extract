defmodule LangExtract do
  @moduledoc """
  Extracts structured data from text with source grounding.
  Maps extraction strings back to exact byte positions in source text.
  """

  alias LangExtract.Alignment.{Aligner, Span}
  alias LangExtract.{Client, FormatHandler, Orchestrator, Parser, Prompt, Provider}

  @doc """
  Aligns extraction strings to byte spans in source text.

  Returns a list of `%LangExtract.Alignment.Span{}` structs, one per extraction.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      iex> LangExtract.align("the quick brown fox", ["quick brown"])
      [%LangExtract.Alignment.Span{text: "quick brown", byte_start: 4, byte_end: 15, status: :exact}]

  """
  @spec align(String.t(), [String.t()], keyword()) :: [LangExtract.Alignment.Span.t()]
  def align(source, extractions, opts \\ []) do
    Aligner.align(source, extractions, opts)
  end

  @doc """
  Parses LLM output, aligns extractions against source text, and returns
  enriched spans with class and attributes.

  Accepts both canonical (`{"extractions": [...]}`) and dynamic-key format
  (where each entry uses the class name as the key). Strips markdown fences
  and think tags before parsing.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      iex> json = ~s({"extractions": [{"class": "word", "text": "fox"}]})
      iex> {:ok, [span]} = LangExtract.extract("the quick brown fox", json)
      iex> span.status
      :exact

  """
  @spec extract(String.t(), String.t(), keyword()) ::
          {:ok, [Span.t()]}
          | {:error, {:invalid_format, String.t()} | :invalid_json | :missing_extractions}
  def extract(source, raw_llm_output, opts \\ []) do
    with {:ok, normalized} <- FormatHandler.normalize(raw_llm_output),
         {:ok, extractions} <- Parser.parse(normalized) do
      texts = Enum.map(extractions, & &1.text)
      spans = Aligner.align(source, texts, opts)

      enriched =
        Enum.zip_with(extractions, spans, fn extraction, %Span{} = span ->
          %Span{span | class: extraction.class, attributes: extraction.attributes}
        end)

      {:ok, enriched}
    end
  end

  @doc """
  Runs the full extraction pipeline: prompt → LLM → parse → align.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      client = LangExtract.new(:claude, api_key: "sk-...")
      template = %LangExtract.Prompt.Template{description: "Extract entities."}
      {:ok, spans} = LangExtract.run(client, "the quick brown fox", template)

  """
  @spec run(Client.t(), String.t(), Prompt.Template.t(), keyword()) ::
          {:ok, [Span.t()]} | {:error, term()}
  def run(%Client{} = client, source, %Prompt.Template{} = template, opts \\ []) do
    Orchestrator.run(client, source, template, opts)
  end

  @doc """
  Creates a configured LLM client for extraction.

  ## Examples

      client = LangExtract.new(:claude, api_key: "sk-...")
      client = LangExtract.new(:openai, api_key: "sk-...", model: "gpt-4o")
      client = LangExtract.new(:gemini, api_key: "gm-...")

  """
  @spec new(atom(), keyword()) :: Client.t()
  def new(provider, opts \\ []) do
    module = resolve_provider(provider)
    %Client{provider: module, options: opts}
  end

  defp resolve_provider(:claude), do: Provider.Claude
  defp resolve_provider(:openai), do: Provider.OpenAI
  defp resolve_provider(:gemini), do: Provider.Gemini

  defp resolve_provider(other) do
    raise ArgumentError,
          "unknown provider: #{inspect(other)}. Expected :claude, :openai, or :gemini"
  end
end
