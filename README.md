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

template = %LangExtract.Prompt.Template{
  description: "Extract literary works, people, and locations from the text.",
  examples: [
    %LangExtract.Prompt.ExampleData{
      text: "Dickens wrote Oliver Twist while living in London.",
      extractions: [
        %LangExtract.Extraction{class: "person", text: "Dickens"},
        %LangExtract.Extraction{class: "work", text: "Oliver Twist", attributes: %{"type" => "novel"}},
        %LangExtract.Extraction{class: "location", text: "London"}
      ]
    }
  ]
}

{:ok, {spans, _errors}} = LangExtract.run(client, "Romeo and Juliet was written by William Shakespeare.", template)

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
    {:lang_extract, "~> 0.5.0"}
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
examples double as alignment ground truth, and the validator (below) checks
this before you spend tokens.

```elixir
template = %LangExtract.Prompt.Template{
  description: "Extract medical conditions and medications from clinical text.",
  examples: [
    %LangExtract.Prompt.ExampleData{
      text: "Patient was diagnosed with diabetes and prescribed metformin.",
      extractions: [
        %LangExtract.Extraction{
          class: "condition",
          text: "diabetes",
          attributes: %{"chronicity" => "chronic"}
        },
        %LangExtract.Extraction{
          class: "medication",
          text: "metformin",
          attributes: %{}
        }
      ]
    }
  ]
}
```

### 3. Run extraction

```elixir
source = "The patient presents with hypertension and is taking lisinopril daily."

{:ok, {spans, errors}} = LangExtract.run(client, source, template)
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

## Chunking

For documents that exceed LLM token limits, pass `:max_chunk_chars` to split the
source into sentence-aware chunks and process them in parallel:

```elixir
{:ok, {spans, errors}} = LangExtract.run(client, long_document, template,
  max_chunk_chars: 4000,
  max_concurrency: 5
)
```

Byte offsets in the returned spans are adjusted to reference the original source,
not individual chunks.

## Prompt Validation

Validate that your few-shot examples actually align with their own source text
before burning LLM tokens:

```elixir
# Returns :ok or {:error, [issues]}
:ok = LangExtract.Prompt.Validator.validate(template)

# Or raise on failure
:ok = LangExtract.Prompt.Validator.validate!(template)
```

The validator reports what it finds. You decide what to do — log, raise, or
ignore. No built-in severity levels.

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
# JSON is the wire format; YAML responses are also accepted
raw = ~s({"extractions": [{"class": "animal", "text": "fox"}]})
{:ok, spans} = LangExtract.extract("the quick brown fox", raw)
```

Both canonical format (`class`/`text`/`attributes` keys) and dynamic-key format
(`"animal": "fox"`) are accepted. Markdown fences and `<think>` tags are
stripped automatically.

## Serialization

Convert results to plain maps for storage or interop:

```elixir
map = LangExtract.Serializer.to_map(source, spans)
# %{"text" => "...", "extractions" => [%{"class" => "...", "status" => "exact", ...}]}

{:ok, {source, spans}} = LangExtract.Serializer.from_map(map)
```

Save and load multiple results as JSONL:

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
├── alignment/              # Tokenizer, Token, Aligner, Span
├── pipeline/               # Parser, ChunkError
├── prompt/                 # Template, ExampleData, Builder, Validator
├── provider/               # Claude, OpenAI, Gemini implementations
├── client.ex               # Configured LLM client struct
├── extraction.ex           # Core extraction struct
├── wire_format.ex          # LLM wire format (encode + decode)
├── orchestrator.ex         # Pipeline wiring + chunking
├── chunker.ex              # Sentence-aware text splitting
├── pipeline.ex             # Extraction pipeline public API
└── serializer.ex           # Serialization + JSONL
```

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
