# Roadmap

Features from the [original Python library](https://github.com/google/langextract)
and natural extensions that haven't been implemented yet.

## Extraction Quality

- **Multi-pass extraction** — Run the pipeline N times and merge results with
  first-pass-wins overlap resolution. Improves recall by catching extractions
  that one pass might miss.
- **Variable fuzzy window sizes** — The original tests multiple window sizes
  during fuzzy matching for better recall. We use a fixed window equal to the
  extraction token count.
- **Light plural stemming** — The original normalizes tokens by stripping
  trailing "s" during fuzzy matching. We only downcase.
- **`MATCH_LESSER` status** — Partial contiguous Myers matches that preempt the
  fuzzy phase. Currently our aligner falls through to fuzzy for any non-exact
  match.
- **Cross-chunk overlap resolution** — When chunking, the same entity might be
  extracted from overlapping chunk context. The original merges non-overlapping
  extractions with a first-pass-wins strategy.

## Multi-Document & Batch Processing

- **Batch inference** — Process multiple documents in a single `run` call with
  shared chunking and parallel provider calls.
- **`AnnotatedDocument` wrapper** — A struct tying together document ID, source
  text, and extraction results for multi-document workflows.
- **Streaming results** — Emit completed documents as soon as all their chunks
  finish, rather than waiting for everything.

## Provider Features

- **Ollama provider** — Local inference with no API key required.
- **Gemini structured output** — Pass `response_schema` for constrained
  decoding via Gemini's native JSON schema support.
- **Gemini Vertex AI auth** — Project/location-based auth for enterprise use.
- **Schema generation from examples** — Introspect few-shot examples to
  automatically build a JSON Schema for providers that support it.
- **Provider plugin system** — Registry for community providers.

## Format & I/O

- **YAML support** — The original supports both JSON and YAML output formats.
- **URL text fetching** — Download and extract text from URLs.
- **CSV dataset loading** — Batch-load documents from CSV files.
- **Template loading from files** — Load `PromptTemplate` from YAML/JSON files
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

## Tech Debt

- **`LangExtract.align/3` smoke test** — The public API delegate has no direct
  test. The underlying `Aligner.align/3` is tested, but a smoke test for the
  top-level function would catch delegation bugs.
