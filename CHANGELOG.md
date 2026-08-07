# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Malformed canonical entries are skipped, not rewritten into data** —
  a model echoing the canonical schema with one field missing
  (`{"class": "drug"}`) was falling into the dynamic-key clause, which
  fabricated an extraction out of the schema's own key names
  (`class: "class"`, `text: "drug"`). Entries carrying a canonical marker
  key now always pass through untouched, so the Parser's skip-and-log
  guard is reachable again. This reserves `class` and `text` as dynamic
  class names — a deliberate divergence from upstream, which would treat
  them as ordinary classes.

- **Exotic whitespace no longer breaks alignment** — the tokenizer's
  classifier only knew the four ASCII whitespace bytes, so NBSP, formfeed,
  vertical tab, and Unicode spaces (all matched by the token pattern's
  `\s+` alternative) were typed `:punctuation` and survived into the
  aligner as phantom tokens. An extraction whose whitespace the model
  normalized to ASCII spaces — the same habit as smart quotes — then
  degraded from `:exact` to `:lesser` over a one-token prefix, where
  upstream (which skips all whitespace gaps) matches exactly. Gutenberg
  corpus texts use formfeed page breaks, so this affected the benchmark
  corpus itself. Whitespace now classifies by character against `\s`.

- **`retry-after` deadlines are bounded** — the Limiter clamps every pause
  to a 30-second ceiling (repeated 429s still extend it window by window),
  and a negative `retry-after` now parses as `nil` like any other malformed
  value. Previously a server-supplied header was obeyed verbatim: an echoed
  epoch timestamp paused all admission for decades — silently hanging every
  `Runner.run/4` sharing the cell — and larger garbage overflowed the wake
  timer, crashing the runner cell. The backoff-escalation cap moved from
  `Request` into the Limiter, the single place pauses sleep.

- **Crash sanitizer scrubs raised exception structs** — the Runner's
  crash-reason sanitizer formatted exceptions via `Exception.format_banner/2`
  unscrubbed, so value-carrying exceptions (`KeyError`, `MatchError`, …)
  raised inside a chunk task printed their culprit term — the same place
  unredacted request headers hide — into `ChunkError.reason`. Struct fields
  are now value-stripped before formatting; an authored `:message` string
  survives.

### Changed

- **Docs demote bare `align/3` as a product path** — README no longer has an
  "Alignment Without an LLM" section. The front door matches upstream:
  `run/4` / `stream/4` for documents, `extract/3` for replaying stored model
  JSON. `align/3` remains on the facade as a thin helper over the alignment
  engine (tests/tooling); grounding itself is still the core product, via
  the pipeline. Guide and Serializer wording updated to match.

## [0.10.0] - 2026-07-20

### Added

- **Mermaid diagrams for the hard flows** — the README and guides now
  render diagrams for streaming completion order, chunk fan-out with
  partial failure, the four alignment phases, and the runner's failure
  semantics (shared 429 pause, retry budgets, drain).

### Fixed

- **`Serializer.load_jsonl/1` no longer pins the whole file in memory** —
  decoded strings of 64+ bytes were sub-binaries of the entire file
  binary, so keeping any loaded span alive retained the full file until
  GC. Strings are now copied at decode (`Jason.decode(..., strings:
  :copy)`); a regression test pins the retention bound via
  `:binary.referenced_byte_size/1`.

### Removed

- **The `validate: false` option on `template/2` and `template!/2`**
  (**breaking**) — it was the only hole in the "a template that
  constructs is a template whose examples align" invariant, and its sole
  consumer in the tree was the test exercising the option itself. The
  invariant is now unconditional. Templates whose alignment ground truth
  legitimately can't hold should be assembled as structs by hand (they
  remain public for matching) — if a real use case for unvalidated
  construction appears, it will be designed for deliberately rather than
  through a skip flag.

### Changed

