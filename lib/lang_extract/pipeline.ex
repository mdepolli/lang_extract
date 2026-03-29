defmodule LangExtract.Pipeline do
  @moduledoc false

  alias LangExtract.Alignment.{Aligner, Span}
  alias LangExtract.{FormatHandler, Parser}

  @spec extract(String.t(), String.t(), keyword()) ::
          {:ok, [Span.t()]}
          | {:error, {:invalid_format, String.t()} | :missing_extractions}
  def extract(source, raw_llm_output, opts) do
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
end
