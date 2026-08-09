defmodule LangExtract.Chunker do
  @moduledoc """
  Splits text into sentence-aware chunks, mirroring upstream's `ChunkIterator`.

  A chunk is a token interval: its text runs from its first token's start to
  its last token's end. Whitespace between chunks belongs to no chunk, so
  chunks do not tile the source — matching upstream, whose token stream has
  no whitespace tokens. Byte offsets always slice the chunk's text back out
  of the source verbatim.

  Sentence boundary rules (upstream's `find_sentence_range` semantics):
  1. A `:punctuation` token ending in a sentence terminator (`.`, `!`, `?`,
     CJK equivalents — `...` counts, since symbol runs are one token) ends a
     sentence, unless the previous token plus the terminator form a known
     abbreviation (`"Dr" <> "." == "Dr."`). Whitespace is invisible here, so
     `"Dr ."` still reads as the abbreviation.
  2. After sentence-ending punctuation, trailing closing punctuation
     (`"`, `'`, `)`, `]`, `}`, `»`, `”`, `’`) is consumed into the
     same sentence — across any whitespace, so the quote opening the next
     line's dialogue attaches to the sentence before it, exactly as upstream.
  3. A token first on its line (its gap from the previous token contains
     `\\n` or `\\r`) starts a new sentence unless it begins lowercase —
     lines opening with quotes, digits, or capitals all break (upstream:
     "assume break unless lowercase").

  Chunk assembly (mirroring upstream's `ChunkIterator.__next__`):
  1. A single token longer than the budget forms a chunk by itself.
  2. An oversized sentence is cut at the most recent newline within budget
     when one exists, else at the last token that fits; the remainder
     restarts sentence discovery mid-sentence.
  3. A chunk that completes a broken sentence never absorbs following
     sentences.
  4. Otherwise whole sentences pack into the chunk while they fit.

  Budgets count characters (upstream's `max_char_buffer` unit — see
  `chunk/2`); offsets are bytes.

  Departure from upstream's shape: every boundary rule is position-local,
  so sentence ends are precomputed for all positions in one backward pass,
  where upstream rescans forward from each chunk start — quadratic on
  boundary-free text (minified JSON, logs). Behavior is pinned two ways:
  the parity fixtures tie the line-comparable port to upstream, and the
  differential test ties this rewrite to that port, frozen as
  `LangExtract.Test.ChunkerBaseline` in test support.
  """

  alias LangExtract.Alignment.Tokenizer
  alias LangExtract.Chunker.Chunk

  @abbreviations ~w(Mr. Mrs. Ms. Dr. Prof. St.)
  @closing_punctuation [~s("), "'", ")", "]", "}", "»", "”", "’"]
  # Upstream's _END_OF_SENTENCE_PATTERN: a token ending in a sentence
  # terminator (same-symbol runs make "..." one token, so match the tail).
  @sentence_ending ~r/[.?!。！？\x{0964}]["'”’»)\]}]*$/u

  @doc """
  Splits text into chunks respecting sentence boundaries.

  ## Options

    * `:max_chunk_chars` — maximum characters per chunk (required).
      Char-denominated to mirror upstream's `max_char_buffer` — chars are
      code points, Python's `len` unit — so chunk boundaries land
      identically across the two libraries; the cross-library benchmarks
      depend on that. Output offsets are bytes.

  """
  @spec chunk(String.t(), keyword()) :: [Chunk.t()]
  def chunk(text, opts) when is_binary(text) do
    max_chars = Keyword.fetch!(opts, :max_chunk_chars)

    # nil would otherwise disable chunking silently: integers sort before
    # atoms in term order, so char-count <= nil is always true and the
    # whole document becomes one chunk.
    unless is_integer(max_chars) and max_chars > 0 do
      raise ArgumentError,
            "max_chunk_chars must be a positive integer, got: #{inspect(max_chars)}"
    end

    tokens = annotate_tokens(text)
    boundaries = sentence_boundaries(tokens)
    build_chunks(text, tokens, tuple_size(tokens), boundaries, 0, false, max_chars, [])
  end

  # The chunker's token stream: the tokenizer's non-whitespace tokens,
  # annotated with char positions (the budget unit) and whether the gap
  # from the previous token contains a line break (upstream's
  # first_token_after_newline; a lone \r counts, and the document's first
  # token never carries the flag).
  defp annotate_tokens(text) do
    {annotated, _char_pos, _newline?} =
      text
      |> Tokenizer.tokenize()
      |> Enum.reduce({[], 0, false}, &annotate_token/2)

    annotated
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp annotate_token(token, {acc, char_pos, newline?}) do
    # Code points, not graphemes: upstream's budget unit is Python's len().
    # String.length/1 would undercount "\r\n" (one grapheme, two code
    # points) by one char per hard-wrapped line, drifting every cut.
    char_end = char_pos + length(String.codepoints(token.text))

    if token.type == :whitespace do
      gap_breaks? = newline? or String.contains?(token.text, ["\n", "\r"])
      {acc, char_end, gap_breaks?}
    else
      annotated = %{
        text: token.text,
        type: token.type,
        byte_start: token.byte_start,
        byte_end: token.byte_end,
        char_start: char_pos,
        char_end: char_end,
        newline?: newline? and acc != []
      }

      {[annotated | acc], char_end, false}
    end
  end

  # For every position, the end of the sentence a scan started there would
  # find (upstream find_sentence_range(idx)). One backward pass: a rule
  # hit at idx is position-local (punctuation end at idx, or a break
  # before idx + 1); a miss inherits the boundary of idx + 1. Entry count
  # holds the end-of-text sentinel, so lookups never bounds-check.
  defp sentence_boundaries(tokens) do
    count = tuple_size(tokens)

    (count - 1)..0//-1
    |> Enum.reduce([count], fn idx, [next | _] = acc ->
      boundary =
        cond do
          sentence_end_by_punctuation?(elem(tokens, idx), idx, tokens) ->
            consume_closing_punctuation(idx + 1, tokens, count)

          sentence_break_after_newline?(idx, tokens, count) ->
            idx + 1

          true ->
            next
        end

      [boundary | acc]
    end)
    |> List.to_tuple()
  end

  # Upstream ChunkIterator.__next__, one clause per return path: a token
  # wider than the budget is its own chunk; otherwise the sentence grows
  # token-by-token (cutting at the budget), and only an unbroken sentence
  # may then absorb following whole sentences.
  defp build_chunks(_text, _tokens, count, _boundaries, pos, _broken?, _max_chars, acc)
       when pos >= count do
    Enum.reverse(acc)
  end

  defp build_chunks(text, tokens, count, boundaries, pos, broken?, max_chars, acc) do
    sentence_end = elem(boundaries, pos)

    if span_exceeds?(tokens, pos, pos + 1, max_chars) do
      chunk = emit_chunk(text, tokens, pos, pos + 1)
      still_broken? = pos + 1 < sentence_end

      build_chunks(text, tokens, count, boundaries, pos + 1, still_broken?, max_chars, [
        chunk | acc
      ])
    else
      case fit_within_sentence(tokens, pos, pos + 1, sentence_end, -1, max_chars) do
        {:cut, cut_end} ->
          chunk = emit_chunk(text, tokens, pos, cut_end)
          build_chunks(text, tokens, count, boundaries, cut_end, true, max_chars, [chunk | acc])

        :fits when broken? ->
          chunk = emit_chunk(text, tokens, pos, sentence_end)

          build_chunks(text, tokens, count, boundaries, sentence_end, false, max_chars, [
            chunk | acc
          ])

        :fits ->
          chunk_end = append_sentences(tokens, count, boundaries, pos, sentence_end, max_chars)
          chunk = emit_chunk(text, tokens, pos, chunk_end)

          build_chunks(text, tokens, count, boundaries, chunk_end, false, max_chars, [
            chunk | acc
          ])
      end
    end
  end

  # Grows [start, idx) through the sentence until the budget trips. The
  # first token already fit (build_chunks checked), so a cut interval is
  # never empty. On a cut, the most recent line start wins when it lies
  # inside the interval — upstream breaks oversized sentences at newlines.
  defp fit_within_sentence(_tokens, _start, idx, sentence_end, _newline_idx, _max_chars)
       when idx > sentence_end do
    :fits
  end

  defp fit_within_sentence(tokens, start, idx, sentence_end, newline_idx, max_chars) do
    if span_exceeds?(tokens, start, idx, max_chars) do
      cut_end = if newline_idx > start, do: newline_idx, else: idx - 1
      {:cut, cut_end}
    else
      newline_idx = next_newline_idx(tokens, idx, sentence_end, newline_idx)
      fit_within_sentence(tokens, start, idx + 1, sentence_end, newline_idx, max_chars)
    end
  end

  defp next_newline_idx(tokens, idx, sentence_end, newline_idx) do
    if idx < sentence_end and elem(tokens, idx).newline?, do: idx, else: newline_idx
  end

  # Upstream's trailing sentence loop: keep absorbing whole sentences while
  # the chunk stays within budget. Sentences are contiguous, so the chunk
  # ends exactly where the first non-fitting sentence starts.
  defp append_sentences(_tokens, count, _boundaries, _start, chunk_end, _max_chars)
       when chunk_end >= count do
    chunk_end
  end

  defp append_sentences(tokens, count, boundaries, start, chunk_end, max_chars) do
    next_end = elem(boundaries, chunk_end)

    if span_exceeds?(tokens, start, next_end, max_chars) do
      chunk_end
    else
      append_sentences(tokens, count, boundaries, start, next_end, max_chars)
    end
  end

  # Char width of the token interval [start, stop): first token's start to
  # last token's end, leading whitespace excluded, interior included —
  # upstream measures chunks through get_char_interval the same way.
  defp span_exceeds?(tokens, start, stop, max_chars) do
    elem(tokens, stop - 1).char_end - elem(tokens, start).char_start > max_chars
  end

  defp emit_chunk(text, tokens, start, stop) do
    first = elem(tokens, start)
    last = elem(tokens, stop - 1)

    %Chunk{
      text: binary_part(text, first.byte_start, last.byte_end - first.byte_start),
      byte_start: first.byte_start,
      byte_end: last.byte_end
    }
  end

  # Public only as a test seam: the sentence-boundary rules aren't
  # observable through chunk/2 (packing merges sentences back together).
  # Sentence texts span first to last token, like chunks.
  @doc false
  @spec find_sentences(String.t()) :: [String.t()]
  def find_sentences(text) when is_binary(text) do
    tokens = annotate_tokens(text)
    boundaries = sentence_boundaries(tokens)
    collect_sentences(text, tokens, tuple_size(tokens), boundaries, 0, [])
  end

  defp collect_sentences(_text, _tokens, count, _boundaries, pos, acc) when pos >= count do
    Enum.reverse(acc)
  end

  defp collect_sentences(text, tokens, count, boundaries, pos, acc) do
    sentence_end = elem(boundaries, pos)
    first = elem(tokens, pos)
    last = elem(tokens, sentence_end - 1)
    sentence = binary_part(text, first.byte_start, last.byte_end - first.byte_start)
    collect_sentences(text, tokens, count, boundaries, sentence_end, [sentence | acc])
  end

  defp sentence_end_by_punctuation?(%{type: :punctuation, text: text}, idx, tokens) do
    Regex.match?(@sentence_ending, text) and not abbreviation_before?(idx, tokens, text)
  end

  defp sentence_end_by_punctuation?(_token, _idx, _tokens), do: false

  # Upstream concatenates the previous token with the terminator and
  # checks the pair ("Dr" <> "." == "Dr."), so "Dr..." still breaks. The
  # token stream has no whitespace, so "Dr ." reads the same as "Dr.".
  defp abbreviation_before?(punct_idx, tokens, punct_text) when punct_idx > 0 do
    prev = elem(tokens, punct_idx - 1)
    (prev.text <> punct_text) in @abbreviations
  end

  defp abbreviation_before?(_punct_idx, _tokens, _punct_text), do: false

  defp consume_closing_punctuation(idx, tokens, count) when idx < count do
    token = elem(tokens, idx)

    if token.type == :punctuation and token.text in @closing_punctuation do
      consume_closing_punctuation(idx + 1, tokens, count)
    else
      idx
    end
  end

  defp consume_closing_punctuation(idx, _tokens, _count), do: idx

  # Upstream: "Assume break unless lowercase (covers numbers/quotes)" —
  # a line starting with “, a digit, or an uppercase letter all break.
  defp sentence_break_after_newline?(idx, tokens, count) when idx + 1 < count do
    next = elem(tokens, idx + 1)
    next.newline? and not lowercase_start?(next.text)
  end

  defp sentence_break_after_newline?(_idx, _tokens, _count), do: false

  # Total for this pipeline: the tokenizer rejects invalid UTF-8 at the
  # shared boundary and never emits empty tokens, so the head always
  # decodes. Anything else is an invariant breach; let the clause miss.
  defp lowercase_start?(<<first::utf8, _rest::binary>>) do
    char = <<first::utf8>>
    String.downcase(char) == char and String.upcase(char) != char
  end
end
