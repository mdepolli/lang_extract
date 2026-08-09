defmodule LangExtract.Alignment.Aligner do
  @moduledoc """
  Maps extraction strings to byte spans in source text.

  Mirrors upstream langextract's `WordAligner` (v1.6.0 + #485) semantics in
  four phases over downcased word tokens:

  0. **Occurrence DP** — over the whole extraction list in model output
     order: selects at most one exact occurrence per extraction, keeping
     selections order-preserving and non-overlapping while maximizing total
     matched tokens; ties prefer the earliest-ending chain, so repeated
     mentions resolve to successive occurrences. Status `:exact`.
     Extractions the DP cannot place fall through to the phases below.
  1. **Exact** — the extraction's tokens appear contiguously in the source
     (linear scan, first occurrence wins). Status `:exact`.
  2. **Lesser** — difflib-style block decomposition: if a matching block is
     anchored at the extraction's first token, its source run grounds the
     extraction (upstream `MATCH_LESSER`). Blocks elsewhere in the extraction
     do not qualify. Status `:lesser`.
  3. **LCS fuzzy** — for extractions the lesser phase couldn't anchor
     (no matching block at the extraction's first token), an LCS
     subsequence match over lightly stemmed tokens, accepted when coverage
     (matched / extraction tokens) ≥ `:fuzzy_threshold` and density
     (matched / span length) ≥ `:min_density`, preferring the tightest span.
     Status `:fuzzy`.

  Known divergence from upstream: our fallthrough phases treat each leftover
  extraction standalone, while upstream reruns difflib over the concatenated
  tokens of all sibling extractions — see @known_divergences in
  aligner_parity_test.exs for the observable consequences.

  Fallthrough respects DP claims: a token interval placed in phase 0 is
  reserved, so leftovers cannot nest inside it — exact scans past claimed
  occurrences, the lesser search keeps its plain-difflib block when it
  lands on free source and reruns with claimed tokens masked when it does
  not (claims elsewhere never disturb an uncontested grounding), and LCS
  rejects spans that overlap a claim. Each fallthrough placement reserves
  its own interval for later leftovers the same way.

  Cost model: this module aligns whatever text it is handed, with no size
  limit (same as upstream's `WordAligner`). The fallthrough phases are
  super-linear in source tokens — per leftover extraction, the naive
  lesser block search examines O(source × extraction) anchor pairs and
  walks a run from each (repetitive text pushes it past that bound), and
  LCS is O(source × extraction²) — so whole-document calls on
  book-length text take real CPU time. That time is spent in the calling process only; BEAM
  preemption keeps the rest of the system responsive. The chunked
  pipeline (`LangExtract.run/4`) is the bounded document path; callers
  who need a hard latency bound on a direct call wrap it in a task with
  a timeout.
  """

  alias LangExtract.Alignment.Tokenizer
  alias LangExtract.Span

  @default_fuzzy_threshold 0.75
  @default_min_density 1 / 3

  @spec align(String.t(), [String.t()], keyword()) :: [Span.t()]
  def align(source, extractions, opts \\ []) do
    config = build_config(opts)
    index = index_source(source)
    ext_token_lists = tokenize_extractions(extractions)
    selection = occurrence_selection(config.exact_algorithm, index.texts, ext_token_lists)

    place_extractions(extractions, ext_token_lists, selection, index, config)
  end

  defp build_config(opts) do
    %{
      threshold: Keyword.get(opts, :fuzzy_threshold, @default_fuzzy_threshold),
      min_density: Keyword.get(opts, :min_density, @default_min_density),
      accept_lesser: Keyword.get(opts, :accept_lesser, true),
      exact_algorithm: Keyword.get(opts, :exact_algorithm, :dp)
    }
  end

  # The source representations every phase reads: word tokens with byte
  # offsets (span construction), their downcased texts (matching), and
  # stemmed texts (LCS phase only). Words and texts are tuples for O(1)
  # indexed access; stemmed stays a list — it is only ever walked
  # sequentially by the LCS scan.
  defp index_source(source) do
    words = source |> Tokenizer.tokenize() |> reject_whitespace()
    texts = Enum.map(words, &String.downcase(&1.text))

    %{
      words: List.to_tuple(words),
      texts: List.to_tuple(texts),
      stemmed: Enum.map(texts, &stem_token/1)
    }
  end

  defp tokenize_extractions(extractions) do
    Enum.map(extractions, fn extraction ->
      extraction
      |> Tokenizer.tokenize()
      |> reject_whitespace()
      |> Enum.map(&String.downcase(&1.text))
    end)
  end

  # :first_occurrence keeps legacy independent first-match-wins (overlaps
  # allowed). :dp reserves phase-0 intervals so fallthrough cannot nest
  # inside a DP placement, and each fallthrough hit reserves for later
  # leftovers.
  defp place_extractions(
         extractions,
         ext_token_lists,
         _selection,
         index,
         %{
           exact_algorithm: :first_occurrence
         } = config
       ) do
    extractions
    |> Enum.zip(ext_token_lists)
    |> Enum.map(fn {extraction, ext_texts} ->
      case align_one(extraction, ext_texts, index, config, _claimed = []) do
        {:ok, span, _interval} -> span
        :not_found -> not_found_span(extraction)
      end
    end)
  end

  defp place_extractions(extractions, ext_token_lists, selection, index, config) do
    claimed = claimed_from_selection(selection, ext_token_lists)

    {spans, _claimed} =
      extractions
      |> Enum.zip(ext_token_lists)
      |> Enum.with_index()
      |> Enum.map_reduce(claimed, fn {{extraction, ext_texts}, idx}, claimed ->
        place_one(extraction, ext_texts, idx, selection, index, config, claimed)
      end)

    spans
  end

  defp place_one(extraction, ext_texts, idx, selection, index, _config, claimed)
       when is_map_key(selection, idx) do
    start_idx = Map.fetch!(selection, idx)
    end_idx = start_idx + length(ext_texts) - 1
    {found_span(extraction, index.words, start_idx, end_idx, :exact), claimed}
  end

  defp place_one(extraction, ext_texts, _idx, _selection, index, config, claimed) do
    case align_one(extraction, ext_texts, index, config, claimed) do
      {:ok, span, interval} -> {span, [interval | claimed]}
      :not_found -> {not_found_span(extraction), claimed}
    end
  end

  defp claimed_from_selection(selection, ext_token_lists) do
    lengths = ext_token_lists |> Enum.map(&length/1) |> List.to_tuple()

    Enum.map(selection, fn {idx, start_idx} ->
      {start_idx, start_idx + elem(lengths, idx)}
    end)
  end

  # Half-open token intervals [start, end).
  defp free?(claimed, {c, d}) do
    not Enum.any?(claimed, fn {a, b} -> c < b and a < d end)
  end

  defp align_one(extraction, ext_texts, index, config, claimed) do
    with :no_match <- exact_match(extraction, index, ext_texts, claimed),
         :no_match <- lesser_match(extraction, index, ext_texts, config, claimed),
         :no_match <- lcs_match(extraction, index, ext_texts, config, claimed) do
      :not_found
    else
      {:ok, span, interval} -> {:ok, span, interval}
    end
  end

  # --- Phase 0: monotonic occurrence DP (upstream #485) ---
  #
  # Port of upstream _select_monotonic_matches: chains are built over a
  # Pareto frontier of {chain_end, chain_weight, node} entries kept strictly
  # increasing in both end and weight. Weight totals matched tokens so longer
  # extractions win contested regions; equal-weight ties keep the
  # earliest-ending chain, which is what maps repeated mentions to
  # successive occurrences. Nodes are {extraction_index, start, parent}.

  defp occurrence_selection(:first_occurrence, _source_texts_tuple, _ext_token_lists), do: %{}

  defp occurrence_selection(:dp, source_texts_tuple, ext_token_lists) do
    ext_token_lists
    |> Enum.with_index()
    |> Enum.reduce([], fn {ext_texts, idx}, frontier ->
      add_extraction(frontier, idx, ext_texts, occurrences(source_texts_tuple, ext_texts))
    end)
    |> backtrack()
  end

  defp add_extraction(frontier, _idx, [], _occurrences), do: frontier
  defp add_extraction(frontier, _idx, _ext_texts, []), do: frontier

  defp add_extraction(frontier, idx, ext_texts, occurrences) do
    len = length(ext_texts)

    # Candidates chain off the pre-insert frontier so an extraction cannot
    # extend a chain that already contains it.
    occurrences
    |> Enum.map(fn start ->
      {pred_weight, parent} =
        case best_ending_at_or_before(frontier, start) do
          nil -> {0, nil}
          {_chain_end, weight, node} -> {weight, node}
        end

      {start + len, len + pred_weight, {idx, start, parent}}
    end)
    |> Enum.reduce(frontier, &insert_if_undominated(&2, &1))
  end

  defp best_ending_at_or_before(frontier, position) do
    frontier
    |> Enum.take_while(fn {chain_end, _weight, _node} -> chain_end <= position end)
    |> List.last()
  end

  defp insert_if_undominated(frontier, {chain_end, weight, _node} = entry) do
    case best_ending_at_or_before(frontier, chain_end) do
      {_chain_end, covering_weight, _node} when covering_weight >= weight ->
        frontier

      _ ->
        {keep, rest} = Enum.split_while(frontier, fn {e, _w, _n} -> e < chain_end end)
        keep ++ [entry | Enum.drop_while(rest, fn {_e, w, _n} -> w <= weight end)]
    end
  end

  defp backtrack([]), do: %{}

  defp backtrack(frontier) do
    {_chain_end, _weight, node} = List.last(frontier)
    collect_chain(node, %{})
  end

  defp collect_chain(nil, selection), do: selection

  defp collect_chain({idx, start, parent}, selection) do
    collect_chain(parent, Map.put(selection, idx, start))
  end

  defp occurrences(source_texts_tuple, ext_texts) do
    last_start = tuple_size(source_texts_tuple) - length(ext_texts)

    if last_start < 0 do
      []
    else
      Enum.filter(0..last_start//1, &subslice_at?(source_texts_tuple, ext_texts, &1))
    end
  end

  # --- Phase 1: exact contiguous match ---

  defp exact_match(_extraction, _index, [], _claimed), do: :no_match

  defp exact_match(extraction, index, ext_texts, claimed) do
    ext_length = length(ext_texts)
    last_start = tuple_size(index.texts) - ext_length

    start_idx =
      Enum.find(0..last_start//1, fn start ->
        subslice_at?(index.texts, ext_texts, start) and
          free?(claimed, {start, start + ext_length})
      end)

    case start_idx do
      nil ->
        :no_match

      start_idx ->
        interval = {start_idx, start_idx + ext_length}

        {:ok, found_span(extraction, index.words, start_idx, start_idx + ext_length - 1, :exact),
         interval}
    end
  end

  defp subslice_at?(_source_texts_tuple, [], _start_idx), do: true

  defp subslice_at?(source_texts_tuple, [text | rest], start_idx) do
    elem(source_texts_tuple, start_idx) == text and
      subslice_at?(source_texts_tuple, rest, start_idx + 1)
  end

  # --- Phase 2: lesser match (longest contiguous partial run) ---

  defp lesser_match(_extraction, _index, _ext_texts, %{accept_lesser: false}, _claimed),
    do: :no_match

  defp lesser_match(_extraction, _index, [], _config, _claimed), do: :no_match

  defp lesser_match(extraction, index, ext_texts, _config, claimed) do
    ext_tuple = List.to_tuple(ext_texts)

    case free_prefix_block(index.texts, ext_tuple, claimed) do
      nil ->
        :no_match

      {start_idx, block_len} ->
        interval = {start_idx, start_idx + block_len}

        {:ok, found_span(extraction, index.words, start_idx, start_idx + block_len - 1, :lesser),
         interval}
    end
  end

  # Two passes: plain difflib runs first, so claims elsewhere can never
  # perturb the tie-breaks that guide the recursion over free source, and
  # its block wins whenever it lands on free tokens. Only a leftover whose
  # own difflib block is claimed reruns with claimed tokens masked out of
  # runs, landing the decomposition on a later free occurrence (or
  # :no_match when every anchored candidate is claimed).
  defp free_prefix_block(source_tuple, ext_tuple, claimed) do
    source_hi = tuple_size(source_tuple)
    ext_hi = tuple_size(ext_tuple)

    case prefix_block(source_tuple, ext_tuple, source_hi, ext_hi, MapSet.new()) do
      nil ->
        nil

      {start_idx, block_len} = block ->
        if free?(claimed, {start_idx, start_idx + block_len}) do
          block
        else
          prefix_block(source_tuple, ext_tuple, source_hi, ext_hi, claimed_token_set(claimed))
        end
    end
  end

  defp claimed_token_set(claimed) do
    for {a, b} <- claimed, idx <- a..(b - 1)//1, into: MapSet.new(), do: idx
  end

  # difflib decomposes matches by recursively taking the longest common block
  # (ties: lowest source index, then lowest extraction index). Only a block
  # anchored at extraction token 0 grounds MATCH_LESSER, and such a block can
  # only come from the leftmost recursion path — so chase it directly.
  # With an empty mask this is difflib exactly; masked tokens cannot join
  # runs, so a masked search decomposes over free source only.
  defp prefix_block(_source_tuple, _ext_tuple, source_hi, ext_hi, _masked)
       when source_hi <= 0 or ext_hi <= 0,
       do: nil

  defp prefix_block(source_tuple, ext_tuple, source_hi, ext_hi, masked) do
    case longest_block(source_tuple, ext_tuple, source_hi, ext_hi, masked) do
      {_i, _j, 0} -> nil
      {i, 0, n} -> {i, n}
      {i, j, _n} -> prefix_block(source_tuple, ext_tuple, i, j, masked)
    end
  end

  # Longest common contiguous run of source[0..source_hi) and ext[0..ext_hi);
  # among maximal runs prefers the lowest source index, then lowest extraction
  # index (difflib find_longest_match tie-breaks).
  defp longest_block(source_tuple, ext_tuple, source_hi, ext_hi, masked) do
    Enum.reduce(0..(source_hi - 1), {0, 0, 0}, fn i, best ->
      Enum.reduce(0..(ext_hi - 1), best, fn j, acc ->
        best_at(source_tuple, ext_tuple, i, j, source_hi, ext_hi, masked, acc)
      end)
    end)
  end

  defp best_at(source_tuple, ext_tuple, i, j, source_hi, ext_hi, masked, {_, _, best_n} = acc) do
    n = run_length(source_tuple, ext_tuple, i, j, source_hi, ext_hi, masked)
    if n > best_n, do: {i, j, n}, else: acc
  end

  defp run_length(source_tuple, ext_tuple, i, j, source_hi, ext_hi, masked) do
    if i < source_hi and j < ext_hi and not MapSet.member?(masked, i) and
         elem(source_tuple, i) == elem(ext_tuple, j) do
      1 + run_length(source_tuple, ext_tuple, i + 1, j + 1, source_hi, ext_hi, masked)
    else
      0
    end
  end

  # --- Phase 3: LCS subsequence match over stemmed tokens ---

  defp lcs_match(_extraction, _index, [], _config, _claimed), do: :no_match

  defp lcs_match(extraction, index, ext_texts, config, claimed) do
    ext_stemmed = Enum.map(ext_texts, &stem_token/1)
    ext_length = length(ext_stemmed)
    spans = best_lcs_spans(index.stemmed, ext_stemmed)

    spans
    |> Map.keys()
    |> Enum.sort(:desc)
    |> Enum.find_value(:no_match, fn matches ->
      {start_idx, end_idx} = spans[matches]
      span_len = end_idx - start_idx + 1
      coverage = matches / ext_length
      density = matches / span_len
      interval = {start_idx, end_idx + 1}

      if coverage >= config.threshold and density >= config.min_density and
           free?(claimed, interval) do
        {:ok, found_span(extraction, index.words, start_idx, end_idx, :fuzzy), interval}
      end
    end)
  end

  # Port of upstream _best_lcs_spans (resolver.py): for each achievable match
  # count k, the tightest source span containing k extraction tokens as a
  # subsequence. dp[{j, k}] holds the latest source start covering k matches
  # within the first j extraction tokens; later starts yield minimal spans,
  # earliest start wins ties.
  defp best_lcs_spans(source, extraction) do
    m = length(extraction)
    ext = List.to_tuple(extraction)

    initial_dp =
      for j <- 0..m, k <- 0..m, into: %{} do
        {{j, k}, if(k == 0, do: 0, else: -1)}
      end

    {best, _dp} =
      source
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, initial_dp}, fn {src_tok, i}, {best, prev} ->
        curr = dp_row(src_tok, i, m, ext, prev)
        {harvest_spans(best, curr, i, m), curr}
      end)

    best
  end

  defp dp_row(src_tok, i, m, ext, prev) do
    base = for k <- 0..m, into: %{}, do: {{0, k}, if(k == 0, do: i, else: -1)}

    Enum.reduce(1..m, base, fn j, acc ->
      matches_here = src_tok == elem(ext, j - 1)
      acc = Map.put(acc, {j, 0}, i)

      Enum.reduce(1..m, acc, fn k, acc ->
        Map.put(acc, {j, k}, dp_cell(prev, acc, i, j, k, matches_here))
      end)
    end)
  end

  defp dp_cell(prev, acc, i, j, k, matches_here) do
    skip = max(Map.fetch!(prev, {j, k}), Map.fetch!(acc, {j - 1, k}))

    if matches_here do
      candidate = if k == 1, do: i - 1, else: Map.fetch!(prev, {j - 1, k - 1})
      max(skip, candidate)
    else
      skip
    end
  end

  defp harvest_spans(best, curr, i, m) do
    end_idx = i - 1

    Enum.reduce(1..m, best, fn k, best ->
      start_idx = Map.fetch!(curr, {m, k})

      if start_idx < 0 do
        best
      else
        update_tightest(best, k, start_idx, end_idx)
      end
    end)
  end

  defp update_tightest(best, k, start_idx, end_idx) do
    new_len = end_idx - start_idx + 1

    case Map.get(best, k) do
      nil ->
        Map.put(best, k, {start_idx, end_idx})

      {cur_start, cur_end} ->
        cur_len = cur_end - cur_start + 1

        if new_len < cur_len or (new_len == cur_len and start_idx < cur_start) do
          Map.put(best, k, {start_idx, end_idx})
        else
          best
        end
    end
  end

  # Upstream _normalize_token: light plural stemming, fuzzy phase only.
  defp stem_token(token) do
    if String.length(token) > 3 and String.ends_with?(token, "s") and
         not String.ends_with?(token, "ss") do
      binary_part(token, 0, byte_size(token) - 1)
    else
      token
    end
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
