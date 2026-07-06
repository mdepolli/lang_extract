# Roadmap

Features from the [original Python library](https://github.com/google/langextract)
and natural extensions that haven't been implemented yet.

## Production Pipeline

- ~~**Streaming results**~~ — shipped: `LangExtract.stream/4` (0.7.0).
- ~~**Supervised runner**~~ — shipped: `LangExtract.Runner` with shared
  budget, global 429 backoff, runner-owned retries, bounded delivery,
  and graceful drain (0.7.0).

## Extraction Quality

- **Multi-pass extraction** — Run the pipeline N times and merge results with
  first-pass-wins overlap resolution. Improves recall by catching extractions
  that one pass might miss.
- **Cross-chunk deduplication** — When chunking, the same entity might be
  extracted from adjacent chunks at sentence boundaries. The original merges
  non-overlapping extractions with a first-pass-wins strategy.
- **Contraction tokenization parity** — We keep contractions whole ("don't"
  is one token); upstream splits them, letting its lesser phase ground the
  fragment. Documented divergence (see `@known_divergences` in
  `aligner_parity_test.exs`); revisit only if it shows up in real workloads.

## Multi-Document & Batch Processing

- **Batch inference** — Process multiple documents in a single call with
  shared chunking and parallel provider calls (subsumed by the Runner's
  `stream_corpus` if 0.8.0 lands as designed).
- **`AnnotatedDocument` wrapper** — A struct tying together document ID, source
  text, and extraction results for multi-document workflows.

## Provider Features

- **Ollama provider** — Local inference with no API key required.
- **Gemini structured output** — Pass `response_schema` for constrained
  decoding via Gemini's native JSON schema support (upstream #483 added
  user-provided output schemas for Gemini and OpenAI).
- **Gemini Vertex AI auth** — Project/location-based auth for enterprise use.
- **Schema generation from examples** — Introspect few-shot examples to
  automatically build a JSON Schema for providers that support it.
- **Provider plugin system** — Registry for community providers.

## Format & I/O

- **URL text fetching** — Download and extract text from URLs (needs an
  explicit opt-in design; fetching arbitrary URLs is an SSRF surface).
- **CSV dataset loading** — Batch-load documents from CSV files.
- **Template loading from files** — Load `PromptTemplate` from JSON/YAML files
  instead of constructing structs in code.

## Tokenization

- **Unicode tokenizer** — The original has a `UnicodeTokenizer` for CJK, emoji,
  and grapheme cluster support alongside the regex-based tokenizer.
- **Configurable abbreviation lists** — The sentence detector uses a hardcoded
  set (`Mr.`, `Dr.`, etc.). Domain-specific abbreviations (e.g., medical, legal)
  may need custom lists.

## Visualization

- **Interactive HTML output** — The original generates self-contained HTML with
  color-coded highlights, animated playback, tooltips, and Jupyter integration.

## Benchmark

- **Structured-fields task** — A third benchmark axis on synthetic resumes:
  attribute-heavy, schema-like extraction, the profile closest to production
  document-processing use. Replaces the retired literary_devices task.
- **Thinking/visible token split** — Compare response text size against
  `output_tokens` to measure adaptive-thinking spend directly; would close
  the residual ~1.4× ner output-token gap vs Python (see BASELINE.md).

## Removed since last revision

Shipped or obsoleted: plural stemming, `MATCH_LESSER`, and variable fuzzy
windows (0.5.0 aligner parity port); `compare.py` rewrite and alignment
comparison tooling (benchmark overhaul, parity achieved); `align/3` smoke
test (covered by doctests); smart-quote normalization pass (superseded by
the parity policy — we match upstream behavior rather than exceeding it).
