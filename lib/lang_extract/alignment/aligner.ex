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
     subsequence match over lightly stemmed tokens, accepted when matched
     tokens ≥ `ceil(extraction tokens × :fuzzy_threshold)` (upstream's
     coverage gate, float error included) and density (matched / span
     length) ≥ `:min_density`, preferring the tightest span.
     Status `:fuzzy`.

  Known divergence from upstream: our fallthrough phases treat each leftover
  extraction standalone, while upstream reruns difflib over the concatenated
  tokens of all sibling extractions — see @known_divergences in
  aligner_parity_test.exs for the observable consequences.

  DP claims narrow only the lesser phase when `:exact_algorithm` is `:dp`
  (the default). Token intervals are half-open `[start, end)` throughout.
  Phase-0 placements seed the claim list; each successful leftover
  reserves its interval for later items. Exact and LCS fallthrough ignore
  claims: upstream grounds nested and contested mentions inside sibling
  placements (see the dp_nested_* and dp_contested_overlap fixtures), so
  rediscovering claimed tokens is correct there. The lesser phase is
  "plain optimum, then claim-rescue" via `accept_free_or_masked/3`: the
  plain difflib block stands when it lands on free source; a winner that
  overlaps a claim reruns under a claimed-token mask, so a paraphrase of
  an already-claimed repeat cannot ground its prefix inside the claim
  (upstream returns not_found for those too).

  With `:exact_algorithm` `:first_occurrence`, phase 0 is skipped and
  claims stay empty.

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

  # Two units of work: index (document views) and item (one extraction).
  # After assign_phase0, item.placement is {:selected, start} | :leftover.
  # Claims are fold state only — not a third unit.
  # Grounding: half-open [start, end) plus status, produced when placing.

  @spec align(String.t(), [String.t()], keyword()) :: [Span.t()]
  def align(source, extractions, opts \\ []) do
    config = build_config(opts)
    index = index_source(source)

    items =
      extractions
      |> tokenize_items()
      |> assign_phase0(index, config)

    index
    |> stem_if_leftovers(items)
    |> place(items, config)
  end

  defp build_config(opts) do
    %{
      threshold: Keyword.get(opts, :fuzzy_threshold, @default_fuzzy_threshold),
      min_density: Keyword.get(opts, :min_density, @default_min_density),
      accept_lesser: Keyword.get(opts, :accept_lesser, true),
      exact_algorithm: Keyword.get(opts, :exact_algorithm, :dp)
    }
  end

  # --- Setup: items, source index, phase-0 placement, optional stems ---

  # Raw work item: text (Span.text), downcased tokens (matching), model-output index.
  defp tokenize_items(extractions) do
    extractions
    |> Enum.with_index()
    |> Enum.map(fn {text, idx} ->
      tokens =
        text
        |> Tokenizer.tokenize()
        |> reject_whitespace()
        |> Enum.map(&String.downcase(&1.text))

      %{text: text, tokens: tokens, idx: idx}
    end)
  end

  # Phase 0 as a routing decision on each item. The DP may still use an
  # internal %{idx => start} map; it does not escape this boundary.
  defp assign_phase0(items, _index, %{exact_algorithm: :first_occurrence}) do
    Enum.map(items, &Map.put(&1, :placement, :leftover))
  end

  defp assign_phase0(items, index, %{exact_algorithm: :dp}) do
    selection = occurrence_selection(index, items)

    Enum.map(items, fn item ->
      case Map.fetch(selection, item.idx) do
        {:ok, start} -> Map.put(item, :placement, {:selected, start})
        :error -> Map.put(item, :placement, :leftover)
      end
    end)
  end

  # Source views phases read: word tokens with byte offsets (span
  # construction) and downcased texts (matching). Both are tuples for
  # O(1) access. Stemmed texts are filled in only when fallthrough can run.
  defp index_source(source) do
    words =
      source
      |> Tokenizer.tokenize()
      |> reject_whitespace()

    texts = Enum.map(words, &String.downcase(&1.text))

    %{
      words: List.to_tuple(words),
      texts: List.to_tuple(texts),
      stemmed: nil
    }
  end

  # Upstream normalizes source tokens only once unaligned extractions
  # remain (resolver.py builds src_norm inside the fuzzy-alignment branch);
  # mirror that so a fully placed call never pays the stem pass. LCS is
  # the only stem reader, and stemmed stays a list — it is only ever
  # walked sequentially by the LCS scan.
  defp stem_if_leftovers(%{texts: texts} = index, items) do
    if Enum.any?(items, &(&1.placement == :leftover)) do
      %{index | stemmed: texts |> Tuple.to_list() |> Enum.map(&stem_token/1)}
    else
      index
    end
  end

  # --- Placement: selected hits vs leftovers under claims ---

  # :dp seeds claims from phase-0 selections and grows them on leftover
  # hits; claims mask only the lesser phase. :first_occurrence never claims.
  defp place(index, items, %{exact_algorithm: :dp} = config) do
    fold_placements(index, items, config, claims_from_selected(items))
  end

  defp place(index, items, %{exact_algorithm: :first_occurrence} = config) do
    fold_placements(index, items, config, _claimed = [])
  end

  defp fold_placements(index, items, config, claimed) do
    {spans, _claimed} =
      Enum.map_reduce(items, claimed, fn item, claimed ->
        place_one(item, index, config, claimed)
      end)

    spans
  end

  defp place_one(%{placement: {:selected, start}} = item, index, _config, claimed) do
    from_selection(item, start, index, claimed)
  end

  defp place_one(%{placement: :leftover} = item, index, config, claimed) do
    place_leftover(item, index, config, claimed)
  end

  defp from_selection(%{text: text, tokens: tokens}, start, %{words: words}, claimed) do
    grounding = %{status: :exact, start: start, end: start + length(tokens)}
    {to_span(text, words, grounding), claimed}
  end

  defp place_leftover(item, index, config, claimed) do
    case align_one(item, index, config, claimed) do
      {:ok, grounding} ->
        {to_span(item.text, index.words, grounding), reserve_claim(claimed, grounding, config)}

      :not_found ->
        {not_found_span(item.text), claimed}
    end
  end

  defp reserve_claim(claimed, grounding, %{exact_algorithm: :dp}),
    do: [interval(grounding) | claimed]

  defp reserve_claim(claimed, _grounding, %{exact_algorithm: :first_occurrence}), do: claimed

  defp claims_from_selected(items) do
    for %{placement: {:selected, start}, tokens: tokens} <- items do
      {start, start + length(tokens)}
    end
  end

  defp interval(%{start: start, end: end_}), do: {start, end_}

  # Half-open token intervals [start, end).
  defp free?(claimed, {c, d}) do
    not Enum.any?(claimed, fn {a, b} -> c < b and a < d end)
  end

  # Lesser-phase claim policy ("plain optimum, then rescue"). on_claimed is
  # invoked only when the plain winner overlaps a claim — the caller builds
  # the mask and re-runs there, so free winners pay nothing.
  defp accept_free_or_masked(nil, _claimed, _on_claimed), do: nil

  defp accept_free_or_masked(interval, claimed, on_claimed) do
    if free?(claimed, interval) do
      interval
    else
      on_claimed.()
    end
  end

  defp claimed_token_set(claimed) do
    for {a, b} <- claimed, idx <- a..(b - 1)//1, into: MapSet.new(), do: idx
  end

  # Phases return {:ok, grounding} | :no_match. A successful value fails the
  # with pattern and becomes align_one's result; exhausting every phase
  # yields :not_found.
  defp align_one(item, index, config, claimed) do
    with :no_match <- exact_match(item, index),
         :no_match <- lesser_match(item, index, config, claimed),
         :no_match <- lcs_match(item, index, config) do
      :not_found
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

  # Internal %{idx => start} for the DP only; assign_phase0 writes placement on items.
  defp occurrence_selection(%{texts: source_texts}, items) do
    items
    |> Enum.reduce([], fn %{tokens: ext_texts, idx: idx}, frontier ->
      add_extraction(frontier, idx, ext_texts, contiguous_starts(source_texts, ext_texts))
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

  # --- Contiguous token runs (phase 0 occurrences + phase 1 exact) ---

  # Every source start where ext_texts appears as a contiguous subslice.
  defp contiguous_starts(texts, ext_texts) do
    case start_range(texts, ext_texts) do
      nil ->
        []

      first..last//1 ->
        Enum.filter(first..last//1, &subslice_at?(texts, ext_texts, &1))
    end
  end

  # Exact fallthrough strategy: plain first contiguous occurrence. Claims
  # are not consulted — nested/contested rediscovery is upstream behavior.
  defp first_contiguous(texts, ext_texts) do
    case start_range(texts, ext_texts) do
      nil ->
        nil

      first..last//1 ->
        Enum.find(first..last//1, &subslice_at?(texts, ext_texts, &1))
    end
  end

  defp start_range(texts, ext_texts) do
    last_start = tuple_size(texts) - length(ext_texts)

    if last_start < 0 do
      nil
    else
      0..last_start//1
    end
  end

  defp subslice_at?(_texts, [], _start_idx), do: true

  defp subslice_at?(texts, [text | rest], start_idx) do
    elem(texts, start_idx) == text and subslice_at?(texts, rest, start_idx + 1)
  end

  # --- Phase 1: exact contiguous match (first occurrence wins) ---

  defp exact_match(%{tokens: []}, _index), do: :no_match

  defp exact_match(%{tokens: ext_texts}, %{texts: texts}) do
    case first_contiguous(texts, ext_texts) do
      nil ->
        :no_match

      start ->
        {:ok, %{status: :exact, start: start, end: start + length(ext_texts)}}
    end
  end

  # --- Phase 2: lesser match ("plain optimum, then claim-rescue") ---

  defp lesser_match(_item, _index, %{accept_lesser: false}, _claimed), do: :no_match

  defp lesser_match(%{tokens: []}, _index, _config, _claimed), do: :no_match

  defp lesser_match(%{tokens: ext_texts}, %{texts: texts}, _config, claimed) do
    case free_prefix_block(texts, List.to_tuple(ext_texts), claimed) do
      nil ->
        :no_match

      {start, end_} ->
        {:ok, %{status: :lesser, start: start, end: end_}}
    end
  end

  # Returns half-open [start, end) or nil.
  defp free_prefix_block(source_tuple, ext_tuple, claimed) do
    source_hi = tuple_size(source_tuple)
    ext_hi = tuple_size(ext_tuple)

    source_tuple
    |> prefix_block(ext_tuple, source_hi, ext_hi, MapSet.new())
    |> prefix_to_interval()
    |> accept_free_or_masked(claimed, fn ->
      source_tuple
      |> prefix_block(ext_tuple, source_hi, ext_hi, claimed_token_set(claimed))
      |> prefix_to_interval()
    end)
  end

  defp prefix_to_interval(nil), do: nil
  defp prefix_to_interval({start, len}), do: {start, start + len}

  # difflib decomposes matches by recursively taking the longest common block
  # (ties: lowest source index, then lowest extraction index). Only a block
  # anchored at extraction token 0 grounds MATCH_LESSER, and such a block can
  # only come from the leftmost recursion path — so chase it directly.
  # With an empty mask this is difflib exactly; masked tokens cannot join
  # runs, so a masked search decomposes over free source only.
  # Returns {source_start, block_len} or nil.
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

  # --- Phase 3: LCS fuzzy over stemmed tokens ---

  defp lcs_match(%{tokens: []}, _index, _config), do: :no_match

  defp lcs_match(%{tokens: ext_texts}, %{stemmed: stemmed}, %{threshold: threshold} = config) do
    ext_stemmed = Enum.map(ext_texts, &stem_token/1)
    # Coverage gate as upstream _accept_lcs_match computes it: the float
    # error in m * threshold is part of the spec (25 * 0.28 floats to
    # 7.000000000000001, so ceil demands 8 matches, not 7).
    needed = ceil(length(ext_stemmed) * threshold)

    case accepted_lcs_span(stemmed, ext_stemmed, needed, config) do
      nil ->
        :no_match

      {start, end_} ->
        {:ok, %{status: :fuzzy, start: start, end: end_}}
    end
  end

  # Highest match count whose tightest span passes the coverage and
  # density gates (per count the span map already holds the tightest span,
  # earliest start on ties — upstream's preference).
  # Returns half-open [start, end).
  defp accepted_lcs_span(source_stemmed, ext_stemmed, needed, %{min_density: min_density}) do
    spans = best_lcs_spans(source_stemmed, ext_stemmed)

    spans
    |> Map.keys()
    |> Enum.sort(:desc)
    |> Enum.find_value(fn matches ->
      # DP harvest stores inclusive ends; convert to half-open.
      {start, last} = spans[matches]
      end_ = last + 1
      density = matches / (end_ - start)

      if matches >= needed and density >= min_density do
        {start, end_}
      end
    end)
  end

  # Port of upstream _best_lcs_spans (resolver.py): for each achievable match
  # count k, the tightest source span containing k extraction tokens as a
  # subsequence. Rolling rows over the source dimension, upstream's layout:
  # row[j][k] holds the latest source start covering k matches within the
  # first j extraction tokens; later starts yield minimal spans, earliest
  # start wins ties. A row is a tuple of m+1 k-vectors (tuples) — cells are
  # written once in build order and only ever read back through elem/2.
  # Values in the result map are inclusive {start, last} token indices.
  defp best_lcs_spans(source, extraction) do
    m = length(extraction)
    ext = List.to_tuple(extraction)
    init_vec = List.to_tuple([0 | List.duplicate(-1, m)])
    initial_row = Tuple.duplicate(init_vec, m + 1)

    {best, _row} =
      source
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, initial_row}, fn {src_tok, i}, {best, prev_row} ->
        curr = dp_row(src_tok, i, m, ext, prev_row)
        {harvest_spans(best, curr, i, m), curr}
      end)

    best
  end

  # dp_cell only reads finished vectors: the previous row's j and j-1
  # (skip a source token / take a match), and the current row's j-1
  # (skip an extraction token) — so each j-vector seals as it is built
  # and no in-place tuple update is ever needed.
  defp dp_row(src_tok, i, m, ext, prev_row) do
    j0 = List.to_tuple([i | List.duplicate(-1, m)])

    {vectors, _last} =
      Enum.map_reduce(1..m, j0, fn j, curr_jm1 ->
        matches_here = src_tok == elem(ext, j - 1)
        prev_j = elem(prev_row, j)
        prev_jm1 = elem(prev_row, j - 1)
        cells = Enum.map(1..m, &dp_cell(prev_j, prev_jm1, curr_jm1, i, &1, matches_here))
        vec = List.to_tuple([i | cells])

        {vec, vec}
      end)

    List.to_tuple([j0 | vectors])
  end

  defp dp_cell(prev_j, prev_jm1, curr_jm1, i, k, matches_here) do
    skip = max(elem(prev_j, k), elem(curr_jm1, k))

    if matches_here do
      candidate = if k == 1, do: i - 1, else: elem(prev_jm1, k - 1)
      max(skip, candidate)
    else
      skip
    end
  end

  defp harvest_spans(best, curr, i, m) do
    last = i - 1
    last_vec = elem(curr, m)

    Enum.reduce(1..m, best, fn k, best ->
      start = elem(last_vec, k)

      if start < 0 do
        best
      else
        update_tightest(best, k, start, last)
      end
    end)
  end

  defp update_tightest(best, k, start, last) do
    new_len = last - start + 1

    case Map.get(best, k) do
      nil ->
        Map.put(best, k, {start, last})

      {cur_start, cur_last} ->
        cur_len = cur_last - cur_start + 1

        if new_len < cur_len or (new_len == cur_len and start < cur_start) do
          Map.put(best, k, {start, last})
        else
          best
        end
    end
  end

  # --- Spans and token utilities ---

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

  # grounding.start/end are half-open token indices.
  defp to_span(text, words, %{status: status, start: start, end: end_}) do
    first = elem(words, start)
    last = elem(words, end_ - 1)
    %Span{text: text, byte_start: first.byte_start, byte_end: last.byte_end, status: status}
  end

  defp reject_whitespace(tokens) do
    Enum.reject(tokens, &(&1.type == :whitespace))
  end
end
