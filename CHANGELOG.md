# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Minimum Elixir raised to 1.15** — plug 1.20 (test dependency, pulled in by
  a security patch) requires Elixir 1.15, and CI can no longer verify 1.14.

### Fixed

- **Claude provider default model updated to `claude-sonnet-5`** — the previous
  default, `claude-sonnet-4-20250514`, was retired upstream on 2026-06-15, so
  `LangExtract.new(:claude)` without an explicit `:model` returned 404s.
- **Claude provider no longer sends `temperature` by default** — claude-sonnet-5
  rejects non-default sampling parameters with a 400, so the old
  `temperature: 0` default broke every request. It is now sent only when the
  caller explicitly sets `:temperature`.
- **`WireFormat.normalize/1` no longer corrupts YAML block scalars** — the
  colon-quoting pass treated block scalar headers (`dialogue: |-`) as values
  and quoted them, orphaning the indented lines and failing the parse.
  Claude Sonnet 5 emits multi-line extractions as block scalars, so this
  caused chunk-level `{:invalid_format, _}` failures.
- **`WireFormat.normalize/1` parses first, repairs only on failure** — valid
  YAML (including multi-line plain scalars) is never rewritten. The repair
  pass now also recovers unterminated and mis-escaped quoted values and folds
  plain-scalar continuation lines, fixing all chunk failures observed in the
  July 2026 benchmark (11/11 payloads, 90 extractions recovered).

## [0.4.0] - 2026-07-02

### Changed

- **`LangExtract.IO` renamed to `LangExtract.Serializer`** (breaking) — The old
  name shadowed Elixir's standard-library `IO` module, forcing callers to alias
  around the collision. The functions are unchanged.
- **`LangExtract.Pipeline.Extraction` promoted to `LangExtract.Extraction`**
  (breaking) — The struct users build in every template example is the
  library's central payload, shared by `Prompt` and `Pipeline` alike; it now
  lives at the top level instead of inside one consumer's namespace.
- **`LangExtract.Pipeline.FormatHandler` renamed to `LangExtract.WireFormat`**
  (breaking) — The LLM wire-format port (encode for prompts, decode for
  responses) moved to the top level for the same reason. With both moves,
  `Prompt` no longer depends on `Pipeline` at all.
- **Provider HTTP defaults: 120s receive timeout and transient retries** —
  Reverses the 0.2.0 "retries disabled by default" decision. LLM completions
  routinely exceed Req's 15s `receive_timeout` default, and `retry: false`
  meant a transient 429/5xx permanently dropped a chunk as a `ChunkError`.
  Both remain overridable via `req_options:`.
- **Aligner ports upstream langextract v1.6.0 semantics** — After the exact
  phase, a difflib-style lesser phase grounds partial matches anchored at the
  extraction's first token, and an LCS subsequence fallback (with upstream's
  0.75 coverage and 1/3 density gates, plus light plural stemming) replaces
  the fixed-window fuzzy matcher. Extractions that previously returned
  `:not_found` (interrupted dialogue, plural variants) now ground as `:fuzzy`
  with trimmed spans. New options: `:min_density`, `:accept_lesser`.
  Verified against upstream via generated differential fixtures
  (`test/fixtures/alignment_parity.json`).
- **Exact alignment via linear scan** — Replaces `List.myers_difference/2`,
  which did O(N²) work in source token count and missed genuinely contiguous
  matches when extraction tokens also appeared scattered earlier in the source
  (those fell back to `:fuzzy`; they now align as `:exact` with the same byte
  offsets).
- **Hex package no longer ships the benchmark Mix task** — `mix benchmark.run`
  needs the local `benchmark/` corpus, which was never packaged, so the task
  could only fail for downstream users. An explicit `files:` list now scopes
  the package to the library itself.

### Added

- **Verbatim extraction instruction in prompts** — `Prompt.Builder` now
  instructs the model to extract only verbatim spans and to emit
  `extractions: []` for contentless passages. Reduces ungrounded extractions
  (few-shot echoes, merged interrupted quotes) that could never align.
- **`Serializer.span_to_map/1`** — Public single-span serialization
  (previously private), also used by the benchmark task instead of a
  duplicated implementation.

### Fixed

