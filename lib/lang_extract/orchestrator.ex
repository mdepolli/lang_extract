defmodule LangExtract.Orchestrator do
  @moduledoc """
  Wires the full extraction pipeline.

  Builds a prompt, calls the LLM provider, normalizes and parses the response,
  aligns extractions to source text, and returns enriched spans.
  """

  alias LangExtract.{
    Alignment.Aligner,
    Alignment.Span,
    Client,
    Extraction,
    FormatHandler,
    Parser,
    Prompt
  }

  @spec run(Client.t(), String.t(), Prompt.Template.t(), keyword()) ::
          {:ok, [Span.t()]} | {:error, term()}
  def run(%Client{} = client, source, %Prompt.Template{} = template, opts \\ []) do
    prompt = Prompt.Builder.build(template, source)

    with {:ok, raw_output} <- client.provider.infer(prompt, client.options),
         {:ok, normalized} <- FormatHandler.normalize(raw_output),
         {:ok, extractions} <- Parser.parse(normalized) do
      texts = Enum.map(extractions, & &1.text)
      spans = Aligner.align(source, texts, opts)

      enriched =
        Enum.zip(extractions, spans)
        |> Enum.map(fn {%Extraction{} = extraction, %Span{} = span} ->
          %Span{span | class: extraction.class, attributes: extraction.attributes}
        end)

      {:ok, enriched}
    end
  end
end
