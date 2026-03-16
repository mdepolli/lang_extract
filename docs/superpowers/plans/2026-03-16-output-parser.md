# Output Parser Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a parser that converts raw LLM JSON output into Extraction structs, with a convenience function that does parse + align + merge in one call.

**Architecture:** Parser strips optional markdown fences, decodes JSON via Jason, validates entries, and returns Extraction structs. A top-level `extract/3` function wires Parser output through the existing Aligner and merges class/attributes onto Spans.

**Tech Stack:** Elixir, Jason, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-16-output-parser-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `mix.exs` | Modify | Add `jason` dependency |
| `lib/lang_extract/extraction.ex` | Create | Extraction struct |
| `lib/lang_extract/span.ex` | Modify | Add `class` and `attributes` fields |
| `lib/lang_extract/parser.ex` | Create | JSON parsing + validation |
| `lib/lang_extract.ex` | Modify | Add `extract/3` convenience function |
| `test/lang_extract/parser_test.exs` | Create | Parser + extract tests |

---

## Chunk 1: Dependencies + Structs

### Task 1: Add Jason dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add jason to deps**

In `mix.exs`, change the `deps` function to:

```elixir
  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
```

- [ ] **Step 2: Fetch deps**

```bash
cd /Users/marcelo/code/lang_extract && mix deps.get
```

- [ ] **Step 3: Verify it compiles**

```bash
cd /Users/marcelo/code/lang_extract && mix compile
```

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock && git commit -m "Add jason dependency"
```

### Task 2: Extraction struct

**Files:**
- Create: `lib/lang_extract/extraction.ex`

- [ ] **Step 1: Create the Extraction struct**

```elixir
defmodule LangExtract.Extraction do
  @moduledoc """
  A single extraction from LLM output.

  Contains the entity class, verbatim source text, and arbitrary attributes.
  Positional information is added later by the aligner on `%LangExtract.Span{}`.
  """

  @type t :: %__MODULE__{
          class: String.t(),
          text: String.t(),
          attributes: map()
        }

  @enforce_keys [:class, :text]
  defstruct [:class, :text, attributes: %{}]
end
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/marcelo/code/lang_extract && mix compile
```

- [ ] **Step 3: Commit**

```bash
git add lib/lang_extract/extraction.ex && git commit -m "Add Extraction struct"
```

### Task 3: Add class and attributes to Span

**Files:**
- Modify: `lib/lang_extract/span.ex`

- [ ] **Step 1: Update Span struct**

Replace the contents of `lib/lang_extract/span.ex` with:

```elixir
defmodule LangExtract.Span do
  @moduledoc """
  An aligned extraction with its byte position in the source text.
  """

  @type status :: :exact | :fuzzy | :not_found

  @type t :: %__MODULE__{
          text: String.t(),
          byte_start: non_neg_integer() | nil,
          byte_end: non_neg_integer() | nil,
          status: status(),
          class: String.t() | nil,
          attributes: map()
        }

  @enforce_keys [:text, :status]
  defstruct [:text, :byte_start, :byte_end, :status, :class, attributes: %{}]
end
```

- [ ] **Step 2: Run existing tests to verify nothing broke**

```bash
cd /Users/marcelo/code/lang_extract && mix test
```

Expected: 23 tests, 0 failures (existing aligner tests still pass since new fields default to nil/%{})

- [ ] **Step 3: Commit**

```bash
git add lib/lang_extract/span.ex && git commit -m "Add class and attributes fields to Span"
```

---

## Chunk 2: Parser (TDD)

### Task 4: Parser — happy path

**Files:**
- Create: `lib/lang_extract/parser.ex`, `test/lang_extract/parser_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LangExtract.ParserTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Extraction, Parser}

  describe "parse/1" do
    test "parses valid JSON with all fields" do
      json = Jason.encode!(%{
        "extractions" => [
          %{"class" => "character", "text" => "ROMEO", "attributes" => %{"emotion" => "wonder"}},
          %{"class" => "location", "text" => "Verona", "attributes" => %{}}
        ]
      })

      assert {:ok, extractions} = Parser.parse(json)
      assert length(extractions) == 2

      assert %Extraction{class: "character", text: "ROMEO", attributes: %{"emotion" => "wonder"}} =
               hd(extractions)

      assert %Extraction{class: "location", text: "Verona", attributes: %{}} =
               List.last(extractions)
    end

    test "returns empty list for empty extractions" do
      json = Jason.encode!(%{"extractions" => []})
      assert {:ok, []} = Parser.parse(json)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/parser_test.exs
