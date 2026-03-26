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
     (`"`, `'`, `)`, `]`, `}`, `»`, `\u201D`, `\u2019`) is consumed into the same sentence.
  3. A `:whitespace` token containing `\\n` followed by an uppercase-starting
     `:word` token starts a new sentence.
  """

  alias LangExtract.Alignment.Tokenizer
  alias LangExtract.Chunker.Chunk

  @abbreviations ~w(Mr Mrs Ms Dr Prof St)
  @closing_punctuation [~s("), "'", ")", "]", "}", "»", "\u201D", "\u2019"]
  @sentence_ending ~w(. ! ?)

  @doc """
  Splits text into chunks respecting sentence boundaries.

  ## Options

    * `:max_chunk_chars` — maximum characters per chunk (required)

  """
  @spec chunk(String.t(), keyword()) :: [Chunk.t()]
  def chunk("", _opts), do: []

  def chunk(text, opts) when is_binary(text) do
    max_chars = Keyword.fetch!(opts, :max_chunk_chars)

    text
    |> find_sentences()
    |> pack_sentences(max_chars)
  end

  defp pack_sentences(sentences, max_chars) do
    {chunks, current_text, current_start, _current_len} =
      Enum.reduce(sentences, {[], "", 0, 0}, fn sentence,
                                                {chunks, current_text, current_start, current_len} ->
        sentence_len = String.length(sentence)

        if current_len + sentence_len <= max_chars or current_text == "" do
          {chunks, current_text <> sentence, current_start, current_len + sentence_len}
        else
          chunk = %Chunk{text: current_text, byte_start: current_start}
          new_start = current_start + byte_size(current_text)
          {[chunk | chunks], sentence, new_start, sentence_len}
        end
      end)

    if current_text != "" do
      Enum.reverse([%Chunk{text: current_text, byte_start: current_start} | chunks])
    else
      Enum.reverse(chunks)
    end
  end

  @spec find_sentences(String.t()) :: [String.t()]
  def find_sentences(""), do: []

  def find_sentences(text) when is_binary(text) do
    tokens = Tokenizer.tokenize(text)
    tokens_tuple = List.to_tuple(tokens)
    count = tuple_size(tokens_tuple)
    boundaries = find_boundaries(tokens_tuple, count)
    tokens_to_sentences(tokens_tuple, boundaries, text)
  end

  defp find_boundaries(tokens_tuple, count) do
    boundaries =
      Enum.reduce(0..(count - 1)//1, [], fn idx, acc ->
        token = elem(tokens_tuple, idx)

        cond do
          sentence_end_by_punctuation?(token, idx, tokens_tuple) ->
            end_idx = consume_closing_punctuation(idx + 1, tokens_tuple, count)
            [end_idx | acc]

          sentence_end_by_newline?(token, idx, tokens_tuple, count) ->
            [idx | acc]

          true ->
            acc
        end
      end)

    boundaries
    |> Enum.sort()
    |> Enum.uniq()
    |> ensure_final_boundary(count)
  end

  defp sentence_end_by_punctuation?(%{type: :punctuation, text: text}, idx, tokens_tuple)
       when text in @sentence_ending do
    not abbreviation_before?(idx, tokens_tuple)
  end

  defp sentence_end_by_punctuation?(_token, _idx, _tokens_tuple), do: false

  defp abbreviation_before?(punct_idx, tokens_tuple) when punct_idx > 0 do
    prev = elem(tokens_tuple, punct_idx - 1)
    prev.type == :word and prev.text in @abbreviations
  end

  defp abbreviation_before?(_punct_idx, _tokens_tuple), do: false

  defp consume_closing_punctuation(idx, tokens_tuple, count) when idx < count do
    token = elem(tokens_tuple, idx)

    if token.type == :punctuation and token.text in @closing_punctuation do
      consume_closing_punctuation(idx + 1, tokens_tuple, count)
    else
      idx
    end
  end

  defp consume_closing_punctuation(idx, _tokens_tuple, _count), do: idx

  defp sentence_end_by_newline?(%{type: :whitespace, text: ws_text}, idx, tokens_tuple, count) do
    if String.contains?(ws_text, "\n") and idx + 1 < count do
      next = elem(tokens_tuple, idx + 1)
      next.type == :word and uppercase_start?(next.text)
    else
      false
    end
  end

  defp sentence_end_by_newline?(_token, _idx, _tokens_tuple, _count), do: false

  defp uppercase_start?(<<first::utf8, _rest::binary>>) do
    char = <<first::utf8>>
    String.upcase(char) == char and String.downcase(char) != char
  end

  defp uppercase_start?(_), do: false

  defp ensure_final_boundary(boundaries, count) do
    if List.last(boundaries) == count do
      boundaries
    else
      boundaries ++ [count]
    end
  end

  # Extracts sentence strings using byte offsets from the token tuple.
  # Uses boundary pairs to look up first/last token directly — O(1) per sentence.
  defp tokens_to_sentences(tokens_tuple, boundaries, text) do
    {sentences, _} =
      Enum.reduce(boundaries, {[], 0}, fn boundary, {acc, start_idx} ->
        if boundary > start_idx do
          first = elem(tokens_tuple, start_idx)
          last = elem(tokens_tuple, boundary - 1)
          sentence = binary_part(text, first.byte_start, last.byte_end - first.byte_start)
          {[sentence | acc], boundary}
        else
          {acc, boundary}
        end
      end)

    Enum.reverse(sentences)
  end
end
