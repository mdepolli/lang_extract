defmodule LangExtract.Prompt.Builder do
  @moduledoc """
  Renders Q&A-formatted prompts from a template for LLM extraction.
  """

  alias LangExtract.{Prompt.Template, WireFormat}

  # YAML-mode output invites paraphrase: models merge interrupted quotes,
  # normalize punctuation, and echo few-shot examples on empty passages.
  # Grounding requires verbatim spans, so the prompt demands them.
  @instructions String.trim("""
                Extract only text that appears verbatim in the passage below, exactly as
                written, including punctuation and quotation marks. Never merge separate
                fragments, complete text from memory, or copy from the examples. If the
                passage contains nothing to extract, output an empty list: extractions: []
                """)

  @spec build(Template.t(), String.t()) :: String.t()
  def build(%Template{} = template, chunk_text) do
    [
      non_empty(template.description),
      format_examples(template.examples),
      @instructions,
      chunk_text
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_examples(nil), do: nil
  defp format_examples([]), do: nil

  defp format_examples(examples) do
    Enum.map_join(examples, "\n\n", fn example ->
      formatted = WireFormat.format_extractions(example.extractions)
      "#{example.text}\n#{formatted}"
    end)
  end

  defp non_empty(""), do: nil
  defp non_empty(str), do: str
end
