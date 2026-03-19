# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  pipeline end-to-end. Sentence-aware chunking via `:max_chunk_size` option
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

- **`LangExtract.FormatHandler`** — Hexagonal port between external LLM format
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
- **Orchestrator chunking** — When `:max_chunk_size` is set, the orchestrator
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
