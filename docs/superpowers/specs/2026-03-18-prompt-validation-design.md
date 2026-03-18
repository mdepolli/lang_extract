# LangExtract Prompt Validation — Design Spec

## Goal

Add a prompt validator that checks whether few-shot examples in a `PromptTemplate` are self-consistent — each extraction text should align exactly against its own example's source text. Catches typos, hallucinated spans, and copy-paste errors before they reach the LLM.

## Architecture

The validator sits between template construction and prompt building. It depends only on the `Aligner` (already built) and the `PromptTemplate`/`ExampleData`/`Extraction` structs.

```
PromptTemplate
  → PromptValidator.validate/1   (optional pre-flight check)
  → PromptBuilder.build/3        (prompt construction)
```

The validator is a pure function with no side effects, no logging, and no severity system. It reports what it finds; the caller decides what to do.

## Design Decision: Caller Decides Severity

The original Python library bakes severity into the validator via a `PromptValidationLevel` enum (`OFF`, `WARNING`, `ERROR`). We deliberately do not replicate this.

**Rationale:** Elixir's pattern matching and `!/` convention make severity levels redundant. The three behaviors map naturally:

| Python `PromptValidationLevel` | Elixir equivalent |
|---|---|
| `OFF` | Don't call the validator |
| `WARNING` | Call `validate/1`, log on `{:error, issues}` |
| `ERROR` | Call `validate!/1` (raises on failure) |

This keeps the validator simple (pure data in, pure data out) and gives callers full control over error handling. It follows the same convention as `Jason.decode/1` vs `Jason.decode!/1`.

**Usage examples:**

```elixir
# Development: warn and continue
case PromptValidator.validate(template) do
  :ok -> :ok
  {:error, issues} ->
    Logger.warning("Prompt examples have alignment issues: #{inspect(issues)}")
end

# CI / production: hard fail
:ok = PromptValidator.validate!(template)

# Skip validation entirely: just don't call it
```

## Modules

### `LangExtract.PromptValidator`

**Public API:**

```elixir
@spec validate(PromptTemplate.t(), keyword()) :: :ok | {:error, [Issue.t()]}
PromptValidator.validate(template, opts \\ [])

@spec validate!(PromptTemplate.t(), keyword()) :: :ok
PromptValidator.validate!(template, opts \\ [])
```

`validate!/1` raises `LangExtract.PromptValidator.ValidationError` when issues are found.

**Options:**

- `:fuzzy_threshold` — passed through to `Aligner.align/3` (default `0.75`)

**Logic:**

For each example in `template.examples` (with its 0-based index):

1. Collect extraction texts: `Enum.map(example.extractions, & &1.text)`
2. Run `Aligner.align(example.text, texts, opts)`
3. Zip extractions with spans. Any span with `status != :exact` produces an `Issue`

If no issues are found, return `:ok`. Otherwise return `{:error, issues}`.

### `LangExtract.PromptValidator.Issue`

A struct describing a single alignment problem in a few-shot example.

```elixir
%PromptValidator.Issue{
  example_index: 0,              # 0-based index into template.examples
  extraction_index: 2,           # 0-based index into example.extractions
  example_text: "Patient was...", # the example's source text (for readability)
  extraction_text: "tylenol",    # the extraction that didn't align
  extraction_class: "drug",      # the extraction's class (for context)
  status: :not_found             # :fuzzy or :not_found
}
```

```elixir
@type t :: %__MODULE__{
        example_index: non_neg_integer(),
        extraction_index: non_neg_integer(),
        example_text: String.t(),
        extraction_text: String.t(),
        extraction_class: String.t(),
        status: :fuzzy | :not_found
      }

@enforce_keys [:example_index, :extraction_index, :example_text, :extraction_text, :extraction_class, :status]
defstruct [:example_index, :extraction_index, :example_text, :extraction_text, :extraction_class, :status]
```

### `LangExtract.PromptValidator.ValidationError`

A simple exception for `validate!/1`.

```elixir
defmodule LangExtract.PromptValidator.ValidationError do
  defexception [:issues]

  @impl true
  def message(%{issues: issues}) do
    count = length(issues)
    "prompt validation failed: #{count} alignment issue(s) found"
  end
end
```

## File Structure

```
lib/lang_extract/
├── prompt_validator.ex           # NEW: validate/1, validate!/1, Issue, ValidationError
test/lang_extract/
├── prompt_validator_test.exs     # NEW
```

The `Issue` struct and `ValidationError` exception are defined inside `prompt_validator.ex` since they are tightly coupled and small.

## Edge Cases to Test

### validate/1
- All examples align exactly → `:ok`
- One extraction doesn't match (typo) → `{:error, [issue]}` with `:not_found`
- One extraction fuzzy matches → `{:error, [issue]}` with `:fuzzy`
- Multiple issues across multiple examples → all collected
- Template with no examples → `:ok` (nothing to validate)
- Template with example that has no extractions → `:ok` (nothing to check)
- Extraction with empty text → produces an `Issue` with `:not_found` (the aligner returns `:not_found` for empty strings; the validator reports what the aligner finds)
- Duplicate extraction texts within one example → each aligned independently, both get `:exact` if text exists in source
- Respects `:fuzzy_threshold` option

### validate!/1
- All examples align → returns `:ok`
- Any issues → raises `ValidationError` with issues accessible

## Out of Scope

- Logging or severity levels (caller's responsibility)
- Validation of template structure (e.g., empty description) — not an alignment concern
- Cross-example validation (e.g., duplicate extractions across examples)
