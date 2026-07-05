defmodule LangExtract.Prompt.Builder do
  @moduledoc """
  Renders Q&A-formatted prompts from a template for LLM extraction.

  The framing mirrors upstream langextract's `QAPromptGenerator`: an
  `Examples` heading, `Q:`/`A:` pairs (answers are code-fenced by
  `WireFormat.format_extractions/1`), and a trailing bare `A:` that primes
  the model to emit the artifact directly. Measured on the ner benchmark
  (2026-07-05 probe series, BASELINE.md): this scaffold cuts output tokens
  ~20% versus bare concatenation by reducing adaptive-thinking spend, with
  no alignment cost.
  """

  alias LangExtract.{Prompt.Template, WireFormat}

  # YAML-mode output invites paraphrase: models merge interrupted quotes,
  # normalize punctuation, and echo few-shot examples on empty passages.
  # Grounding requires verbatim spans, so the prompt demands them.
  @instructions """
                Extract only text that appears verbatim in the passage below, exactly as
                written, including punctuation and quotation marks. Never merge separate
                fragments, complete text from memory, or copy from the examples. If the
                passage contains nothing to extract, output {"extractions": []}
                """
                |> String.trim()

  @spec build(Template.t(), String.t()) :: String.t()
  def build(%Template{} = template, chunk_text) do
    [
      non_empty(template.description),
      format_examples(template.examples),
      @instructions,
      "Q: " <> chunk_text,
      "A:"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_examples(nil), do: nil
  defp format_examples([]), do: nil

  defp format_examples(examples) do
    rendered =
      Enum.map_join(examples, "\n\n", fn example ->
        formatted = WireFormat.format_extractions(example.extractions)
        "Q: #{example.text}\nA: #{formatted}"
      end)

    "Examples\n\n" <> rendered
  end

  defp non_empty(""), do: nil
  defp non_empty(str), do: str
end
