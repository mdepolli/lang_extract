defmodule LangExtract do
  @moduledoc """
  Extracts structured data from text with source grounding.
  Maps extraction strings back to exact byte positions in source text.
  """

  alias LangExtract.Alignment.{Aligner, Span}
  alias LangExtract.{FormatHandler, Parser}

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
          {:ok, [Span.t()]} | {:error, :invalid_format | :invalid_json | :missing_extractions}
  def extract(source, raw_llm_output, opts \\ []) do
    with {:ok, normalized} <- FormatHandler.normalize(raw_llm_output),
         {:ok, extractions} <- Parser.parse(normalized) do
      texts = Enum.map(extractions, & &1.text)
      spans = Aligner.align(source, texts, opts)

      enriched =
        Enum.zip(extractions, spans)
        |> Enum.map(fn {extraction, %Span{} = span} ->
          %Span{span | class: extraction.class, attributes: extraction.attributes}
        end)

      {:ok, enriched}
    end
  end
end