```

Expected: FAIL — `Parser` module not found

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule LangExtract.Parser do
  @moduledoc """
  Parses raw LLM output JSON into `%LangExtract.Extraction{}` structs.

  Handles optional markdown fence stripping and validates each entry
  before constructing structs.
  """

  require Logger

  alias LangExtract.Extraction

  @fence_pattern ~r/```(?:json)?\s*(.*?)\s*```/s

  @spec parse(String.t()) :: {:ok, [Extraction.t()]} | {:error, :invalid_json | :missing_extractions}
  def parse(raw) when is_binary(raw) do
    raw
    |> strip_fences()
    |> Jason.decode()
    |> case do
      {:ok, %{"extractions" => entries}} when is_list(entries) ->
        {:ok, Enum.flat_map(entries, &parse_entry/1)}

      {:ok, _} ->
        {:error, :missing_extractions}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp strip_fences(raw) do
    case Regex.run(@fence_pattern, raw) do
      [_, content] -> content
      _ -> raw
    end
  end

  defp parse_entry(%{"class" => class, "text" => text} = entry)
       when is_binary(class) and class != "" and is_binary(text) and text != "" do
    attributes =
      case Map.get(entry, "attributes") do
        attrs when is_map(attrs) -> attrs
        _ -> %{}
      end

    [%Extraction{class: class, text: text, attributes: attributes}]
  end

  defp parse_entry(entry) do
    Logger.warning("Skipping invalid extraction entry: #{inspect(entry)}")
    []
  end
end
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/parser_test.exs
```

Expected: 2 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/parser.ex test/lang_extract/parser_test.exs && git commit -m "Add parser with happy path"
```

### Task 5: Parser — markdown fences

**Files:**
- Modify: `test/lang_extract/parser_test.exs`

- [ ] **Step 1: Add fence tests**

Add to the `describe "parse/1"` block:

```elixir
    test "strips markdown fences with json language tag" do
      json = ~s(```json\n{"extractions": [{"class": "x", "text": "y"}]}\n```)
      assert {:ok, [%Extraction{class: "x", text: "y"}]} = Parser.parse(json)
    end

    test "strips markdown fences without language tag" do
      json = ~s(```\n{"extractions": [{"class": "x", "text": "y"}]}\n```)
      assert {:ok, [%Extraction{class: "x", text: "y"}]} = Parser.parse(json)
    end
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/parser_test.exs
```

Expected: 4 tests, 0 failures (should pass with existing implementation)

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/parser_test.exs && git commit -m "Add markdown fence stripping tests"
```

### Task 6: Parser — error handling and validation edge cases

**Files:**
- Modify: `test/lang_extract/parser_test.exs`

- [ ] **Step 1: Add error and validation tests**

Add to the `describe "parse/1"` block:

```elixir
    test "returns error for invalid JSON" do
      assert {:error, :invalid_json} = Parser.parse("not json at all")
    end

    test "returns error when extractions key is missing" do
      json = Jason.encode!(%{"data" => []})
      assert {:error, :missing_extractions} = Parser.parse(json)
    end

    test "returns error when extractions is not a list" do
      json = Jason.encode!(%{"extractions" => "oops"})
      assert {:error, :missing_extractions} = Parser.parse(json)

      json_null = Jason.encode!(%{"extractions" => nil})
      assert {:error, :missing_extractions} = Parser.parse(json_null)
    end

    test "skips entries with missing class or text" do
      json = Jason.encode!(%{
        "extractions" => [
          %{"class" => "valid", "text" => "kept"},
          %{"text" => "no class"},
          %{"class" => "no text"}
        ]
      })

      assert {:ok, [%Extraction{class: "valid", text: "kept"}]} = Parser.parse(json)
    end

    test "skips entries with non-string class or text" do
      json = Jason.encode!(%{
        "extractions" => [
          %{"class" => 42, "text" => "bad class"},
          %{"class" => "good", "text" => nil},
          %{"class" => "valid", "text" => "kept"}
        ]
      })

      assert {:ok, [%Extraction{class: "valid", text: "kept"}]} = Parser.parse(json)
    end

    test "skips entries with empty string class or text" do
      json = Jason.encode!(%{
        "extractions" => [
          %{"class" => "", "text" => "empty class"},
          %{"class" => "valid", "text" => ""},
          %{"class" => "good", "text" => "kept"}
        ]
      })

      assert {:ok, [%Extraction{class: "good", text: "kept"}]} = Parser.parse(json)
    end

    test "defaults missing attributes to empty map" do
      json = Jason.encode!(%{
        "extractions" => [%{"class" => "x", "text" => "y"}]
      })

      assert {:ok, [%Extraction{attributes: %{}}]} = Parser.parse(json)
    end

    test "defaults non-map attributes to empty map" do
      json = Jason.encode!(%{
        "extractions" => [%{"class" => "x", "text" => "y", "attributes" => "bad"}]
      })

      assert {:ok, [%Extraction{attributes: %{}}]} = Parser.parse(json)
    end

    test "preserves nested attributes" do
      json = Jason.encode!(%{
        "extractions" => [
          %{"class" => "x", "text" => "y", "attributes" => %{"nested" => %{"deep" => true}}}
        ]
      })

      assert {:ok, [%Extraction{attributes: %{"nested" => %{"deep" => true}}}]} =
               Parser.parse(json)
    end
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/parser_test.exs
```