- **`Serializer.from_map/1` and `load_jsonl/1` no longer raise on malformed
  input** — An unknown or missing extraction `"status"` now returns
  `{:error, :invalid_data}` (the module's existing error contract) instead of
  raising `ArgumentError` from `String.to_existing_atom/1`.

## [0.3.0] - 2026-04-06

### Changed

- **`LangExtract.run/4` returns `{:ok, {spans, chunk_errors}} | {:error, reason}`** —
  Always returns partial results alongside chunk errors instead of halting on
  the first failure. Infrastructure failures (task exits, timeouts) return
  `{:error, reason}`.
- **Pipeline namespace** — `FormatHandler`, `Parser`, `Extraction` moved under
  `LangExtract.Pipeline.*`. `Pipeline` is the public API for the extraction context.
- **YAML format with quoting** — LLM wire format switched from JSON to YAML,
  matching the upstream Python library. Unquoted values containing colons are
  automatically quoted before parsing.
- **Removed `run_single`** — All text goes through chunking, matching Python's
  behavior. The `max_chunk_chars: :disabled` option is removed.
- **Removed `:on_chunk_error` callback** — Errors are now visible in the return
  value. The callback was redundant.
- **Removed previous chunk context** — Was causing cross-chunk `not_found`
  alignments. Python disables this by default.
- **`Chunk` struct** now includes `byte_end`, computed once in `pack_sentences`.
- **`FormatHandler.normalize/1`** passes through valid YAML without an
  `extractions` key, letting `Parser` return `:missing_extractions`.
- **Broke dependency cycle** between `LangExtract` and `Orchestrator`. Shared
  pipeline logic (normalize → parse → align) extracted into `LangExtract.Pipeline`.
- **Reuse Req HTTP client** across requests. New `build_http_client/1` callback
  on `Provider` behaviour builds the `Req` struct once at `new/2` time, stored
  on `Client.http_client` and reused for all subsequent requests.
- **Tokenizer `classify/1`** uses binary pattern matching for ASCII bytes,
  falling back to Unicode regex only for non-ASCII. Avoids up to 3 regex calls
  per token.
- **`Client` struct** now redacts `:options` and `:http_client` from `inspect`
  output to prevent accidental API key exposure in logs.

### Added

- **`LangExtract.Pipeline.ChunkError`** — Struct with `byte_start`, `byte_end`,
  and `reason` for failed chunk regions.
- **Benchmark improvements** — Per-document JSON files in timestamped
  directories, `--document` flag for single-document runs, `_latest` symlink.

## [0.2.2] - 2026-03-19

### Added

- **ROADMAP.md** — Documents future improvements and unported features from
  the original Python library.
- **Aligner edge-case tests** — Additional test coverage inspired by the
  Python langextract test suite.

### Changed

- **README.md** — Moved future improvements to ROADMAP.md. Cleaned up
  comparison section.

### Removed

- **`docs/` directory** — Removed historical design specs and implementation
  plans (17 files, ~7,000 lines). These served their purpose during
  development; the project is now documented via README, CHANGELOG, and ROADMAP.

## [0.2.1] - 2026-03-19

### Fixed

- Remove stale `httpower` entry from `mix.lock`.

## [0.2.0] - 2026-03-19

### Changed

- **Replaced HTTPower with Req** as the HTTP client. Req is a mature,
  batteries-included HTTP client with wide ecosystem adoption. This removes
  the `httpower` and direct `finch` dependencies.
- **Gemini API key** now passed via Req's `params:` option instead of being
  embedded in the URL path string.
- **Req retries disabled by default** in all providers. Callers can opt in
  via `req_options: [retry: :transient]`.
- **Generic `:req_options` passthrough** replaces the test-specific `:plug`
  option. Any Req configuration (timeouts, retry, pool settings, plug for
  testing) can be forwarded to the underlying Req request.

### Added

- **Orchestrator with chunking** — `LangExtract.run/3,4` wires the full
  pipeline end-to-end. Sentence-aware chunking via `:max_chunk_chars` option
  with `Task.async_stream` for parallel inference.
- **`LangExtract.new/2`** — Req-inspired two-step API: create a client, then
  run extractions.
- **`LangExtract.Chunker`** — Sentence-aware text splitting with
  abbreviation awareness and three-tier strategy.
- **`LangExtract.IO`** — Serialize extraction results to plain maps and JSONL.
- **Module reorganization** — Alignment and Prompt subdomains for cleaner
  namespace organization.

## [0.1.0] - 2026-03-18

Initial release. A complete Elixir port of the core pipeline from
[google/langextract](https://github.com/google/langextract) — extracts
structured data from text using LLMs and maps every extraction back to exact
byte positions in the source.

### Added

#### Core Pipeline

- **`LangExtract.new/2`** — Create a configured LLM client with a provider
  shorthand (`:claude`, `:openai`, `:gemini`) and provider-specific options.
- **`LangExtract.run/3,4`** — Run the full extraction pipeline: build prompt →
  call LLM → normalize → parse → align → return enriched spans.
- **`LangExtract.extract/3`** — Parse raw LLM output and align extractions
  against source text. Accepts both canonical (`class`/`text`/`attributes`)
  and dynamic-key format.
- **`LangExtract.align/3`** — Align extraction strings to byte spans in source
  text without LLM involvement.

#### Alignment (`LangExtract.Alignment.*`)

- **Tokenizer** — Regex-based tokenizer producing tokens with byte offsets.
  Keeps contractions as single tokens for better English alignment.
- **Two-phase Aligner** — Phase 1: exact contiguous match via
  `List.myers_difference/2`. Phase 2: fuzzy sliding-window fallback with
  configurable threshold (default 0.75). Uses tuples for O(1) index access.
- **Span struct** — Holds extraction text, byte offsets (`byte_start`,
  `byte_end`), alignment status (`:exact`, `:fuzzy`, `:not_found`), plus
  optional `class` and `attributes` from the LLM.

#### Prompt Building (`LangExtract.Prompt.*`)

- **Template** — Struct holding a task description and few-shot examples.
- **ExampleData** — Struct for a single few-shot example (source text +
  expected extractions).
- **Builder** — Renders Q&A-formatted prompts with dynamic-key extraction
  examples. Supports cross-chunk context via `:previous_chunk` option.
- **Validator** — Pre-flight check that few-shot examples align against their
  own source text. `validate/1` returns results; `validate!/1` raises.
  The caller decides severity — no built-in logging or severity levels.

#### Format Handler

- **`LangExtract.Pipeline.FormatHandler`** — Hexagonal port between external LLM format
  and internal domain. Serializes `Extraction` structs to dynamic-key JSON for
  prompts. Normalizes raw LLM output (strips `<think>` tags, markdown fences,
  converts dynamic keys to canonical `class`/`text`/`attributes` format).
  Returns decoded maps to avoid redundant JSON round-trips.

#### LLM Providers

- **Provider behaviour** — Single `infer/2` callback. Shared helpers for API key
  resolution (`fetch_api_key/2`), common options (`common_opts/2`), and HTTP
  error mapping (`map_response/2`).
- **Claude** (`LangExtract.Provider.Claude`) — Anthropic Messages API via
  Req. `x-api-key` header auth.
- **OpenAI** (`LangExtract.Provider.OpenAI`) — Chat Completions API via
  Req. Bearer auth. Optional JSON mode (`:json_mode` option, default
  `true`). Works with any OpenAI-compatible endpoint.
- **Gemini** (`LangExtract.Provider.Gemini`) — REST API via Req. Query
  parameter auth. JSON output via `responseMimeType`.

#### Chunking

- **`LangExtract.Chunker`** — Sentence-aware text chunking with three-tier
  strategy: sentence packing → newline splitting → token fallback.
  Abbreviation-aware sentence detection (`Mr.`, `Dr.`, etc.).
  Newline + uppercase heuristic for paragraph breaks.
- **Orchestrator chunking** — When `:max_chunk_chars` is set, the orchestrator
  splits the source, processes chunks in parallel via `Task.async_stream`,
  adjusts byte offsets, and concatenates results. Previous chunk text is passed
  as prompt context for cross-chunk coreference resolution.

#### I/O

- **`LangExtract.IO`** — Serialize extraction results to plain maps
  (`to_map/2`) and back (`from_map/1`). Save/load multiple results as JSONL
  (`save_jsonl/2`, `load_jsonl/1`).

#### Infrastructure

- **Client struct** — Holds provider module and options. Created via
  `LangExtract.new/2`.
- **Req** — Batteries-included HTTP client. Uses `json:` option for automatic
  request body encoding. Retries disabled by default; opt in via `:req_options`.
- **Req.Test** — All provider integration tests use stubs, not network
  calls.
- **Credo** — Strict mode passes with zero issues.
- **187 tests** — Full coverage across all modules.

### Divergences from Python Reference

- **Byte offsets** instead of character offsets (natural for Elixir binaries).
- **Contraction handling** — `don't` is one token, not three.
- **No `MATCH_LESSER`/`MATCH_GREATER`** — Deliberate simplification. Our
  three statuses (`:exact`, `:fuzzy`, `:not_found`) are cleaner.
- **Claude provider** — Not in the original; added as the primary provider.
- **JSON only** — No YAML support (modern LLMs handle JSON well).
- **Caller-decides severity** for prompt validation (no built-in severity enum).
- **Req-inspired API** — `new/2` + `run/3,4` instead of a single function with
  many keyword arguments.

[Unreleased]: https://github.com/mdepolli/lang_extract/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/mdepolli/lang_extract/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mdepolli/lang_extract/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/mdepolli/lang_extract/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/mdepolli/lang_extract/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mdepolli/lang_extract/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mdepolli/lang_extract/releases/tag/v0.1.0
