# LangExtract Span Aligner — Design Spec

## Goal

Prototype the "hard part" of a potential Elixir port of [google/langextract](https://github.com/google/langextract): the tokenizer and span aligner. This spike determines whether the core algorithm translates cleanly to Elixir before committing to a full port.

## Project setup

- Standalone Mix project at `/Users/marcelo/code/lang_extract/`
- No dependencies beyond stdlib
- Hex-publishable structure with tests

## Modules

### `LangExtract.Token`

A struct representing a single token with its position in the source text.

```elixir
%Token{
  text: "hello",        # original text, case preserved
  type: :word,           # :word | :number | :punctuation | :whitespace
  byte_start: 0,         # inclusive byte offset in source UTF-8 binary
  byte_end: 5            # exclusive byte offset in source UTF-8 binary
}
```

Offsets are byte positions in the UTF-8 binary, matching what `Regex.scan/3` with `return: :index` produces and what `binary_part/3` consumes. These are NOT codepoint/grapheme offsets — for ASCII text they're identical, but for multibyte characters (accented letters, CJK, emoji) they diverge.

### `LangExtract.Tokenizer`

Splits text into tokens with tracked byte offsets.

**Public API:**

```elixir
Tokenizer.tokenize("Hello, world!")
# => [%Token{text: "Hello", type: :word, byte_start: 0, byte_end: 5}, ...]
```

**Key decisions:**

- Byte offsets via `Regex.scan/3` with `return: :index` — natural for Elixir binaries
- Whitespace tokens preserved in output for continuous offset mapping; filtered before alignment
- Regex-based: `~r/\p{L}[\p{L}\p{M}''-]*|\d[\d.,]*|[^\s]|\s+/u`
- No text normalization — preserves offset correctness

**Regex deviation from reference:** The Python implementation splits on `[^\W\d_]+|\d+|([^\w\s]|_)\1*`, which breaks `don't` into three tokens. Our regex keeps `don't` as one token — a deliberate choice for better English alignment. This means token lists are not cross-compatible with the Python version.

### `LangExtract.Span`

A struct representing an aligned extraction.

```elixir
%Span{
  text: "quick brown",   # the extraction string as given
  byte_start: 4,         # inclusive byte offset in source
  byte_end: 15,          # exclusive byte offset in source
  status: :exact          # :exact | :fuzzy | :not_found
}
```

### `LangExtract.Aligner`

Maps extraction strings to byte spans in source text using a two-phase approach.

**Public API:**

```elixir
Aligner.align(source_text, ["quick brown", "lazy dog"], fuzzy_threshold: 0.75)
# => [%Span{text: "quick brown", byte_start: 4, byte_end: 15, status: :exact}, ...]
```

**Options:**

- `:fuzzy_threshold` — minimum overlap ratio for fuzzy match (default `0.75`)

**Top-level convenience:**

```elixir
LangExtract.align(source_text, extractions, opts \\ [])
# delegates to Aligner.align/3
```

**Phase 1 — Exact match via Myers diff:**

1. Tokenize source and extraction, filter out whitespace tokens
2. Downcase token texts for comparison
3. Run `List.myers_difference(source_words, extraction_words)`
4. Walk the edit script maintaining a source token index counter:
   - `:eq` segments → advance source index by segment length
   - `:del` segments → advance source index by segment length (tokens only in source)
   - `:ins` segments → do not advance (tokens only in extraction)
5. For each `:eq` segment, check if it contains a contiguous run matching all extraction tokens. Track the source index range where the match starts and ends.
6. If found: look up the original (unfiltered) source tokens at those indices, take `byte_start` from the first matched token and `byte_end` from the last. Mark `:exact`.
7. If no single contiguous `:eq` segment covers all extraction tokens → fall through to Phase 2.

**Phase 2 — Fuzzy fallback (sliding window):**

Triggered when Myers doesn't find a contiguous match.

1. Build token frequency map from extraction tokens (downcased)
2. Slide a window of `length(extraction_tokens)` across the source tokens (whitespace-filtered, downcased)
3. Maintain a running frequency count — add incoming token, subtract outgoing — for O(n) total
4. At each position, compute overlap ratio: `matched / total_extraction_tokens`
5. Track the window position with the highest ratio
6. If best ratio >= fuzzy_threshold, map window bounds back to byte offsets via source tokens. Mark `:fuzzy`.
7. Otherwise return `status: :not_found` with `byte_start: nil, byte_end: nil`

**Simplification note:** The reference implementation tests multiple window sizes for better recall. This spike uses a fixed window size equal to extraction token count. Variable window sizes can be added later if needed.

**Multiple extractions** are aligned independently — no deduplication or overlap resolution at this layer.

## Edge cases to test

- Empty source text → all extractions return `:not_found`
- Empty extraction string → returns `:not_found`
- Extraction appears multiple times in source → first occurrence wins (matches Myers diff behavior)
- Extraction longer than source → `:not_found`
- Unicode: multibyte characters (é, ñ), CJK, emoji — byte offsets must be correct
- Case mismatch: `"Hello"` in source, `"hello"` in extraction → should match
- Punctuation adjacent to words: `"Hello,"` should not prevent matching `"Hello"`

## File structure

```
lang_extract/
├── lib/
│   ├── lang_extract.ex         # top-level convenience (delegates to Aligner)
│   └── lang_extract/
│       ├── token.ex
│       ├── tokenizer.ex
│       ├── span.ex
│       └── aligner.ex
├── test/
│   └── lang_extract/
│       ├── tokenizer_test.exs
│       └── aligner_test.exs
└── mix.exs
```

## Out of scope

- LLM calls, prompt building, chunking, orchestration
- Visualization / HTML output
- Multi-pass extraction merging
- Overlap resolution between extractions
- Token normalization beyond downcasing (e.g., stemming, stripping possessives)
- Variable fuzzy window sizes
