defmodule LangExtract.Alignment.Aligner do
  @moduledoc """
  Maps extraction strings to byte spans in source text.

  Phase 1: Exact contiguous match via `List.myers_difference/2`.
  Phase 2: Fuzzy sliding-window fallback.
  """

  alias LangExtract.Alignment.{Span, Tokenizer}

  @default_fuzzy_threshold 0.75

  @spec align(String.t(), [String.t()], keyword()) :: [Span.t()]
  def align(source, extractions, opts \\ []) do
    fuzzy_threshold = Keyword.get(opts, :fuzzy_threshold, @default_fuzzy_threshold)
    source_tokens = Tokenizer.tokenize(source)
    source_words = reject_whitespace(source_tokens)
    # Convert to tuple for O(1) lookups by index
    source_words_tuple = List.to_tuple(source_words)
    source_texts = Enum.map(source_words, &String.downcase(&1.text))

    Enum.map(extractions, fn extraction ->
      align_one(extraction, source_words_tuple, source_texts, fuzzy_threshold)
    end)
  end

  defp align_one("", _source_words, _source_texts, _threshold) do
    %Span{text: "", byte_start: nil, byte_end: nil, status: :not_found}
  end

  defp align_one(extraction, source_words, source_texts, threshold) do
    ext_tokens = extraction |> Tokenizer.tokenize() |> reject_whitespace()
    ext_texts = Enum.map(ext_tokens, &String.downcase(&1.text))

    case exact_match(extraction, source_words, source_texts, ext_texts) do
      {:ok, span} -> span
      :no_match -> fuzzy_match(extraction, source_words, source_texts, ext_texts, threshold)
    end
  end

  defp exact_match(extraction, source_words, source_texts, ext_texts) do
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
        first = elem(source_words, start_idx)
        last = elem(source_words, end_idx)

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

  defp fuzzy_match(extraction, source_words, source_texts, ext_texts, threshold) do
    ext_length = length(ext_texts)

    if ext_length == 0 do
      %Span{text: extraction, byte_start: nil, byte_end: nil, status: :not_found}
    else
      ext_freq = build_freq(ext_texts)

      best = slide_window(source_texts, ext_freq, ext_length)

      case best do
        {ratio, start_idx, end_idx} when ratio >= threshold ->
          first = elem(source_words, start_idx)
          last = elem(source_words, end_idx)

          %Span{
            text: extraction,
            byte_start: first.byte_start,
            byte_end: last.byte_end,
            status: :fuzzy
          }

        _ ->
          %Span{text: extraction, byte_start: nil, byte_end: nil, status: :not_found}
      end
    end
  end

  defp slide_window(source_texts, ext_freq, window_size) do
    source_length = length(source_texts)

    if source_length < window_size do
      {0.0, 0, 0}
    else
      source_texts_tuple = List.to_tuple(source_texts)
      # Build initial window frequency
      {init_window, rest} = Enum.split(source_texts, window_size)
      init_freq = build_freq(init_window)
      init_overlap = compute_overlap(init_freq, ext_freq)
      init_best = {init_overlap / window_size, 0, window_size - 1}

      {best, _freq} =
        rest
        |> Enum.with_index(window_size)
        |> Enum.reduce(
          {init_best, init_freq},
          &slide_step(&1, &2, source_texts_tuple, ext_freq, window_size)
        )

      best
    end
  end

  defp slide_step(
         {incoming, idx},
         {{best_ratio, _, _} = best, freq},
         source_texts_tuple,
         ext_freq,
         window_size
       ) do
    outgoing = elem(source_texts_tuple, idx - window_size)
    freq = freq |> add_token(incoming) |> remove_token(outgoing)
    overlap = compute_overlap(freq, ext_freq)
    ratio = overlap / window_size

    best = if ratio > best_ratio, do: {ratio, idx - window_size + 1, idx}, else: best
    {best, freq}
  end

  defp build_freq(tokens) do
    Enum.frequencies(tokens)
  end

  defp add_token(freq, token) do
    Map.update(freq, token, 1, &(&1 + 1))
  end

  defp remove_token(freq, token) do
    case Map.get(freq, token) do
      1 -> Map.delete(freq, token)
      n when n > 1 -> Map.put(freq, token, n - 1)
      _ -> freq
    end
  end

  defp compute_overlap(window_freq, ext_freq) do
    Enum.reduce(ext_freq, 0, fn {token, ext_count}, acc ->
      window_count = Map.get(window_freq, token, 0)
      acc + min(window_count, ext_count)
    end)
  end

  defp reject_whitespace(tokens) do
    Enum.reject(tokens, &(&1.type == :whitespace))
  end
end
