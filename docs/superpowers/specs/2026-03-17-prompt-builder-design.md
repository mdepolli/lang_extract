# LangExtract Prompt Builder & Format Handler — Design Spec

## Goal

Add a format handler (hexagonal port) and prompt builder that together enable constructing few-shot Q&A prompts for LLM extraction, while normalizing LLM output back into internal domain structs.

## Architecture

```
                         External                    Internal Domain
                    ┌─────────────────┐          ┌─────────────────────┐
Prompt building:    │  FormatHandler   │ ←──────  │  Extraction structs  │
                    │  (serializes to  │          │  (class/text/attrs)  │
                    │   dynamic keys)  │          └─────────────────────┘
                    └─────────────────┘
                                                 ┌─────────────────────┐
LLM output:         ┌─────────────────┐          │                     │
  raw string ──────→│  FormatHandler   │────────→ │  Parser             │
                    │  (strips fences, │          │  (canonical JSON →  │
                    │   normalizes to  │          │   Extraction structs)│
                    │   canonical form)│          │                     │
                    └─────────────────┘          └─────────────────────┘
```

The format handler is a port in the hexagonal architecture sense — it isolates the external LLM format (dynamic keys, fences, `<think>` tags) from the internal domain (canonical `class`/`text`/`attributes` structs). The parser never sees external format concerns.

## External vs Internal Format

**External (dynamic-key format)** — what the LLM sees in prompts and produces in output:

```json
{
  "extractions": [
    {
      "medical_condition": "hypertension",
      "medical_condition_attributes": {
        "chronicity": "chronic",
        "system": "cardiovascular"
      }
    }
  ]
}
```

The extraction class is the key, and attributes use a `_attributes` suffix. This reads naturally in context — the LLM learns by example what "medical_condition" means.

**Internal (canonical format)** — what our code works with:

```json
{
  "extractions": [
    {
      "class": "medical_condition",
      "text": "hypertension",
      "attributes": {
        "chronicity": "chronic",
        "system": "cardiovascular"
      }
    }
  ]
}
```

Explicit, uniform keys that map directly to `%Extraction{class: ..., text: ..., attributes: ...}`.

## Modules

### `LangExtract.FormatHandler`

The port between external LLM format and internal domain. Handles both directions.

**Serialization (for prompts):**

```elixir
@spec format_extractions([Extraction.t()]) :: String.t()
FormatHandler.format_extractions(extractions)
# => "```json\n{\"extractions\": [{\"medical_condition\": \"hypertension\", ...}]}\n```"
```

Converts `Extraction` structs to dynamic-key JSON wrapped in markdown fences. Each extraction becomes `{<class>: <text>, <class>_attributes: <attributes>}`. Wrapped in `{"extractions": [...]}`.

**Normalization (for LLM output):**

```elixir
@spec normalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_format}
FormatHandler.normalize(raw_llm_output)
# => {:ok, "{\"extractions\": [{\"class\": \"medical_condition\", \"text\": \"hypertension\", ...}]}"}
```

Takes raw LLM output and:

1. Strips `<think>...</think>` tags (reasoning model output). Uses `~r/<think>.*?<\/think>/s` (non-greedy, dotall mode). Strips all occurrences. If an opening `<think>` has no closing tag, strips from `<think>` to end of string. This happens before JSON parsing, so think tags inside JSON string values are not a concern.
2. Strips markdown fences (`` ```json ... ``` ``)
3. JSON-decodes to access the structure
4. Converts dynamic-key entries to canonical `class`/`text`/`attributes` form
5. Re-encodes to canonical JSON string

Returns a clean JSON string that the parser can handle directly.

**Dynamic-key normalization logic:**

For each entry in the `"extractions"` list, the entry is a map. The format handler:

0. **Canonical detection:** If the entry already has both `"class"` and `"text"` keys, it's already in canonical format — pass through as-is. This ensures `normalize/1` is idempotent on canonical input.
1. Collects all keys ending in `_attributes`, but **only if a corresponding prefix key exists** in the same entry. E.g., `"medical_condition_attributes"` is only treated as attributes if `"medical_condition"` also exists as a key. This prevents false matches on class names that naturally end in `_attributes` (e.g., `"html_attributes"`).
2. The remaining keys (excluding matched `_attributes` keys) are class/text pairs: the key is the class, the value is the text.
3. If an entry has exactly one class key and zero or one matched `_attributes` keys, it's valid.
4. Constructs `{"class": <key>, "text": <value>, "attributes": <attrs>}`.

If an entry doesn't conform (e.g., multiple non-attribute keys, or no keys at all), it's passed through as-is and the parser's validation will skip it.

**Configuration:**

```elixir
@attribute_suffix "_attributes"
```

JSON-only for now. YAML support can be added later behind this same interface without touching the parser or domain layer.

### `LangExtract.Parser` (modified)

The parser is simplified — it no longer handles fence stripping (that's the format handler's job). It only knows about canonical format.

**Current responsibilities that move to FormatHandler:**
- Markdown fence stripping (`@fence_pattern`)

**Breaking change:** Two existing parser tests (`"strips markdown fences with json language tag"` and `"strips markdown fences without language tag"`) test fence stripping as a parser capability. These tests must be migrated to `FormatHandler` tests. The parser's moduledoc must be updated to remove mention of fence stripping.

**Retained responsibilities:**
- `Jason.decode/1` the canonical JSON string
- Extract and validate the `"extractions"` key
- Validate each entry (`class` and `text` must be non-empty strings, `attributes` must be a map)
- Construct `%Extraction{}` structs
- Skip invalid entries with `Logger.warning/1`

**Updated public API:**

```elixir
@spec parse(String.t()) ::
        {:ok, [Extraction.t()]} | {:error, :invalid_json | :missing_extractions}
