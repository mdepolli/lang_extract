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
    source_words_tuple = List.to_tuple(source_words)
    source_texts = Enum.map(source_words, &String.downcase(&1.text))
    source_texts_tuple = List.to_tuple(source_texts)

    Enum.map(extractions, fn extraction ->
      align_one(extraction, source_words_tuple, source_texts, source_texts_tuple, fuzzy_threshold)
    end)
  end

  defp align_one("", _source_words, _source_texts, _source_texts_tuple, _threshold) do
    not_found_span("")
  end

  defp align_one(extraction, source_words, source_texts, source_texts_tuple, threshold) do
    ext_tokens = extraction |> Tokenizer.tokenize() |> reject_whitespace()
    ext_texts = Enum.map(ext_tokens, &String.downcase(&1.text))
    ext_length = length(ext_texts)

    case exact_match(extraction, source_words, source_texts, ext_texts, ext_length) do
      {:ok, span} ->
        span

      :no_match ->
        fuzzy_match(
          extraction,
          source_words,
          source_texts_tuple,
          ext_texts,
          ext_length,
          threshold
        )
    end
  end

  defp exact_match(extraction, source_words, source_texts, ext_texts, ext_length) do
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
        {:ok, found_span(extraction, source_words, start_idx, end_idx, :exact)}

      nil ->
        :no_match
    end
  end

  defp fuzzy_match(extraction, source_words, source_texts_tuple, ext_texts, ext_length, threshold) do
    if ext_length == 0 do
      not_found_span(extraction)
    else
      ext_freq = Enum.frequencies(ext_texts)

      best = slide_window(source_texts_tuple, ext_freq, ext_length)

      case best do
        {ratio, start_idx, end_idx} when ratio >= threshold ->
          found_span(extraction, source_words, start_idx, end_idx, :fuzzy)

        _ ->
          not_found_span(extraction)
      end
    end
  end

  defp slide_window(source_texts_tuple, ext_freq, window_size) do
    source_length = tuple_size(source_texts_tuple)

    if source_length < window_size do
      {0.0, 0, 0}
    else
      init_window = for i <- 0..(window_size - 1), do: elem(source_texts_tuple, i)
      init_freq = Enum.frequencies(init_window)
      init_overlap = compute_overlap(init_freq, ext_freq)
      init_best = {init_overlap / window_size, 0, window_size - 1}

      {best, _freq} =
        Enum.reduce(window_size..(source_length - 1)//1, {init_best, init_freq}, fn idx, acc ->
          slide_step(idx, acc, source_texts_tuple, ext_freq, window_size)
        end)

      best
    end
  end

  defp slide_step(
         idx,
         {{best_ratio, _, _} = best, freq},
         source_texts_tuple,
         ext_freq,
         window_size
       ) do
    incoming = elem(source_texts_tuple, idx)
    outgoing = elem(source_texts_tuple, idx - window_size)
    freq = freq |> add_token(incoming) |> remove_token(outgoing)
    overlap = compute_overlap(freq, ext_freq)
    ratio = overlap / window_size

    best = if ratio > best_ratio, do: {ratio, idx - window_size + 1, idx}, else: best
    {best, freq}
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

  defp not_found_span(text) do
    %Span{text: text, byte_start: nil, byte_end: nil, status: :not_found}
  end

  defp found_span(text, source_words, start_idx, end_idx, status) do
    first = elem(source_words, start_idx)
    last = elem(source_words, end_idx)
    %Span{text: text, byte_start: first.byte_start, byte_end: last.byte_end, status: status}
  end

  defp reject_whitespace(tokens) do
    Enum.reject(tokens, &(&1.type == :whitespace))
  end
end