- **Runner crash reasons are sanitized before becoming data** — a crashed
  chunk task's `ChunkError` now carries `{:task_exit, banner_or_atom}`
  (e.g. `"** (RuntimeError) boom"`, `:killed`) instead of the raw
  `{exception, stacktrace}` exit term. Raw exit reasons can embed the
  crashing frame's arguments or an error term's culprit value — including
  the `Req.Request` whose headers hold the API key, which Req's `Inspect`
  does not redact for `x-api-key`/`x-goog-api-key` — so the reason is
  reduced to a value-free summary at the delivery boundary: exceptions
  become their banner, atoms pass through, and any other term keeps only
  its structure (structs reduce to module names, binaries and maps to
  placeholders). Consumers matching `{:task_exit, _}` are unaffected;
  only code destructuring the raw exception tuple needs updating.

- **`req` 0.6.2 → 0.6.3** (patch bump, no code changes).

- **Gemini API key moves from the URL to the `x-goog-api-key` header** —
  the key is baked into the Req client at `new/2` like the other two
  providers, request URLs no longer contain the secret, and the
  key-in-URL logging warning is gone from the docs. No API change —
  the Gemini API accepts both transports.

- **Error reasons serialize as tagged maps** — `Serializer` now encodes
  the known `ChunkError` reason shapes as
  `%{"tag" => "task_exit", "detail" => "timeout"}`-style maps instead of
  one-way `inspect/1` strings, so persisted results can programmatically
  distinguish a timeout from a parse failure after reload. Loaded reasons
  keep their outer shape — `{:task_exit, _}`, `{:api_error, status, _}`,
  bare atoms — so the same patterns match live and loaded errors; tuple
  payloads come back as strings where the original term wasn't one,
  except the common exit atoms (`:timeout`, `:killed`, `:shutdown`),
  which round-trip exactly.
  Reasons outside the known set fall back to
  `%{"tag" => "other", "detail" => inspect(term)}` and load as the bare
  detail string; plain string reasons from files written by earlier
  versions still load unchanged. Benchmark result files are unaffected —
  their `reason` stays a display string, matching the Python runner.

