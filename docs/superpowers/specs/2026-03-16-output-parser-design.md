# LangExtract Output Parser — Design Spec

## Goal

Add a parser that converts raw LLM output strings into `Extraction` structs, and a convenience function that parses + aligns + merges in one call.

## Context

The library already has a tokenizer and span aligner. The parser sits between the LLM response and the aligner:

```
LLM response (JSON string) → Parser → [%Extraction{}]
                                              ↓
                    source text + extractions → LangExtract.extract/3 → [%Span{}]
                                                (parse + align + merge)
```

Target LLM providers: Gemini (via `response_schema`) and Claude (via tool use). Both return clean, schema-conformant JSON. No YAML support needed.

## Modules

### `LangExtract.Extraction`

A struct representing a single extraction from the LLM output.

```elixir
%Extraction{
  class: "character",          # entity type label
  text: "ROMEO",               # verbatim text to align against source
  attributes: %{}               # arbitrary key-value metadata
}
```

- `class` — required, non-empty string. `@enforce_keys [:class, :text]`
- `text` — required, non-empty string
- `attributes` — optional, defaults to `%{}`

```elixir
@type t :: %__MODULE__{
        class: String.t(),
        text: String.t(),
        attributes: map()
      }
```

### `LangExtract.Span` (modification)

Add optional `class` and `attributes` fields to the existing Span struct:

```elixir
%Span{
  text: "ROMEO",
  byte_start: 42,
  byte_end: 47,
  status: :exact,
  class: "character",          # nil when produced by Aligner directly
  attributes: %{"emotion" => "wonder"}  # %{} when produced by Aligner directly
}
```

Updated defstruct (note mixed keyword/atom syntax for defaults):

```elixir
@enforce_keys [:text, :status]
defstruct [:text, :byte_start, :byte_end, :status, :class, attributes: %{}]
```

Updated type:

```elixir
@type t :: %__MODULE__{
        text: String.t(),
        byte_start: non_neg_integer() | nil,
        byte_end: non_neg_integer() | nil,
        status: status(),
        class: String.t() | nil,
        attributes: map()
      }
```

`class` defaults to `nil`, `attributes` defaults to `%{}`. The Aligner does not set them — they are populated by the top-level `LangExtract.extract/3` convenience function.

### `LangExtract.Parser`

Parses raw LLM output into a list of `Extraction` structs.

**Public API:**

```elixir
@spec parse(String.t()) :: {:ok, [Extraction.t()]} | {:error, :invalid_json | :missing_extractions}

Parser.parse(raw_llm_output)
# => {:ok, [%Extraction{class: "character", text: "ROMEO", attributes: %{"emotion" => "wonder"}}]}
# => {:error, :invalid_json}
# => {:error, :missing_extractions}
```

**Expected JSON schema:**

```json
{
  "extractions": [
    {
      "class": "character",
      "text": "ROMEO",
      "attributes": {"emotion": "wonder"}
    }
  ]
}
```

**Pre-processing:** Before JSON decoding, strip markdown fences if present. Use `Regex.run(~r/```(?:json)?\s*(.*?)\s*```/s, input)` — the `s` modifier enables dotall mode so `.` matches newlines, and `\s*` handles trailing whitespace and `\r\n` line endings. If fences are found, parse the captured content; otherwise parse the original string.

**Parsing steps:**

1. Strip markdown fences if present
2. `Jason.decode/1` the string → on error, return `{:error, :invalid_json}`
3. Extract the `"extractions"` key — must be a list. If key is missing, or value is not a list, return `{:error, :missing_extractions}`
4. For each entry, validate before constructing the struct:
   - `"class"` and `"text"` must be present, non-empty strings. If not (missing, non-string, or empty), skip the entry and log with `Logger.warning/1` (note: `require Logger` in the module)
   - `"attributes"` must be a map if present; default to `%{}` if missing or not a map
   - Only after validation passes, construct the `%Extraction{}` struct (this avoids `@enforce_keys` raising on invalid data)
5. Return `{:ok, extractions}`

### `LangExtract.extract/3` (top-level convenience)

Parses LLM output, aligns against source text, and merges class/attributes onto the resulting spans.

```elixir
@spec extract(String.t(), String.t(), keyword()) ::
        {:ok, [Span.t()]} | {:error, :invalid_json | :missing_extractions}

LangExtract.extract(source_text, raw_llm_output, opts \\ [])
# => {:ok, [%Span{text: "ROMEO", byte_start: 42, byte_end: 47, status: :exact,
#                  class: "character", attributes: %{"emotion" => "wonder"}}]}
```

The first argument is `source_text`, matching the existing `align/3` convention where source is always first.

Implementation:

1. `Parser.parse(raw_llm_output)` → on error, return error
2. Extract texts: `Enum.map(extractions, & &1.text)`
3. `Aligner.align(source_text, texts, opts)` → get spans
4. Zip extractions and spans, merge `class` and `attributes` onto each span
5. Return `{:ok, enriched_spans}`

**Zip safety invariant:** The zip in step 4 is safe because `Parser.parse/1` returns only valid extractions (invalid entries are filtered in the parse step), and `Aligner.align/3` returns exactly one span per input string. Therefore `length(extractions) == length(spans)` is always true.

## Dependencies

- `jason` — add to `mix.exs` deps

## Edge cases to test

### Parser tests
- Valid JSON with all fields → happy path
- JSON wrapped in markdown fences (`` ```json ... ``` ``) → stripped and parsed
- JSON wrapped in plain markdown fences (no language tag) → stripped and parsed
- Missing `attributes` key → defaults to `%{}`
- `attributes` present but not a map → defaults to `%{}`
- Missing `class` or `text` in one entry → that entry skipped, others returned
- `class` or `text` present but not a string (e.g., integer, null) → entry skipped
- `class` or `text` is empty string → entry skipped
- Empty extractions list → `{:ok, []}`
- Completely invalid JSON → `{:error, :invalid_json}`
- Valid JSON but no `"extractions"` key → `{:error, :missing_extractions}`
- `"extractions"` is not a list (null, string, number) → `{:error, :missing_extractions}`
- Nested attributes (maps within maps) → preserved as-is

### Extract convenience function tests
- End-to-end: source text + LLM JSON → enriched spans with class and attributes
- Parser error propagates through

## File structure

```
lib/
├── lang_extract.ex            # add extract/3 convenience function
└── lang_extract/
    ├── extraction.ex          # Extraction struct
    ├── parser.ex              # Parser module
    └── span.ex                # add class/attributes fields
test/lang_extract/
└── parser_test.exs            # Parser + extract tests
```

## Out of scope

- Prompt building / few-shot examples (separate layer)
- LLM provider calls
- YAML parsing
- Schema generation for structured output mode
