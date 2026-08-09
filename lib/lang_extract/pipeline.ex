defmodule LangExtract.Pipeline do
  @moduledoc """
  Extraction pipeline: normalize LLM output, parse extractions, align to source text.
  """

  alias LangExtract.Alignment.Aligner
  alias LangExtract.Pipeline.Parser
  alias LangExtract.Span
  alias LangExtract.WireFormat

  @spec extract(String.t(), String.t(), keyword()) ::
          {:ok, [Span.t()]}
          | {:error, {:invalid_format, String.t()} | :missing_extractions}
  def extract(source, raw_llm_output, opts) do
    with {:ok, normalized} <- WireFormat.normalize(raw_llm_output),
         {:ok, extractions} <- Parser.parse(normalized) do
      {:ok, enrich_spans(source, extractions, opts)}
    end
  end

  # Aligner takes bare texts; class/attributes rejoin at this boundary only.
  # The texts list never outlives enrich_spans/3.
  defp enrich_spans(source, extractions, opts) do
    texts = Enum.map(extractions, & &1.text)

    source
    |> Aligner.align(texts, opts)
    |> Enum.zip_with(extractions, fn %Span{} = span, extraction ->
      %Span{span | class: extraction.class, attributes: extraction.attributes}
    end)
  end
end