Parser.parse(canonical_json)
```

The input is now expected to be canonical-format JSON (no fences, no dynamic keys). The caller (typically `LangExtract.extract/3`) runs `FormatHandler.normalize/1` first.

### `LangExtract.PromptTemplate`

A struct holding the extraction task description and few-shot examples.

```elixir
%PromptTemplate{
  description: "Extract medical conditions and medications from clinical text.",
  examples: [
    %ExampleData{
      text: "The patient was diagnosed with hypertension and prescribed lisinopril.",
      extractions: [
        %Extraction{class: "medical_condition", text: "hypertension", attributes: %{"chronicity" => "chronic"}},
        %Extraction{class: "medication", text: "lisinopril", attributes: %{}}
      ]
    }
  ]
}
```

```elixir
@type t :: %__MODULE__{
        description: String.t(),
        examples: [ExampleData.t()]
      }

@enforce_keys [:description]
defstruct [:description, examples: []]
```

### `LangExtract.ExampleData`

A struct holding a single few-shot example: source text and expected extractions.

```elixir
@type t :: %__MODULE__{
        text: String.t(),
        extractions: [Extraction.t()]
      }

@enforce_keys [:text]
defstruct [:text, extractions: []]
```

### `LangExtract.PromptBuilder`

Renders Q&A-formatted prompts from a template and format handler.

**Public API:**

```elixir
@spec build(PromptTemplate.t(), String.t(), keyword()) :: String.t()
PromptBuilder.build(template, chunk_text, opts \\ [])
```

**Options:**

- `:previous_chunk` — text from the previous chunk for cross-chunk coreference (default: `nil`)
- `:context_window_chars` — how many trailing characters of the previous chunk to include (default: `nil`, meaning use full previous chunk text if provided)

**Output format:**

```
<description>

<example 1 text>
```json
<example 1 extractions in dynamic-key format>
```

<example 2 text>
```json
<example 2 extractions in dynamic-key format>
```

[Previous text]: ...<trailing context from previous chunk>

<chunk_text>
```

The prompt follows the Q&A pattern from the original library. The description comes first, then each few-shot example (text followed by formatted extractions), then optional previous-chunk context, then the actual text to extract from.

**Stateless design:** The caller (orchestrator) is responsible for tracking chunk sequences and passing `previous_chunk` explicitly. No per-document state held in the builder. If we find that a stateful builder would simplify the orchestrator later, we can add one.

## Integration with `LangExtract.extract/3`

The top-level convenience function is updated to use the format handler:

```elixir
@spec extract(String.t(), String.t(), keyword()) ::
        {:ok, [Span.t()]} | {:error, :invalid_format | :invalid_json | :missing_extractions}

def extract(source, raw_llm_output, opts \\ []) do
  with {:ok, canonical} <- FormatHandler.normalize(raw_llm_output),
       {:ok, extractions} <- Parser.parse(canonical) do
    texts = Enum.map(extractions, & &1.text)
    spans = Aligner.align(source, texts, opts)

    enriched =
      Enum.zip(extractions, spans)
      |> Enum.map(fn {extraction, span} ->
        %Span{span | class: extraction.class, attributes: extraction.attributes}
      end)

    {:ok, enriched}
  end
end
```

Note: The typespec now includes `:invalid_format` from `FormatHandler.normalize/1` alongside `:invalid_json` and `:missing_extractions` from `Parser.parse/1`.

Existing `extract/3` tests use canonical format, which `normalize/1` passes through unchanged (canonical detection in step 0).

## File Structure

```
lib/lang_extract/
├── format_handler.ex      # NEW: port between external and internal format
├── prompt_template.ex     # NEW: PromptTemplate struct
├── example_data.ex        # NEW: ExampleData struct
├── prompt_builder.ex      # NEW: Q&A prompt renderer
├── parser.ex              # MODIFIED: remove fence stripping, canonical-only
├── extraction.ex          # unchanged
├── span.ex                # unchanged
├── token.ex               # unchanged
├── tokenizer.ex           # unchanged
└── aligner.ex             # unchanged
```

## Edge Cases to Test

### FormatHandler — Serialization
- Single extraction → dynamic-key JSON with fences
- Multiple extractions → ordered list
- Extraction with no attributes → `<class>_attributes` key with empty map
- Extraction with nested attributes → preserved as-is

### FormatHandler — Normalization
- Dynamic-key JSON → canonical format
- Already-canonical JSON → passed through unchanged
- `<think>...</think>` tags stripped before processing
- `<think>` without closing tag → strip from `<think>` to end of string
- Multiple `<think>` blocks → all stripped
- Markdown fences stripped
- Fences with and without language tag
- Entry with multiple non-attribute keys → passed through for parser to skip
- Entry with no recognizable keys → passed through for parser to skip
- `_attributes` key without matching prefix key → treated as a class key, not attributes
- Invalid JSON → `{:error, :invalid_format}`

### FormatHandler — Round-trip
- `format_extractions(extractions) |> normalize() |> Parser.parse()` returns the same extractions

### PromptBuilder
- Template with no examples → description + chunk text only
- Template with examples → description + formatted examples + chunk text
- With previous chunk context → `[Previous text]: ...` section included
- With `context_window_chars` → only trailing N chars of previous chunk
- Without previous chunk → no context section
- Empty description → still valid (just examples + text)

### Parser (after modification)
- Existing canonical-format tests should pass unchanged
- Two fence-stripping tests migrated to FormatHandler tests
- No longer strips fences (that's the format handler's job)

## Out of Scope

- YAML format support (JSON only for now; can be added to FormatHandler later)
- Template loading from files (can be added later)
- Prompt validation (separate component per development plan)
- Stateful chunk tracking (caller passes previous chunk explicitly)
