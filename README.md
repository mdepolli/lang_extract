# LangExtract

Extract structured data from text using LLMs, with every extraction grounded to
exact byte positions in the source. An Elixir port of
[google/langextract](https://github.com/google/langextract).

```elixir
client = LangExtract.new(:claude, api_key: System.get_env("ANTHROPIC_API_KEY"))

template = %LangExtract.Prompt.Template{
  description: "Extract people and locations from the text.",
  examples: [
    %LangExtract.Prompt.ExampleData{
      text: "Hamlet is set in Denmark.",
      extractions: [
        %LangExtract.Extraction{class: "work", text: "Hamlet", attributes: %{"type" => "play"}},
        %LangExtract.Extraction{class: "location", text: "Denmark", attributes: %{}}
      ]
    }
  ]
}

{:ok, spans} = LangExtract.run(client, "Romeo and Juliet was written by William Shakespeare.", template)

for span <- spans do
  IO.puts("#{span.class}: \"#{span.text}\" [bytes #{span.byte_start}..#{span.byte_end}] (#{span.status})")
end
# person: "William Shakespeare" [bytes 31..50] (exact)
# work: "Romeo and Juliet" [bytes 0..16] (exact)
```

Every extraction maps back to its exact position in the source binary via
`binary_part(source, span.byte_start, span.byte_end - span.byte_start)`.

## Installation

Add `lang_extract` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:lang_extract, "~> 0.1.0"}
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

### 2. Define a prompt template

The template tells the LLM what to extract. Few-shot examples teach it the
output format using dynamic keys — the extraction class name becomes the JSON
key, which reads naturally in context:

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

{:ok, spans} = LangExtract.run(client, source, template)
```

Each span contains:

| Field | Description |
|---|---|
| `text` | The extracted text as returned by the LLM |
| `class` | Entity type (e.g., `"condition"`, `"medication"`) |
| `attributes` | Arbitrary metadata the LLM attached |
| `byte_start` | Inclusive byte offset in source (`nil` if not found) |
| `byte_end` | Exclusive byte offset in source (`nil` if not found) |
| `status` | `:exact`, `:fuzzy`, or `:not_found` |

Verify byte offsets round-trip:

```elixir
for span <- spans, span.byte_start != nil do
  extracted = binary_part(source, span.byte_start, span.byte_end - span.byte_start)
  IO.puts("#{span.class}: #{extracted}")
end
```

## Chunking

For documents that exceed LLM token limits, pass `:max_chunk_size` to split the
source into sentence-aware chunks and process them in parallel:

```elixir
{:ok, spans} = LangExtract.run(client, long_document, template,
  max_chunk_size: 4000,
  max_concurrency: 5
)
```

Byte offsets in the returned spans are adjusted to reference the original source,
not individual chunks. Previous chunk text is passed as context to help the LLM
resolve cross-chunk references.

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
json = ~s({"extractions": [{"class": "animal", "text": "fox"}]})
{:ok, spans} = LangExtract.extract("the quick brown fox", json)
```

Both canonical format (`class`/`text`/`attributes` keys) and dynamic-key format
(`"animal": "fox"`) are accepted. Markdown fences and `<think>` tags are
stripped automatically.

## Serialization

Convert results to plain maps for storage or interop:

```elixir
map = LangExtract.IO.to_map(source, spans)
# %{"text" => "...", "extractions" => [%{"class" => "...", "status" => "exact", ...}]}

{:ok, {source, spans}} = LangExtract.IO.from_map(map)
```

Save and load multiple results as JSONL:

```elixir
LangExtract.IO.save_jsonl([{source1, spans1}, {source2, spans2}], "results.jsonl")
{:ok, results} = LangExtract.IO.load_jsonl("results.jsonl")
```

## Provider Options

All providers accept these common options:

| Option | Default | Description |
|---|---|---|
| `:api_key` | From env var | API key (falls back to provider-specific env var) |
| `:model` | Provider default | Model ID |
| `:max_tokens` | `4096` | Maximum response tokens |
| `:temperature` | `0` | Sampling temperature |
| `:base_url` | Provider default | API base URL |

Environment variable fallbacks: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GEMINI_API_KEY`.

Provider-specific options:

| Provider | Option | Default | Description |
|---|---|---|---|
| `:openai` | `:json_mode` | `true` | Enable JSON mode. Set `false` for compatible endpoints that don't support it. |

## How It Works

The pipeline has five stages:

```
1. Prompt Builder    — Renders few-shot Q&A prompt with dynamic-key examples
2. LLM Provider      — Calls Claude/OpenAI/Gemini via Req
3. Format Handler    — Strips fences/<think> tags, normalizes dynamic keys to canonical form
4. Parser            — Validates and constructs Extraction structs
5. Aligner           — Maps extraction text to byte positions via Myers diff + fuzzy fallback
```

The aligner uses two phases:

- **Phase 1 (Exact)**: `List.myers_difference/2` on downcased word tokens.
  If a contiguous equal segment covers all extraction tokens, it's an exact match.
- **Phase 2 (Fuzzy)**: Sliding window with token frequency overlap. The window
  with the highest overlap ratio above `:fuzzy_threshold` (default 0.75) wins.

## Architecture

```
lib/lang_extract/
├── alignment/              # Tokenizer, Token, Aligner, Span
├── prompt/                 # Template, ExampleData, Builder, Validator
├── provider/               # Claude, OpenAI, Gemini implementations
├── client.ex               # Configured LLM client struct
├── orchestrator.ex         # Pipeline wiring + chunking
├── chunker.ex              # Sentence-aware text splitting
├── format_handler.ex       # External ↔ internal format port
├── parser.ex               # JSON → Extraction structs
├── extraction.ex           # Extraction struct
└── io.ex                   # Serialization + JSONL
```

## Compared to the Python Original

This is an Elixir port of [google/langextract](https://github.com/google/langextract).
Key differences:

| | Python | Elixir |
|---|---|---|
| Codebase | ~4,000 LOC | ~1,400 LOC |
| Providers | Gemini, OpenAI, Ollama | Claude, OpenAI, Gemini |
| Offsets | Character positions | Byte positions |
| Parallelism | ThreadPoolExecutor | Task.async_stream |
| Chunking | Always-on | Opt-in via `:max_chunk_size` |
| Alignment statuses | 4 (exact, lesser, greater, fuzzy) | 3 (exact, fuzzy, not_found) |
| Prompt validation | Built-in severity levels | Caller decides |

Not ported: visualization (HTML output), multi-pass extraction, YAML support,
batch Vertex AI, plugin system. See [ROADMAP.md](ROADMAP.md) for planned
improvements.

## License

See [LICENSE](LICENSE) for details.