Expected: 13 tests, 0 failures

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/parser_test.exs && git commit -m "Add parser error handling and validation tests"
```

---

## Chunk 3: Extract Convenience Function (TDD)

### Task 7: LangExtract.extract/3

**Files:**
- Modify: `lib/lang_extract.ex`, `test/lang_extract/parser_test.exs`

- [ ] **Step 1: Write the failing tests**

Add a new describe block to `test/lang_extract/parser_test.exs`:

```elixir
  describe "LangExtract.extract/3" do
    test "parses, aligns, and merges class/attributes onto spans" do
      source = "But soft! What light through yonder window breaks?"

      json = Jason.encode!(%{
        "extractions" => [
          %{"class" => "quote", "text" => "soft", "attributes" => %{"tone" => "gentle"}},
          %{"class" => "object", "text" => "window"}
        ]
      })

      assert {:ok, spans} = LangExtract.extract(source, json)
      assert length(spans) == 2

      [soft, window] = spans
      assert %LangExtract.Span{
               text: "soft",
               status: :exact,
               class: "quote",
               attributes: %{"tone" => "gentle"}
             } = soft
      assert soft.byte_start != nil

      assert %LangExtract.Span{
               text: "window",
               status: :exact,
               class: "object",
               attributes: %{}
             } = window
      assert window.byte_start != nil
    end

    test "merges class/attributes onto not_found spans" do
      json = Jason.encode!(%{
        "extractions" => [
          %{"class" => "thing", "text" => "nonexistent phrase", "attributes" => %{"a" => 1}}
        ]
      })

      assert {:ok, [span]} = LangExtract.extract("hello world", json)
      assert span.status == :not_found
      assert span.class == "thing"
      assert span.attributes == %{"a" => 1}
    end

    test "propagates parser errors" do
      assert {:error, :invalid_json} = LangExtract.extract("source", "bad json")
      assert {:error, :missing_extractions} =
               LangExtract.extract("source", Jason.encode!(%{"wrong" => []}))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/parser_test.exs
```

Expected: FAIL — `LangExtract.extract/3` is undefined

- [ ] **Step 3: Implement extract/3**

In `lib/lang_extract.ex`:

1. Replace the existing module-level alias `alias LangExtract.Aligner` with `alias LangExtract.{Aligner, Parser, Span}`
2. Add the following function below the existing `align/3`:

```elixir
  @doc """
  Parses LLM output, aligns extractions against source text, and returns
  enriched spans with class and attributes.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      iex> json = ~s({"extractions": [{"class": "word", "text": "fox"}]})
      iex> {:ok, [span]} = LangExtract.extract("the quick brown fox", json)
      iex> span.status
      :exact

  """
  @spec extract(String.t(), String.t(), keyword()) ::
          {:ok, [Span.t()]} | {:error, :invalid_json | :missing_extractions}
  def extract(source, raw_llm_output, opts \\ []) do
    with {:ok, extractions} <- Parser.parse(raw_llm_output) do
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

- [ ] **Step 4: Run all tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test
```

Expected: all tests pass (23 existing + 15 parser = 38 total)

- [ ] **Step 5: Run formatter**

```bash
cd /Users/marcelo/code/lang_extract && mix format
```

- [ ] **Step 6: Commit**

```bash
git add lib/lang_extract.ex test/lang_extract/parser_test.exs && git commit -m "Add extract/3 convenience function (parse + align + merge)"
```

### Task 8: Final verification

- [ ] **Step 1: Run all tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test
```

Expected: all tests pass

- [ ] **Step 2: Verify end-to-end in iex**

```bash
cd /Users/marcelo/code/lang_extract && mix run -e '
  source = "ROMEO. But soft! What light through yonder window breaks?"
  json = Jason.encode!(%{
    "extractions" => [
      %{"class" => "character", "text" => "ROMEO", "attributes" => %{"emotion" => "wonder"}},
      %{"class" => "word", "text" => "window"}
    ]
  })
  {:ok, spans} = LangExtract.extract(source, json)
  IO.inspect(spans, label: "results")
'
```

Expected: two enriched spans with class, attributes, byte offsets, and :exact status