- **Both `run/4`s return a bare `Result` and cannot fail** (**breaking**) —
  `LangExtract.run/4` no longer abandons the document on a chunk task
  exit: the halt clause is gone, and a timed-out chunk task lands in
  `Result.errors` as a `%ChunkError{reason: {:task_exit, :timeout}}`
  with its byte range (which the stream layer always had and the halt
  discarded), while surviving chunks' spans are kept. With the last error
  return unreachable, the `{:ok, _}` wrapper came off both entry points:
  `LangExtract.run/4` and `Runner.run/4` now return `%Result{}` bare and
  share one collector (`Orchestrator.collect/1`) — one return contract,
  the runner keeping retries, the shared budget, and crash isolation
  (standalone chunk tasks stay linked, so a bug-level crash propagates;
  the runner's supervised tasks report it as a `ChunkError`). Callers
  change `{:ok, result} = run(...)` to `result = run(...)`; the
  `{:error, {:task_exit, _}}` branch is gone.

- **`:lesser` is a fourth `Span` status** (**breaking**) — the aligner's
  lesser phase (prefix-anchored partial matches, upstream `MATCH_LESSER`)
  now reports `:lesser` instead of folding into `:fuzzy`. The two inexact
  statuses fail in different directions: `:lesser` means the model
  over-extracted or stitched fragments and the span covers the verbatim
  prefix that exists; `:fuzzy` means an LCS match over stemmed tokens.
  `Span.located?/1` counts `:lesser` as grounded, the serializer
  round-trips `"lesser"`, and both benchmark runners report it natively
  (the Python side no longer squashes `match_lesser` into `"fuzzy"`).
  Breaking for exhaustive matches on `Span.status` and for consumers of
  serialized `"status"` values.

## [0.9.0] - 2026-07-09

### Added

- **`Serializer.result_to_map/2` and `result_from_map/1`** — serialize the
  full `Result` (spans + errors + usage), not just span lists; the shape
  extends `to_map/2`'s with `"errors"` and `"usage"`. Error reasons are
  open terms, so they serialize as their `inspect/1` rendering — JSON-safe
  but one-way: loaded errors carry the rendered string.
  `chunk_error_to_map/1` is public alongside `span_to_map/1`.

- **Explicit stability tiers** — the docs now group modules as Core API
  (the SemVer contract), Advanced (public, best-effort), Providers, and
  Internal (no guarantees), and the README's new "Stability" section
  spells out the contract: the two entry points, which structs are stable
  to match on, which are public for matching but constructed via
  `template!/2`, and that `Client` is opaque. Internal-tier moduledocs
  carry the marker themselves, so a reader landing directly on an
  internal module's page sees its status.

### Changed

- **Deserialization validates field types, not just shape** —
  `Serializer.from_map/1` (and `load_jsonl/1`) now reject maps whose byte
  offsets or attributes have the wrong type, enforcing the `Span`
  invariant at the decode boundary: located spans carry non-negative
  integer offsets, `not_found` spans carry `nil`, attributes are a map.
  Previously such maps decoded into corrupted structs that crashed later
  in consumer offset arithmetic; now they fail fast as
  `{:error, :invalid_data}`. `result_from_map/1` applies the same checks
  to chunk errors.

- **Breaking: `ChunkError`, `ChunkResult`, and `Span` are promoted to
  `LangExtract.*`** (were `LangExtract.Pipeline.ChunkError`,
  `LangExtract.Pipeline.ChunkResult`, `LangExtract.Alignment.Span`) —
  they are contract structs consumers match on (`Result.spans`,
  `Result.errors`, `stream/4` events, `align/3`) and now carry top-level
  names like the rest of the contract surface (`Result`, `Extraction`).
  Alignment/pipeline machinery (`Aligner`, `Tokenizer`, `Parser`) stays
  namespaced. Migration: drop the middle segment from aliases and struct
  patterns — `LangExtract.Alignment.Span` → `LangExtract.Span`,
  `LangExtract.Pipeline.ChunkError` → `LangExtract.ChunkError`.

## [0.8.0] - 2026-07-08

### Added

- **Programmatic usage: `Result.usage` and `ChunkResult.usage`** — token
  totals from the return value, no telemetry handler required:
  `result.usage.output_tokens` after a `run/4`, per-chunk on every
  `ChunkResult` stream event. `nil` when the provider reported no usage
  block; with partial chunk failures the totals cover the chunks that
  reported. Telemetry emission is unchanged — the same numbers now flow
  both ways.

- **`Span.located?/1`** — the documented guard for offset arithmetic:
  `true` for `:exact`/`:fuzzy` spans (offsets present), `false` for
  `:not_found` (offsets `nil`). `Enum.filter(spans, &Span.located?/1)`
  replaces every consumer hand-rolling the status check.

### Changed

- **Template attribute keys normalize to strings at construction** —
  map-authored example attributes (`%{kind: "port"}`) now produce the
  same string-keyed shape the wire format decodes (`%{"kind" => "port"}`),
  so prompt-rendered examples and parsed output never differ by key type.
  Ready-made `Extraction` structs pass through unchanged.
- **Breaking: `template/2` is renamed `template!/2`; `template/2` now
  returns tagged tuples** — the raising constructor gets the bang the
  stdlib convention demands (`URI.new/new!`), and the un-suffixed name
  becomes the non-raising twin for runtime task definitions:
  `{:ok, Template.t()} | {:error, ArgumentError.t() | ValidationError.t()}`.
  Migration: append `!` to existing calls. Wrong-typed fields (non-string
  `text`/`class`, non-list `extractions`, non-map `attributes`, non-map
  examples) also return the tagged `ArgumentError` — previously they
  raised `Protocol.UndefinedError` or `FunctionClauseError` deep in
  normalization, undermining the non-raising contract.
- **Breaking: `Provider.infer/2` returns `%Provider.Response{}`** (was a
  bare `{:ok, text}`) — the struct carries `text` plus `usage`
  (input/output token counts, `nil` when the API omits them). Providers
  were already parsing usage and discarding it into telemetry; now it
  reaches callers programmatically. Only affects direct callers of the
  provider layer and third-party `Provider` implementations — `run/4`,
  `stream/4`, and the Runner are unchanged by this entry.
- **Breaking: `run/4` returns `{:ok, %LangExtract.Result{}}`** (was
  `{:ok, {spans, chunk_errors}}`) — in both `LangExtract.run/4` and
  `Runner.run/4`. The struct binds by key, so future fields (usage,
  timing) can be added without breaking consumer matches; the positional
  tuple could never grow. Migration is mechanical:
  `{:ok, {spans, errors}}` → `{:ok, %LangExtract.Result{spans: spans,
  errors: errors}}`.

- **Tokenizer adopts upstream's letter/digit/symbol-run splitting** —
  possessives and contractions split at the apostrophe (`Tooke’s` →
  `Tooke`·`’`·`s`), numbers split at separators, and symbol runs are
  same-character tokens (`...` is one token). This closes the documented
  contraction-tokenization divergence: bare-name extractions against
  possessive source mentions now ground `exact` instead of `not_found`.
  Measured effect (2026-07-07 baseline): ner not_found 49 → 0 and fuzzy
  44 → 3 — exceeding upstream's own 1 and 45 — with dialogue fuzzy
  15 → 10; see benchmark/BASELINE.md. The `smart_quote_contraction`
  parity case now asserts
  upstream's real result. Chunker sentence rules mirrored to upstream's
  `find_sentence_range`: terminator-run matching (`...` ends sentences),
  abbreviation pairing (`"Dr" <> "."`), and break-unless-lowercase after
  newlines (lines opening with quotes or digits now break). Alignment
  offsets for spans involving contractions/possessives may shift; chunk
  boundaries on decimal-heavy text may differ.

### Fixed

- **`Runner` limiter refill no longer discards fractional tokens** — each
  refill reset the bucket's clock, dropping up to one token's worth of
  elapsed time per refill event; at low `:rpm` the under-delivery was
  proportionally large. Partial tokens now carry into the next refill.

## [0.7.0] - 2026-07-06

### Added

- **`LangExtract.Runner`** — a caller-owned, supervised extraction runner
  with a shared request budget. Place it in your supervision tree with a
  client, `:rpm`, `:max_in_flight`, and `:chunk_retries`; `Runner.run/4`
  and `Runner.stream/4` mirror the standalone APIs but schedule every
  chunk request through one Limiter (token-bucket RPM + in-flight cap),
  so concurrent callers cannot jointly exceed the budget and a single
  429 pauses all admission until the server's `retry-after` deadline.
  The runner owns its retry policy (Req's transient retry is disabled
  inside it): 429 waits never consume the per-chunk retry budget,
  5xx/transport failures take jittered backoff and do, other errors
  fail fast. Stream delivery is bounded — at most `:buffer` undelivered
  results — so a slow consumer throttles admission instead of growing a
  mailbox. `Runner.stream_corpus/4` runs an enumerable of `{id, source}`
  pairs through the same budget. Shutdown drains gracefully: in-flight
  requests get `:drain_timeout` to finish and deliver; unstarted chunks
  come back as `%ChunkError{reason: :drained}`. In runner mode every
  failure is per-chunk; there is no abandon-the-document error path.
  New guide: "Running in Production". New telemetry:
  `[:lang_extract, :limiter, :wait]` (duration, blocking reason, limiter)
  and `[:lang_extract, :chunk, :retry]` (attempt, reason, limiter).
- **`LangExtract.stream/4`** — lazy stream of per-chunk results
  (`{:ok, %Pipeline.ChunkResult{}}` | `{:error, %Pipeline.ChunkError{}}`)
  in completion order, so first spans arrive while later chunks are still
  extracting. `run/4` is now a collect-and-sort consumer of the same
  pipeline — one code path, contract unchanged. Stream mode keeps every
  failure per-chunk (a timed-out chunk is an error event with its byte
  range; survivors keep flowing), where `run/4` retains its
  abandon-the-document `{:error, {:task_exit, reason}}` contract.
  Document telemetry fires at consumption: `:start` on first demand,
  `:stop` at stream end, including early halts.
- **`LangExtract.template/2`** — the front door for building templates:
  accepts plain maps with string or atom keys (JSON-loaded task definitions
  work verbatim), normalizes into structs, and validates examples against
  the production aligner at construction — misaligned examples raise. Pass
  `validate: false` to skip.

### Changed

- **Oversized sentences hard-split at token boundaries** — text without
  sentence boundaries (logs, minified content) previously became one
  whole-document chunk, defeating `:max_chunk_chars`. Sentences past the
  budget now pre-split into token-boundary fragments (byte offsets exact;
  a single token longer than the budget stays whole), matching upstream's
  `ChunkIterator` — verified chunk-count parity on a boundary-free fixture.
- **Runner 429 retries are bounded** — absent a `retry-after` header the
  global pause now escalates exponentially (capped at 30s), and after
  `:rate_limit_retries` 429s on one chunk (default 10) the chunk fails
  with the rate-limit error instead of retrying forever. `retry-after`,
  when present, still sets the pause; rate-limit waits still never
  consume `chunk_retries`.
- **Breaking: decoding is JSON-only — YAML support removed entirely** —
  `WireFormat.normalize/1` no longer falls back to a YAML parser, the YAML
  repair machinery is deleted, and the `yaml_elixir`/`yamerl` dependencies
  are dropped. JSON has been the wire format since 0.6.0 and two of three
  providers constrain JSON at the API level; the tolerance path's
  justification ended with the format switch (audit simplicity finding).
  If you re-parse stored raw responses from the 0.4–0.5 YAML era through
  `extract/3`, convert them to JSON first.
- **Breaking: 429 errors carry the retry-after deadline** —
  `{:error, :rate_limited}` is now `{:error, {:rate_limited, ms | nil}}`;
  the runner's global backoff needs the server's deadline and it only
  exists on that response. Update any code matching on `:rate_limited`.
- **Breaking: `Prompt.Template` is now `LangExtract.Template`; `ExampleData`
  is now `Template.Example`** — template data is core (same promotion
  `Extraction` got in 0.4.0), and the example struct is a subordinate type
  nested in its owner. Construct via `LangExtract.template/2`; the structs
  remain public for pattern matching.
- **`req` constraint tightened to `~> 0.6.0`** (was `~> 0.6`) — pre-1.0
  minors are breaking by convention, so the constraint states what CI
  actually proves.
- **Specs name the provider error union** — the new
  `t:LangExtract.Provider.error/0` type covers every error
  `c:LangExtract.Provider.infer/2` can return; the provider modules,
  `Runner.Request.infer/4`, and `map_response/2` use it instead of
  `{:error, term()}`, and `run/4`'s error spec narrowed to
  `{:error, {:task_exit, term()}}`. Spec-only — no runtime change.

## [0.6.0] - 2026-07-05

### Security

- **Providers no longer follow HTTP redirects** — Req strips only the
  standard `authorization` header on cross-host redirects, so Claude's
  `x-api-key` would have been forwarded to a redirect target. LLM APIs
  never legitimately redirect these POSTs; a 3xx now surfaces as
  `{:error, {:api_error, status, body}}`. Re-enable via
  `req_options: [redirect: true]` if you proxy through something that
  redirects.

### Changed

- **Prompts adopt upstream's Q/A scaffold** — `Examples` heading, `Q:`/`A:`
  pairs, and a trailing bare `A:` answer primer, mirroring langextract's
  `QAPromptGenerator`. Measured effect: ~20% fewer output tokens (reduced
  adaptive-thinking spend), no alignment cost.
- **`req` constraint tightened to `~> 0.6`** — the previous `~> 0.5`
  admitted pre-1.0 minors the test suite has never run against.
- **`WireFormat.normalize/1` parses JSON first** — the strict, fast parser
  handles the (now default) JSON responses; the YAML parser and its repair
  pass remain as the tolerance path for models that answer in YAML.
- **Wire format is now JSON (was YAML)** — `WireFormat.format_extractions/1`
  emits fenced dynamic-key JSON, matching upstream's default; the `ymlr`
  dependency is dropped. Decided by a corpus A/B under the new scaffold:
  zero chunk errors across 440 quote-dense dialogue chunks, better dialogue
  alignment (17 fuzzy / 0 not_found vs 68 / 2), and 25% fewer ner output
  tokens. Decoding is format-agnostic — `WireFormat.normalize/1` accepts
  JSON and YAML responses alike and keeps the YAML repair machinery.

### Fixed

- **`Serializer.from_map/1` validates extraction entries** — entries
  missing `"text"` or carrying a non-string `"class"` now return the
  promised `{:error, :invalid_data}` instead of producing malformed spans.
  Class-less spans (from `align/3`) still round-trip.
- **Chunk task timeouts now return the documented error tuple** — the
  `{:error, {:task_exit, reason}}` shape promised by `run/4` was
  unreachable: `Task.async_stream`'s default `on_timeout: :exit` crashed
  the calling process instead. `on_timeout: :kill_task` makes a timed-out
  chunk surface as the documented infrastructure-failure return.

### Added

- **Telemetry** — `[:lang_extract, :request]`, `[:lang_extract, :chunk]`,
  and `[:lang_extract, :document]` spans (`:telemetry` is now an explicit
  dependency). Request `:stop` events carry input/output token counts
  normalized across all three providers; the benchmark runners record them
  as per-document `usage` blocks with per-request latency.

## [0.5.0] - 2026-07-05

### Added

- **Alignment tuning options** — `:min_density` (LCS token-density floor,
  default 1/3), `:accept_lesser` (toggle prefix matching), and
  `:exact_algorithm` (`:dp` | `:first_occurrence`), accepted by
  `LangExtract.run/4`, `extract/3`, and `align/3`.
- **"Alignment and Spans" hexdocs guide** — span semantics, byte-vs-character
  offsets (`binary_part`, not `String.slice`), the four aligner phases, and
  tuning. The hexdocs sidebar now groups modules by layer, and the
  `align`/`extract` examples run as doctests.

### Changed

- **Aligner ported to upstream langextract v1.6.0 semantics** — the fuzzy
  phase's frequency-overlap sliding window is replaced by upstream's
  difflib-style lesser prefix match plus an LCS dynamic program over
  lightly stemmed tokens, gated by coverage (`:fuzzy_threshold`) and density
  (`:min_density`). Behavior is pinned by differential fixtures generated
  from the upstream aligner. On the dialogue benchmark this took the exact
  rate from 77.5% to 93.7% — identical to Python's 93.7% on the same corpus.
- **Every prompt now demands verbatim spans** — `Prompt.Builder` appends a
  standing instruction requiring extractions to be exact source substrings
  and an empty `extractions: []` on contentless passages. Benchmarked:
  without it, dialogue runs produced dozens of few-shot echoes and stitched
  paraphrases that could not be aligned.
- **Repeated mentions now ground to successive occurrences** — the aligner
  gained a phase-0 monotonic occurrence DP (port of upstream #485): over the
  extraction list in model output order, it selects at most one exact
  occurrence per extraction, order-preserving and non-overlapping,
  maximizing matched tokens. Previously every within-chunk repeat took the
  first occurrence's offsets — 32% of exact spans in the ner benchmark
  landed on an already-claimed position; after the port, offset agreement
  with upstream on repeated mentions with matched counts is 90.9%, on par
  with unique mentions. `exact_algorithm: :first_occurrence` restores the
  old behavior.
- **Chunk stream no longer blocks on the slowest chunk** — the orchestrator's
  `Task.async_stream` now runs `ordered: false` (document order is restored
  by sorting chunk results on their byte offsets), so one slow chunk — e.g. a
  429 riding Req's retry backoff — no longer gates every later chunk launch.
  The default `:max_concurrency` also rises from 3 to 10, matching upstream
  langextract's `max_workers` default.
- **Minimum Elixir raised to 1.15** — plug 1.20 (test dependency, pulled in by
  a security patch) requires Elixir 1.15, and CI can no longer verify 1.14.

### Fixed

- **Claude provider default model updated to `claude-sonnet-5`** — the previous
  default, `claude-sonnet-4-20250514`, was retired upstream on 2026-06-15, so
  `LangExtract.new(:claude)` without an explicit `:model` returned 404s.
- **Gemini provider default model updated to `gemini-3.5-flash`** — tracking
  upstream langextract's default (their #472); `gemini-2.0-flash` is
  approaching retirement, the same failure class as the Claude default.
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
- **Hex package no longer ships the benchmark Mix task** — the
  `benchmark.run` task needs the local `benchmark/` corpus, which was never
  packaged, so the task
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

[0.10.0]: https://github.com/mdepolli/lang_extract/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/mdepolli/lang_extract/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/mdepolli/lang_extract/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/mdepolli/lang_extract/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/mdepolli/lang_extract/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/mdepolli/lang_extract/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mdepolli/lang_extract/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mdepolli/lang_extract/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/mdepolli/lang_extract/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/mdepolli/lang_extract/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mdepolli/lang_extract/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mdepolli/lang_extract/releases/tag/v0.1.0
