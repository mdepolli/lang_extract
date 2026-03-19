defmodule LangExtract.Chunker.Chunk do
  @moduledoc """
  A chunk of text with its byte offset in the source.
  """

  @type t :: %__MODULE__{text: String.t(), byte_start: non_neg_integer()}
  @enforce_keys [:text, :byte_start]
  defstruct [:text, :byte_start]
end

defmodule LangExtract.Chunker do
  @moduledoc """
  Splits text into sentence-level chunks using the Alignment.Tokenizer.

  Sentence boundary rules:
  1. A `:punctuation` token of `.`, `!`, or `?` ends a sentence, unless it
     forms a known abbreviation with the preceding word token.
  2. After sentence-ending punctuation, trailing closing punctuation
     (`"`, `'`, `)`, `]`, `}`, `»`, `"`, `'`) is consumed into the same sentence.
  3. A `:whitespace` token containing `\\n` followed by an uppercase-starting
     `:word` token starts a new sentence.
  """

  alias LangExtract.Alignment.Tokenizer

  @abbreviations ~w(Mr Mrs Ms Dr Prof St)

  @closing_punctuation [~s("), "'", ")", "]", "}", "»"]
  # Unicode right double quotation mark and right single quotation mark
  @closing_punctuation_unicode ["\u201D", "\u2019"]

  @sentence_ending ~w(. ! ?)

  @spec find_sentences(String.t()) :: [String.t()]
  def find_sentences(""), do: []

  def find_sentences(text) when is_binary(text) do
    tokens = Tokenizer.tokenize(text)
    indexed = Enum.with_index(tokens)
    boundaries = find_boundaries(indexed, tokens)
    tokens_to_sentences(tokens, boundaries, text)
  end

  # Returns a list of boundary indices (exclusive end indices into the token list).
  # Each boundary marks the end of a sentence.
  defp find_boundaries(indexed, tokens) do
    tokens_array = List.to_tuple(tokens)
    count = tuple_size(tokens_array)

    boundaries =
      Enum.reduce(indexed, [], fn {token, idx}, acc ->
        cond do
          sentence_end_by_punctuation?(token, idx, tokens_array) ->
            end_idx = consume_closing_punctuation(idx + 1, tokens_array, count)
            [end_idx | acc]

          sentence_end_by_newline?(token, idx, tokens_array, count) ->
            [idx | acc]

          true ->
            acc
        end
      end)

    boundaries
    |> Enum.sort()
    |> Enum.dedup()
    |> ensure_final_boundary(count)
  end

  defp sentence_end_by_punctuation?(%{type: :punctuation, text: text}, idx, tokens_array)
       when text in @sentence_ending do
    not abbreviation_before?(idx, tokens_array)
  end

  defp sentence_end_by_punctuation?(_token, _idx, _tokens_array), do: false

  defp abbreviation_before?(punct_idx, tokens_array) when punct_idx > 0 do
    prev = elem(tokens_array, punct_idx - 1)

    prev.type == :word and prev.text in @abbreviations
  end

  defp abbreviation_before?(_punct_idx, _tokens_array), do: false

  # Consumes any trailing closing punctuation tokens starting at `idx`,
  # returning the index after the last consumed token.
  defp consume_closing_punctuation(idx, tokens_array, count)
       when idx < count do
    token = elem(tokens_array, idx)

    if token.type == :punctuation and
         (token.text in @closing_punctuation or token.text in @closing_punctuation_unicode) do
      consume_closing_punctuation(idx + 1, tokens_array, count)
    else
      idx
    end
  end

  defp consume_closing_punctuation(idx, _tokens_array, _count), do: idx

  # A whitespace token containing "\n" followed by an uppercase word starts a new sentence.
  # The boundary index is the index of the whitespace token itself (exclusive end of current sentence).
  defp sentence_end_by_newline?(%{type: :whitespace, text: ws_text}, idx, tokens_array, count) do
    if String.contains?(ws_text, "\n") do
      next_idx = idx + 1

      if next_idx < count do
        next = elem(tokens_array, next_idx)
        next.type == :word and uppercase_start?(next.text)
      else
        false
      end
    else
      false
    end
  end

  defp sentence_end_by_newline?(_token, _idx, _tokens_array, _count), do: false

  defp uppercase_start?(<<first::utf8, _rest::binary>>) do
    char = <<first::utf8>>
    String.upcase(char) == char and String.downcase(char) != char
  end

  defp uppercase_start?(_), do: false

  # Ensures there is always a final boundary at `count` (end of all tokens).
  defp ensure_final_boundary(boundaries, count) do
    if List.last(boundaries) == count do
      boundaries
    else
      boundaries ++ [count]
    end
  end

  # Converts the token list and boundary indices into sentence strings,
  # extracting text from the original binary via byte offsets.
  defp tokens_to_sentences(tokens, boundaries, text) do
    {sentences, _} =
      Enum.reduce(boundaries, {[], 0}, fn boundary, {acc, start_token_idx} ->
        sentence_tokens = Enum.slice(tokens, start_token_idx, boundary - start_token_idx)

        sentence =
          case sentence_tokens do
            [] ->
              nil

            [first | _] = toks ->
              last = List.last(toks)
              byte_len = last.byte_end - first.byte_start
              binary_part(text, first.byte_start, byte_len)
          end

        if sentence do
          {acc ++ [sentence], boundary}
        else
          {acc, boundary}
        end
      end)

    sentences
  end
end
