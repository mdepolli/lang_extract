defmodule LangExtract.Prompt.Builder do
  @moduledoc """
  Renders Q&A-formatted prompts from a template for LLM extraction.

  Stateless — the caller passes previous chunk text explicitly
  for cross-chunk coreference resolution.
  """

  alias LangExtract.{FormatHandler, Prompt.Template}

  @doc """
  Builds a Q&A-formatted prompt from a template and chunk text.

  ## Options

    * `:previous_chunk` - text from the previous chunk for cross-chunk coreference (default: `nil`)
    * `:context_window_chars` - trailing grapheme count from previous chunk to include
      (default: `nil`, meaning use full previous chunk). Operates on graphemes, not bytes.

  """
  @spec build(Template.t(), String.t(), keyword()) :: String.t()
  def build(%Template{} = template, chunk_text, opts \\ []) do
    [
      non_empty(template.description),
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
    Enum.map_join(examples, "\n\n", fn example ->
      formatted = FormatHandler.format_extractions(example.extractions)
      "#{example.text}\n#{formatted}"
    end)
  end

  defp non_empty(""), do: nil
  defp non_empty(str), do: str

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
