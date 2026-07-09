# LangExtract

[![Hex.pm](https://img.shields.io/hexpm/v/lang_extract)](https://hex.pm/packages/lang_extract)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue)](https://hexdocs.pm/lang_extract)
[![CI](https://github.com/mdepolli/lang_extract/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mdepolli/lang_extract/actions/workflows/ci.yml)

Extract structured data from text using LLMs, with every extraction grounded to
exact byte positions in the source. An Elixir port of
[google/langextract](https://github.com/google/langextract).

You give it two things: a **client** (which LLM to call) and a **template**
(the task definition). There is no schema DSL and no fine-tuned model — the
template is a plain-language description of what to extract, plus at least one
worked example: a sample text with the extractions you'd expect back from it.
That example is what teaches the model your class names, your span
granularity, and the output format:

```elixir
client = LangExtract.new(:claude, api_key: System.get_env("ANTHROPIC_API_KEY"))

template =
  LangExtract.template!("Extract literary works, people, and locations from the text.",
    examples: [
      %{text: "Dickens wrote Oliver Twist while living in London.",
        extractions: [
          %{class: "person", text: "Dickens"},
          %{class: "work", text: "Oliver Twist", attributes: %{"type" => "novel"}},
          %{class: "location", text: "London"}
        ]}
    ]
  )

{:ok, %LangExtract.Result{spans: spans}} = LangExtract.run(client, "Romeo and Juliet was written by William Shakespeare.", template)

for span <- spans do
  IO.puts("#{span.class}: \"#{span.text}\" [bytes #{span.byte_start}..#{span.byte_end}] (#{span.status})")
end
# work: "Romeo and Juliet" [bytes 0..16] (exact)
# person: "William Shakespeare" [bytes 32..51] (exact)
```

Every extraction maps back to its exact position in the source binary via
`binary_part(source, span.byte_start, span.byte_end - span.byte_start)`.

## Installation

Add `lang_extract` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:lang_extract, "~> 0.8.0"}
  ]
end
```

LangExtract uses [Req](https://hex.pm/packages/req) for HTTP calls. No
additional adapter configuration is needed.

## Quick Start

### 1. Create a client

```elixir
client = LangExtract.new(:claude, api_key: "sk-ant-...")
```

Supported providers: `:claude`, `:openai`, `:gemini`.

Provider-specific options are passed as keyword arguments:

```elixir
# OpenAI with a specific model
client = LangExtract.new(:openai, api_key: "sk-...", model: "gpt-4o")

# Gemini
client = LangExtract.new(:gemini, api_key: "gm-...")

# OpenAI-compatible endpoint (Ollama, vLLM, etc.)
client = LangExtract.new(:openai,
  api_key: "not-needed",
  base_url: "http://localhost:11434",
  json_mode: false
)
```

> **Note:** the Gemini API takes the key as a URL query parameter (unlike
> Claude and OpenAI, which use headers), so request URLs contain the secret.
> Avoid logging request URLs (e.g. via custom Req steps or verbose HTTP
> logging) when using the Gemini provider.

### 2. Define a prompt template

The template is the task definition — the only place the model learns what
"right" looks like. It has two parts:

- **`description`** — a plain-language instruction: what to extract.
- **`examples`** — worked examples: a sample `text` paired with the
  extractions you would expect from it.

The extractions inside each example are the answer key for its sample text.
They pin down everything the description leaves open: the class vocabulary
(`"condition"`, not `"diagnosis"`), the span granularity (`"diabetes"`, not
`"diagnosed with diabetes"`), which attributes to attach, and the exact
output shape — the class name becomes the JSON key in the model's reply, so
the examples also teach the wire format. A description alone would leave the
model to invent all of that.

Each extraction's `text` must appear verbatim in its example's `text`: the
examples double as alignment ground truth, and `LangExtract.template!/2`
checks this at construction — a template that builds is a template whose
examples align. (Pass `validate: false` to skip the check, or use
`LangExtract.template/2` for tagged tuples instead of raises when the
task definition arrives at runtime.)

```elixir
template =
  LangExtract.template!("Extract medical conditions and medications from clinical text.",
    examples: [
      %{text: "Patient was diagnosed with diabetes and prescribed metformin.",
        extractions: [
          %{class: "condition", text: "diabetes", attributes: %{"chronicity" => "chronic"}},
          %{class: "medication", text: "metformin"}
        ]}
    ]
  )
```

Examples accept string keys too, so a template loaded from JSON passes
through verbatim. The underlying structs (`LangExtract.Template`,
`Template.Example`) are public for pattern matching and introspection.

### 3. Run extraction

```elixir
source = "The patient presents with hypertension and is taking lisinopril daily."

{:ok, %LangExtract.Result{spans: spans, errors: errors}} = LangExtract.run(client, source, template)
```

When some chunks fail to parse, the successful spans are still returned alongside
the errors. Check `errors` to detect failures. Infrastructure failures (task exits,
timeouts) return `{:error, reason}` instead.

Each span contains:

| Field        | Description                                          |
| ------------ | ---------------------------------------------------- |
| `text`       | The extracted text as returned by the LLM            |
| `class`      | Entity type (e.g., `"condition"`, `"medication"`)    |
| `attributes` | Arbitrary metadata the LLM attached                  |
| `byte_start` | Inclusive byte offset in source (`nil` if not found) |
| `byte_end`   | Exclusive byte offset in source (`nil` if not found) |
| `status`     | `:exact`, `:fuzzy`, or `:not_found`                  |

Verify byte offsets round-trip:

```elixir
for span <- spans, span.byte_start != nil do
  extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
  IO.puts("#{span.class}: #{extracted}")
end
```

## Streaming

`stream/4` yields each chunk's outcome the moment it completes — first
results appear while the rest of the document is still being extracted:

```elixir
client
|> LangExtract.stream(document, template)
|> Enum.each(fn
  {:ok, chunk_result} -> send(live_view, {:spans, chunk_result.spans})
  {:error, chunk_error} -> send(live_view, {:chunk_failed, chunk_error})
end)
```

Events arrive in **completion order**, not document order; every event
carries its chunk's byte range, so consumers who need order sort and
consumers who need latency don't wait. The stream is lazy — nothing runs
until consumed, and a slow consumer naturally limits in-flight requests.

Failure semantics differ from `run/4` deliberately: in stream mode every
failure stays per-chunk. A timed-out chunk arrives as
`{:error, %ChunkError{reason: {:task_exit, :timeout}}}` with its byte range
and the surviving chunks keep flowing, where `run/4` abandons the document
with `{:error, {:task_exit, reason}}`.

## Chunking

For documents that exceed LLM token limits, pass `:max_chunk_chars` to split the
source into sentence-aware chunks and process them in parallel:

```elixir
{:ok, %LangExtract.Result{spans: spans, errors: errors}} = LangExtract.run(client, long_document, template,
  max_chunk_chars: 4000,
  max_concurrency: 5
)
```

Chunk size is measured in characters (`String.length/1`); span offsets are
always bytes. Byte offsets in the returned spans are adjusted to reference
the original source, not individual chunks.

## Prompt Validation

`LangExtract.template!/2` validates at construction, so most code never calls
the validator directly. It stays public for templates built with
`validate: false` or assembled as structs by hand:

```elixir
# Returns :ok or {:error, [issues]}
:ok = LangExtract.Prompt.Validator.validate(template)

# Or raise on failure
:ok = LangExtract.Prompt.Validator.validate!(template)
```

Validation uses the production aligner, so a passing template predicts how
the same extractions align at runtime.

## Alignment Without an LLM

If you already have extraction strings (e.g., from a different source), you can
align them against source text directly:

```elixir
spans = LangExtract.align("the quick brown fox", ["quick brown", "fox"])
# [%Span{text: "quick brown", byte_start: 4, byte_end: 15, status: :exact},
#  %Span{text: "fox", byte_start: 16, byte_end: 19, status: :exact}]
```

Or parse raw LLM output and align in one step:

```elixir
raw = ~s({"extractions": [{"class": "animal", "text": "fox"}]})
{:ok, spans} = LangExtract.extract("the quick brown fox", raw)
```

Both canonical format (`class`/`text`/`attributes` keys) and dynamic-key format
(`"animal": "fox"`) are accepted. Markdown fences and `<think>` tags are
stripped automatically.

## Serialization

Store a full run faithfully — spans, errors, and usage together:

```elixir
{:ok, result} = LangExtract.run(client, source, template)

map = LangExtract.Serializer.result_to_map(source, result)
# %{"text" => "...", "extractions" => [...], "errors" => [...], "usage" => %{...}}

{:ok, {source, result}} = LangExtract.Serializer.result_from_map(map)
```

Error reasons are open terms, so they serialize as their `inspect/1`
rendering — JSON-safe, but one-way: loaded errors carry the rendered
string, not the original term.

For bare span lists (e.g. from `align/3`), the span-level pair applies:

```elixir
map = LangExtract.Serializer.to_map(source, spans)
# %{"text" => "...", "extractions" => [%{"class" => "...", "status" => "exact", ...}]}

{:ok, {source, spans}} = LangExtract.Serializer.from_map(map)
```

Save and load multiple span-level results as JSONL:

```elixir
LangExtract.Serializer.save_jsonl([{source1, spans1}, {source2, spans2}], "results.jsonl")
{:ok, results} = LangExtract.Serializer.load_jsonl("results.jsonl")
```

## Provider Options

All providers accept these common options:

| Option         | Default          | Description                                                              |
| -------------- | ---------------- | ------------------------------------------------------------------------ |
| `:api_key`     | From env var     | API key (falls back to provider-specific env var)                        |
| `:model`       | Provider default | Model ID                                                                 |
| `:max_tokens`  | `4096`           | Maximum response tokens                                                  |
| `:temperature` | `0` (OpenAI/Gemini); unset (Claude) | Sampling temperature. The Claude provider omits it unless set — `claude-sonnet-5` rejects non-default values |
| `:base_url`    | Provider default | API base URL                                                             |
| `:req_options` | `[]`             | Extra [Req](https://hex.pm/packages/req) options merged into the request |

Environment variable fallbacks: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GEMINI_API_KEY`.

HTTP defaults suit LLM latency: 120s receive timeout and transient retries
(429/5xx/transport errors). Override either via `:req_options`, e.g.
`req_options: [receive_timeout: 30_000, retry: false]`.

Provider-specific options:

| Provider  | Option       | Default | Description                                                                   |
| --------- | ------------ | ------- | ----------------------------------------------------------------------------- |
| `:openai` | `:json_mode` | `true`  | Enable JSON mode. Set `false` for compatible endpoints that don't support it. |

## Production: the supervised Runner

For applications extracting continuously, `LangExtract.Runner` puts a
shared request budget in your supervision tree:

```elixir
# application.ex
{LangExtract.Runner,
 name: MyApp.Extractor,
 client: LangExtract.new(:claude, api_key: key),
 max_in_flight: 20,
 rpm: 2_000}

# anywhere in the app — same shapes as run/4 and stream/4:
Runner.run(MyApp.Extractor, source, template)
Runner.stream(MyApp.Extractor, source, template)
Runner.stream_corpus(MyApp.Extractor, [{id, source}, ...], template)
```

Concurrent callers share the budget; one 429 pauses all admission until
the server's `retry-after` deadline; retries follow the runner's policy
(429 waits are free, 5xx/transport consume a per-chunk budget); stream
delivery is bounded so slow consumers throttle admission; and shutdown
drains gracefully — in-flight requests finish, unstarted chunks come back
as `%ChunkError{reason: :drained}`.

Despite the matching shapes, `Runner.run/4` is not a drop-in for
`LangExtract.run/4`: the runner retries failures into per-chunk errors and
never returns `{:error, _}`, while the standalone function abandons the
document on a task exit. See the
[production guide](guides/production.md) for sizing and the full
failure-semantics table.

## Telemetry

LangExtract emits `:telemetry` spans at document, chunk, and request level —
request events carry input/output token counts for cost tracking. See the
[Telemetry guide](guides/telemetry.md) for the event reference and examples.

## How It Works

The pipeline has five stages:

```
1. Prompt Builder    — Renders few-shot Q&A prompt with dynamic-key examples
2. LLM Provider      — Calls Claude/OpenAI/Gemini via Req
3. Wire Format       — Strips fences/<think> tags, normalizes dynamic keys to canonical form
4. Parser            — Validates and constructs Extraction structs
5. Aligner           — Maps extraction text to byte positions (exact scan, then fuzzy fallbacks)
```

The aligner mirrors upstream langextract v1.6.0 (+ #485) semantics in four
phases:

- **Occurrence DP**: Over the whole extraction list, selects one exact
  occurrence per extraction — order-preserving, non-overlapping, maximizing
  matched tokens — so repeated mentions ground to successive occurrences.
  Unplaced extractions fall through to the phases below.
- **Exact**: Linear scan for the extraction's downcased word tokens as a
  contiguous run in the source tokens. First occurrence wins.
- **Lesser (prefix match)**: When the model stitches or truncates a span, the
  longest matching token block anchored at the extraction's first token
  grounds it to its opening fragment in the source (status `:fuzzy`;
  disable with `accept_lesser: false`).
- **LCS fuzzy**: Longest-common-subsequence dynamic program over normalized
  (stemmed, downcased) tokens. Accepts the tightest source window with
  coverage ≥ `:fuzzy_threshold` (default 0.75) and token density ≥
  `:min_density` (default 1/3); status `:fuzzy`.

## Architecture

```
lib/lang_extract/
├── alignment/              # Tokenizer, Token, Aligner
├── pipeline/               # Parser
├── prompt/                 # Builder, Validator
├── provider/               # Claude, OpenAI, Gemini implementations
├── runner/                 # Limiter, Request, Delivery
├── chunk_error.ex          # Failed chunk: byte range + reason
├── chunk_result.ex         # Successful chunk: byte range + spans + usage
├── chunker.ex              # Sentence-aware text splitting
├── client.ex               # Configured LLM client struct
├── extraction.ex           # Core extraction struct
├── orchestrator.ex         # Pipeline wiring + chunking
├── pipeline.ex             # Extraction pipeline API
├── result.ex               # run/4 success value: spans + errors + usage
├── runner.ex               # Supervised runner with a shared request budget
├── serializer.ex           # Serialization + JSONL
├── span.ex                 # Grounded extraction: byte offsets + status
├── template.ex             # Task definition (+ Template.Example)
└── wire_format.ex          # LLM wire format (encode + decode)
```

## Stability

The docs group modules by tier; SemVer applies to the **Core API** tier.

**Core API** — the contract. `LangExtract` and `LangExtract.Runner` are the
entry points. The structs they hand out are stable to match on: `Result`,
`Span`, `ChunkError`, `ChunkResult`, and `Provider.Response` freely;
`Template`, `Template.Example`, and `Extraction` are public for matching
and introspection but constructed via `template!/2`, not struct literals.
`Client` is opaque — build it with `new/2`, hold it, pass it. The
`Provider` behaviour (callbacks plus `t:LangExtract.Provider.error/0`),
`Serializer`, `Prompt.Validator`, and the telemetry events documented in
the telemetry guide complete the contract.

**Advanced** — public and documented, best-effort stability: `WireFormat`,
`Chunker`, `Aligner`, `Pipeline`, `Prompt.Builder`. Changes land in minor
releases with changelog notice.

**Providers** — the built-in implementations behind `new/2`'s `:claude`,
`:openai`, and `:gemini`. Use them via the atom; the modules themselves
carry no stability guarantee beyond the `Provider` behaviour they
implement.

**Internal** — no guarantees: `Orchestrator`, `Pipeline.Parser`,
`Runner.{Limiter,Request,Delivery}`, `Tokenizer`, `Token`. Their docs
stay published because they explain how the library works, not because
they're API.

## Compared to the Python Original

This is an Elixir port of [google/langextract](https://github.com/google/langextract).
Key differences:

|                    | Python                            | Elixir                               |
| ------------------ | --------------------------------- | ------------------------------------ |
| Codebase           | ~4,000 LOC                        | ~2,000 LOC                           |
| Providers          | Gemini, OpenAI, Ollama            | Claude, OpenAI, Gemini               |
| Offsets            | Character positions               | Byte positions                       |
| Parallelism        | ThreadPoolExecutor                | Task.async_stream                    |
| Chunking           | Always-on (1000 chars)            | Always-on (1000 chars, configurable) |
| Alignment statuses | 4 (exact, lesser, greater, fuzzy) | 3 (exact, fuzzy, not_found)          |
| Prompt validation  | Built-in severity levels          | Caller decides                       |

Not ported: visualization (HTML output), multi-pass extraction,
batch Vertex AI, plugin system. See the
[roadmap](https://github.com/mdepolli/lang_extract/blob/main/ROADMAP.md)
for planned improvements.

## License

MIT — see the
[LICENSE](https://github.com/mdepolli/lang_extract/blob/main/LICENSE) file
for details.
