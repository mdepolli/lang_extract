defmodule LangExtract.PromptBuilder do
  @moduledoc """
  Renders Q&A-formatted prompts from a template for LLM extraction.

  Stateless — the caller passes previous chunk text explicitly
  for cross-chunk coreference resolution.
  """

  alias LangExtract.{FormatHandler, PromptTemplate}

  @spec build(PromptTemplate.t(), String.t(), keyword()) :: String.t()
  def build(%PromptTemplate{} = template, chunk_text, opts \\ []) do
    [
      template.description,
      format_examples(template.examples),
      format_context(opts),
      chunk_text
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_examples(nil), do: nil
  defp format_examples([]), do: nil

  defp format_examples(examples) do
    examples
    |> Enum.map(fn example ->
      formatted = FormatHandler.format_extractions(example.extractions)
      "#{example.text}\n#{formatted}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_context(opts) do
    case Keyword.get(opts, :previous_chunk) do
      nil ->
        nil

      prev ->
        window = Keyword.get(opts, :context_window_chars)
        text = if window, do: String.slice(prev, -window..-1//1), else: prev
        "[Previous text]: ...#{text}"
    end
  end
end
