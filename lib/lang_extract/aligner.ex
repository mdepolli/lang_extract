defmodule LangExtract.Aligner do
  @moduledoc """
  Maps extraction strings to byte spans in source text.

  Phase 1: Exact contiguous match via `List.myers_difference/2`.
  Phase 2: Fuzzy sliding-window fallback.
  """

  alias LangExtract.{Span, Tokenizer}

  @default_fuzzy_threshold 0.75

  @spec align(String.t(), [String.t()], keyword()) :: [Span.t()]
  def align(source, extractions, opts \\ []) do
    fuzzy_threshold = Keyword.get(opts, :fuzzy_threshold, @default_fuzzy_threshold)
    source_tokens = Tokenizer.tokenize(source)
    source_words = reject_whitespace(source_tokens)

    Enum.map(extractions, fn extraction ->
      align_one(extraction, source_words, fuzzy_threshold)
    end)
  end

  defp align_one("", _source_words, _threshold) do
    %Span{text: "", byte_start: nil, byte_end: nil, status: :not_found}
  end

  defp align_one(extraction, source_words, threshold) do
    ext_tokens = extraction |> Tokenizer.tokenize() |> reject_whitespace()

    case exact_match(extraction, source_words, ext_tokens) do
      {:ok, span} -> span
      :no_match -> fuzzy_match(extraction, source_words, ext_tokens, threshold)
    end
  end

  defp exact_match(extraction, source_words, ext_tokens) do
    source_texts = Enum.map(source_words, &String.downcase(&1.text))
    ext_texts = Enum.map(ext_tokens, &String.downcase(&1.text))
    ext_length = length(ext_texts)

    diff = List.myers_difference(source_texts, ext_texts)

    {match, _index} =
      Enum.reduce(diff, {nil, 0}, fn
        {:eq, segment}, {best, src_idx} ->
          seg_len = length(segment)

          best =
            if seg_len >= ext_length and is_nil(best) do
              {src_idx, src_idx + ext_length - 1}
            else
              best
            end

          {best, src_idx + seg_len}

        {:del, segment}, {best, src_idx} ->
          {best, src_idx + length(segment)}

        {:ins, _segment}, {best, src_idx} ->
          {best, src_idx}
      end)

    case match do
      {start_idx, end_idx} ->
        first = Enum.at(source_words, start_idx)
        last = Enum.at(source_words, end_idx)

        {:ok,
         %Span{
           text: extraction,
           byte_start: first.byte_start,
           byte_end: last.byte_end,
           status: :exact
         }}

      nil ->
        :no_match
    end
  end

  # Fuzzy match placeholder — implemented in Task 9
  defp fuzzy_match(extraction, _source_words, _ext_tokens, _threshold) do
    %Span{text: extraction, byte_start: nil, byte_end: nil, status: :not_found}
  end

  defp reject_whitespace(tokens) do
    Enum.reject(tokens, &(&1.type == :whitespace))
  end
end
