# Prompt Builder & Format Handler Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a format handler (hexagonal port) and prompt builder for constructing few-shot extraction prompts and normalizing LLM output.

**Architecture:** The format handler sits between external LLM format (dynamic keys, fences, `<think>` tags) and internal domain (canonical `class`/`text`/`attributes` structs). The parser is simplified to only handle canonical format. The prompt builder composes the format handler to render few-shot Q&A prompts.

**Tech Stack:** Elixir, Jason, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-17-prompt-builder-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/lang_extract/format_handler.ex` | Create | Port: serialization (structs → dynamic-key JSON) and normalization (raw LLM output → canonical JSON) |
| `test/lang_extract/format_handler_test.exs` | Create | Tests for serialization, normalization, round-trip |
| `lib/lang_extract/parser.ex` | Modify | Remove fence stripping, update moduledoc |
| `test/lang_extract/parser_test.exs` | Modify | Remove two fence-stripping tests |
| `lib/lang_extract.ex` | Modify | Wire `FormatHandler.normalize/1` into `extract/3`, update typespec |
| `lib/lang_extract/example_data.ex` | Create | ExampleData struct |
| `lib/lang_extract/prompt_template.ex` | Create | PromptTemplate struct |
| `lib/lang_extract/prompt_builder.ex` | Create | Stateless Q&A prompt renderer |
| `test/lang_extract/prompt_builder_test.exs` | Create | Tests for prompt rendering |

---

## Chunk 1: FormatHandler — Serialization

### Task 1: Serialization — single extraction

**Files:**
- Create: `lib/lang_extract/format_handler.ex`
- Create: `test/lang_extract/format_handler_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/lang_extract/format_handler_test.exs
defmodule LangExtract.FormatHandlerTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Extraction, FormatHandler}

  describe "format_extractions/1" do
    test "serializes a single extraction to dynamic-key JSON with fences" do
      extractions = [
        %Extraction{class: "medical_condition", text: "hypertension", attributes: %{"chronicity" => "chronic"}}
      ]

      result = FormatHandler.format_extractions(extractions)

      assert result =~ "```json"
      assert String.ends_with?(result, "\n```")

      # Strip fences and decode to verify structure
      json = result |> String.replace(~r/```json\n|```/, "") |> String.trim()
      decoded = Jason.decode!(json)

      assert %{"extractions" => [entry]} = decoded
      assert entry["medical_condition"] == "hypertension"
      assert entry["medical_condition_attributes"] == %{"chronicity" => "chronic"}
      refute Map.has_key?(entry, "class")
      refute Map.has_key?(entry, "text")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/lang_extract/format_handler_test.exs --trace`
Expected: FAIL — `FormatHandler` module not found

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/lang_extract/format_handler.ex
defmodule LangExtract.FormatHandler do
  @moduledoc """
  Port between external LLM format and internal domain.

  Serializes `%Extraction{}` structs to dynamic-key JSON for prompts,
  and normalizes raw LLM output back to canonical format for the parser.
  """

  alias LangExtract.Extraction

  @attribute_suffix "_attributes"

  @spec format_extractions([Extraction.t()]) :: String.t()
  def format_extractions(extractions) do
    items = Enum.map(extractions, &serialize_extraction/1)
    payload = %{"extractions" => items}
    json = Jason.encode!(payload, pretty: true)
    "```json\n#{json}\n```"
  end

  defp serialize_extraction(%Extraction{class: class, text: text, attributes: attributes}) do
    %{class => text, "#{class}#{@attribute_suffix}" => attributes || %{}}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/lang_extract/format_handler_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/format_handler.ex test/lang_extract/format_handler_test.exs
git commit -m "Add FormatHandler with single-extraction serialization"
```

### Task 2: Serialization — multiple extractions and edge cases

**Files:**
- Modify: `test/lang_extract/format_handler_test.exs`

- [ ] **Step 1: Add tests for multiple extractions, empty attributes, nested attributes**

```elixir
    test "serializes multiple extractions in order" do
      extractions = [
        %Extraction{class: "condition", text: "hypertension", attributes: %{}},
        %Extraction{class: "medication", text: "lisinopril", attributes: %{}}
      ]

      result = FormatHandler.format_extractions(extractions)
      json = result |> String.replace(~r/```json\n|```/, "") |> String.trim()
      decoded = Jason.decode!(json)

      assert %{"extractions" => [first, second]} = decoded
      assert first["condition"] == "hypertension"
      assert second["medication"] == "lisinopril"
    end

    test "serializes extraction with empty attributes" do
      extractions = [%Extraction{class: "person", text: "Alice", attributes: %{}}]

      result = FormatHandler.format_extractions(extractions)
      json = result |> String.replace(~r/```json\n|```/, "") |> String.trim()
      decoded = Jason.decode!(json)

      assert %{"extractions" => [entry]} = decoded
      assert entry["person_attributes"] == %{}
    end

    test "serializes empty extraction list" do
      result = FormatHandler.format_extractions([])
      json = result |> String.replace(~r/```json\n|```/, "") |> String.trim()
      decoded = Jason.decode!(json)
      assert %{"extractions" => []} = decoded
    end

    test "preserves nested attributes" do
      extractions = [
        %Extraction{
          class: "entity",
          text: "X",
          attributes: %{"nested" => %{"deep" => true}}
        }
      ]

      result = FormatHandler.format_extractions(extractions)
      json = result |> String.replace(~r/```json\n|```/, "") |> String.trim()
      decoded = Jason.decode!(json)

      assert %{"extractions" => [entry]} = decoded
      assert entry["entity_attributes"] == %{"nested" => %{"deep" => true}}
    end
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `mix test test/lang_extract/format_handler_test.exs --trace`
Expected: PASS (implementation already handles these cases)

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/format_handler_test.exs
git commit -m "Add serialization tests for multiple extractions and edge cases"
```

---

## Chunk 2: FormatHandler — Normalization

### Task 3: Normalization — dynamic-key to canonical format

**Files:**
- Modify: `lib/lang_extract/format_handler.ex`
- Modify: `test/lang_extract/format_handler_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  describe "normalize/1" do
    test "converts dynamic-key JSON to canonical format" do
      input = Jason.encode!(%{
        "extractions" => [
          %{
            "medical_condition" => "hypertension",
            "medical_condition_attributes" => %{"chronicity" => "chronic"}
          }
        ]
      })

      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)

      assert %{"extractions" => [entry]} = decoded
      assert entry["class"] == "medical_condition"
      assert entry["text"] == "hypertension"
      assert entry["attributes"] == %{"chronicity" => "chronic"}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/lang_extract/format_handler_test.exs:\"converts dynamic-key\" --trace`
Expected: FAIL — `normalize/1` not defined

- [ ] **Step 3: Write minimal implementation**

```elixir
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_format}
  def normalize(raw) when is_binary(raw) do
    cleaned = raw |> strip_think_tags() |> strip_fences()

    case Jason.decode(cleaned) do
      {:ok, %{"extractions" => entries} = decoded} when is_list(entries) ->
        normalized = Enum.map(entries, &normalize_entry/1)
        {:ok, Jason.encode!(%{decoded | "extractions" => normalized})}

      {:ok, _} ->
        {:ok, cleaned}

      {:error, _} ->
        {:error, :invalid_format}
    end
  end

  @think_pattern ~r/<think>.*?<\/think>/s
  @think_unclosed ~r/<think>.*/s
  @fence_pattern ~r/```(?:json)?\s*(.*?)\s*```/s

  defp strip_think_tags(raw) do
    raw
    |> String.replace(@think_pattern, "")
    |> String.replace(@think_unclosed, "")
    |> String.trim()
  end

  defp strip_fences(raw) do
    case Regex.run(@fence_pattern, raw) do
      [_, content] -> content
      _ -> raw
    end
  end

  defp normalize_entry(%{"class" => _, "text" => _} = entry), do: entry

  defp normalize_entry(entry) when is_map(entry) do
    all_keys = Map.keys(entry)

    # Partition into potential attribute keys and class keys
    {attr_keys, class_keys} =
      Enum.split_with(all_keys, &String.ends_with?(&1, @attribute_suffix))

    # Only count an _attributes key if its prefix exists as a class key
    matched_attr_keys =
      Enum.filter(attr_keys, fn attr_key ->
        prefix = String.replace_suffix(attr_key, @attribute_suffix, "")
        prefix in class_keys
      end)

    # Unmatched _attributes keys are actually class keys (e.g., "html_attributes" as a class)
    unmatched_attr_keys = attr_keys -- matched_attr_keys
    effective_class_keys = class_keys ++ unmatched_attr_keys

    case effective_class_keys do
      [class_key] ->
        attr_key = "#{class_key}#{@attribute_suffix}"
        attributes =
          if attr_key in matched_attr_keys do
            case Map.get(entry, attr_key) do
              attrs when is_map(attrs) -> attrs
              _ -> %{}
            end
          else
            %{}
          end

        %{"class" => class_key, "text" => Map.get(entry, class_key), "attributes" => attributes}

      _ ->
        entry
    end
  end

  defp normalize_entry(entry), do: entry
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/lang_extract/format_handler_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/format_handler.ex test/lang_extract/format_handler_test.exs
git commit -m "Add FormatHandler normalization for dynamic-key to canonical conversion"
```

### Task 4: Normalization — canonical passthrough

**Files:**
- Modify: `test/lang_extract/format_handler_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
    test "passes through already-canonical JSON unchanged" do
      input = Jason.encode!(%{
        "extractions" => [
          %{"class" => "word", "text" => "fox", "attributes" => %{}}
        ]
      })

      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)

      assert %{"extractions" => [entry]} = decoded
      assert entry["class"] == "word"
      assert entry["text"] == "fox"
    end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/lang_extract/format_handler_test.exs --trace`
Expected: PASS (canonical detection in `normalize_entry/1` handles this)

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/format_handler_test.exs
git commit -m "Add normalization test for canonical passthrough"
```

### Task 5: Normalization — think tag and fence stripping

**Files:**
- Modify: `test/lang_extract/format_handler_test.exs`

- [ ] **Step 1: Write tests for think tags, fences, and edge cases**

```elixir
    test "strips <think> tags before parsing" do
      input = ~s(<think>reasoning here</think>{"extractions": [{"class": "x", "text": "y"}]})
      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)
      assert %{"extractions" => [%{"class" => "x"}]} = decoded
    end

    test "strips unclosed <think> tag to end of string" do
      input = ~s(<think>still thinking{"extractions": []})
      assert {:error, :invalid_format} = FormatHandler.normalize(input)
    end

    test "strips multiple <think> blocks" do
      input = ~s(<think>first</think>{"extractions": [{"class": "x", "text": "y"}]}<think>second</think>)
      assert {:ok, _} = FormatHandler.normalize(input)
    end

    test "strips markdown fences with json language tag" do
      input = ~s(```json\n{"extractions": [{"class": "x", "text": "y"}]}\n```)
      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)
      assert %{"extractions" => [%{"class" => "x"}]} = decoded
    end

    test "strips markdown fences without language tag" do
      input = ~s(```\n{"extractions": [{"class": "x", "text": "y"}]}\n```)
      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)
      assert %{"extractions" => [%{"class" => "x"}]} = decoded
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_format} = FormatHandler.normalize("not json at all")
    end

    test "handles combined think tags, fences, and dynamic keys" do
      input = ~s(<think>reasoning</think>```json\n{"extractions": [{"condition": "flu", "condition_attributes": {"severity": "mild"}}]}\n```)
      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)
      assert %{"extractions" => [entry]} = decoded
      assert entry["class"] == "condition"
      assert entry["text"] == "flu"
      assert entry["attributes"] == %{"severity" => "mild"}
    end
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `mix test test/lang_extract/format_handler_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/format_handler_test.exs
git commit -m "Add normalization tests for think tags, fences, and error cases"
```

### Task 6: Normalization — _attributes edge cases

**Files:**
- Modify: `test/lang_extract/format_handler_test.exs`

- [ ] **Step 1: Write tests for _attributes heuristic edge cases**

```elixir
    test "_attributes key without matching prefix is treated as a class key" do
      # "html_attributes" has no "html" key, so it's a class key itself
      input = Jason.encode!(%{
        "extractions" => [
          %{"html_attributes" => "data-id='5'"}
        ]
      })

      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)

      assert %{"extractions" => [entry]} = decoded
      assert entry["class"] == "html_attributes"
      assert entry["text"] == "data-id='5'"
    end

    test "entry with multiple non-attribute keys is passed through" do
      input = Jason.encode!(%{
        "extractions" => [
          %{"person" => "Alice", "location" => "Wonderland"}
        ]
      })

      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)

      # Passed through as-is — parser will skip it
      assert %{"extractions" => [entry]} = decoded
      assert entry["person"] == "Alice"
      assert entry["location"] == "Wonderland"
    end

    test "entry with no keys is passed through" do
      input = Jason.encode!(%{"extractions" => [%{}]})
      assert {:ok, canonical} = FormatHandler.normalize(input)
      decoded = Jason.decode!(canonical)
      assert %{"extractions" => [%{}]} = decoded
    end
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `mix test test/lang_extract/format_handler_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/format_handler_test.exs
git commit -m "Add normalization tests for _attributes heuristic edge cases"
```

### Task 7: Round-trip test

**Files:**
- Modify: `test/lang_extract/format_handler_test.exs`

- [ ] **Step 1: Write the round-trip integration test**

```elixir
  describe "round-trip" do
    test "format_extractions |> normalize |> Parser.parse returns same extractions" do
      alias LangExtract.Parser

      original = [
        %Extraction{class: "condition", text: "hypertension", attributes: %{"chronicity" => "chronic"}},
        %Extraction{class: "medication", text: "lisinopril", attributes: %{}}
      ]

      formatted = FormatHandler.format_extractions(original)
      assert {:ok, canonical} = FormatHandler.normalize(formatted)
      assert {:ok, parsed} = Parser.parse(canonical)

      assert length(parsed) == length(original)

      Enum.zip(original, parsed)
      |> Enum.each(fn {orig, parsed_ext} ->
        assert parsed_ext.class == orig.class
        assert parsed_ext.text == orig.text
        assert parsed_ext.attributes == orig.attributes
      end)
    end
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/lang_extract/format_handler_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/format_handler_test.exs
git commit -m "Add round-trip test for format -> normalize -> parse"
```

---

## Chunk 3: Parser Refactor & extract/3 Integration

### Task 8: Remove fence stripping from parser

**Files:**
- Modify: `lib/lang_extract/parser.ex`
- Modify: `test/lang_extract/parser_test.exs`

- [ ] **Step 1: Remove the two fence-stripping tests from parser_test.exs**

Find and delete the tests named `"strips markdown fences with json language tag"` and `"strips markdown fences without language tag"` from the `"parse/1"` describe block. These test fence stripping which is now the FormatHandler's responsibility (equivalent tests already exist in `format_handler_test.exs` from Task 5).

- [ ] **Step 2: Remove fence stripping from parser.ex**

Remove `@fence_pattern` (line 13) and `strip_fences/1` (lines 33-37). Update `parse/1` to remove the `strip_fences()` call. Update moduledoc.

Updated parser.ex:
```elixir
defmodule LangExtract.Parser do
  @moduledoc """
  Parses canonical JSON into `%LangExtract.Extraction{}` structs.

  Expects canonical format with explicit `class`, `text`, and `attributes` keys.
  External format concerns (fences, dynamic keys, think tags) are handled by
  `LangExtract.FormatHandler` before reaching this module.
  """

  require Logger

  alias LangExtract.Extraction

  @spec parse(String.t()) ::
          {:ok, [Extraction.t()]} | {:error, :invalid_json | :missing_extractions}
  def parse(raw) when is_binary(raw) do
    raw
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

- [ ] **Step 3: Run all parser tests to verify remaining tests still pass**

Run: `mix test test/lang_extract/parser_test.exs --trace`
Expected: PASS (all remaining tests use canonical format)

- [ ] **Step 4: Commit**

```bash
git add lib/lang_extract/parser.ex test/lang_extract/parser_test.exs
git commit -m "Remove fence stripping from parser (moved to FormatHandler)"
```

### Task 9: Wire FormatHandler into extract/3

**Files:**
- Modify: `lib/lang_extract.ex`

- [ ] **Step 1: Update extract/3 to use FormatHandler.normalize/1**

```elixir
defmodule LangExtract do
  @moduledoc """
  Extracts structured data from text with source grounding.
  Maps extraction strings back to exact byte positions in source text.
  """

  alias LangExtract.{Aligner, FormatHandler, Parser, Span}

  @doc """
  Aligns extraction strings to byte spans in source text.

  Returns a list of `%LangExtract.Span{}` structs, one per extraction.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      iex> LangExtract.align("the quick brown fox", ["quick brown"])
      [%LangExtract.Span{text: "quick brown", byte_start: 4, byte_end: 15, status: :exact}]

  """
  @spec align(String.t(), [String.t()], keyword()) :: [LangExtract.Span.t()]
  def align(source, extractions, opts \\ []) do
    Aligner.align(source, extractions, opts)
  end

  @doc """
  Parses LLM output, aligns extractions against source text, and returns
  enriched spans with class and attributes.

  Accepts both canonical format (`class`/`text`/`attributes` keys) and
  dynamic-key format (`<class>: <text>`, `<class>_attributes: {...}`).
  Markdown fences and `<think>` tags are stripped automatically.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      iex> json = ~s({"extractions": [{"class": "word", "text": "fox"}]})
      iex> {:ok, [span]} = LangExtract.extract("the quick brown fox", json)
      iex> span.status
      :exact

  """
  @spec extract(String.t(), String.t(), keyword()) ::
          {:ok, [Span.t()]} | {:error, :invalid_format | :invalid_json | :missing_extractions}
  def extract(source, raw_llm_output, opts \\ []) do
    with {:ok, canonical} <- FormatHandler.normalize(raw_llm_output),
         {:ok, extractions} <- Parser.parse(canonical) do
      texts = Enum.map(extractions, & &1.text)
      spans = Aligner.align(source, texts, opts)

      enriched =
        Enum.zip(extractions, spans)
        |> Enum.map(fn {extraction, %Span{} = span} ->
          %Span{span | class: extraction.class, attributes: extraction.attributes}
        end)

      {:ok, enriched}
    end
  end
end
```

- [ ] **Step 2: Run all tests to identify what broke**

Run: `mix test --trace`
Expected: The `"propagates parser errors"` test will FAIL — it asserts `{:error, :invalid_json}` for `"bad json"`, but `FormatHandler.normalize/1` now returns `{:error, :invalid_format}` before the parser is reached. All other tests should pass.

- [ ] **Step 3: Update the error propagation test**

In `test/lang_extract/parser_test.exs`, update the error test:

```elixir
    test "propagates parser errors" do
      # Invalid JSON now caught by FormatHandler
      assert {:error, :invalid_format} = LangExtract.extract("source", "bad json")

      assert {:error, :missing_extractions} =
               LangExtract.extract("source", Jason.encode!(%{"wrong" => []}))
    end
```

- [ ] **Step 4: Run all tests again**

Run: `mix test --trace`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract.ex test/lang_extract/parser_test.exs
git commit -m "Wire FormatHandler into extract/3, update error handling"
```

### Task 10: Add extract/3 test with dynamic-key format

**Files:**
- Modify: `test/lang_extract/parser_test.exs`

- [ ] **Step 1: Add test that extract/3 handles dynamic-key LLM output**

```elixir
    test "handles dynamic-key format from LLM output" do
      source = "The patient was diagnosed with hypertension."

      json = Jason.encode!(%{
        "extractions" => [
          %{
            "medical_condition" => "hypertension",
            "medical_condition_attributes" => %{"chronicity" => "chronic"}
          }
        ]
      })

      assert {:ok, [span]} = LangExtract.extract(source, json)
      assert span.class == "medical_condition"
      assert span.text == "hypertension"
      assert span.attributes == %{"chronicity" => "chronic"}
      assert span.status == :exact
    end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/lang_extract/parser_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/parser_test.exs
git commit -m "Add extract/3 test for dynamic-key LLM output format"
```

---

## Chunk 4: Data Structs & Prompt Builder

### Task 11: ExampleData and PromptTemplate structs

**Files:**
- Create: `lib/lang_extract/example_data.ex`
- Create: `lib/lang_extract/prompt_template.ex`

- [ ] **Step 1: Create ExampleData struct**

```elixir
# lib/lang_extract/example_data.ex
defmodule LangExtract.ExampleData do
  @moduledoc """
  A single few-shot example: source text and expected extractions.
  """

  alias LangExtract.Extraction

  @type t :: %__MODULE__{
          text: String.t(),
          extractions: [Extraction.t()]
        }

  @enforce_keys [:text]
  defstruct [:text, extractions: []]
end
```

- [ ] **Step 2: Create PromptTemplate struct**

```elixir
# lib/lang_extract/prompt_template.ex
defmodule LangExtract.PromptTemplate do
  @moduledoc """
  Holds the extraction task description and few-shot examples.
  """

  alias LangExtract.ExampleData

  @type t :: %__MODULE__{
          description: String.t(),
          examples: [ExampleData.t()]
        }

  @enforce_keys [:description]
  defstruct [:description, examples: []]
end
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/lang_extract/example_data.ex lib/lang_extract/prompt_template.ex
git commit -m "Add ExampleData and PromptTemplate structs"
```

### Task 12: PromptBuilder — basic prompt with no examples

**Files:**
- Create: `lib/lang_extract/prompt_builder.ex`
- Create: `test/lang_extract/prompt_builder_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/lang_extract/prompt_builder_test.exs
defmodule LangExtract.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias LangExtract.{ExampleData, Extraction, PromptBuilder, PromptTemplate}

  describe "build/3" do
    test "renders description and chunk text with no examples" do
      template = %PromptTemplate{
        description: "Extract entities from the text."
      }

      result = PromptBuilder.build(template, "The quick brown fox.")

      assert result =~ "Extract entities from the text."
      assert result =~ "The quick brown fox."
      refute result =~ "```json"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/lang_extract/prompt_builder_test.exs --trace`
Expected: FAIL — `PromptBuilder` module not found

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/lang_extract/prompt_builder.ex
defmodule LangExtract.PromptBuilder do
  @moduledoc """
  Renders Q&A-formatted prompts from a template for LLM extraction.

  Stateless — the caller passes previous chunk text explicitly
  for cross-chunk coreference resolution.
  """

  alias LangExtract.{FormatHandler, PromptTemplate}

  @spec build(PromptTemplate.t(), String.t(), keyword()) :: String.t()
  def build(%PromptTemplate{} = template, chunk_text, opts \\ []) do
    [
      template.description,
      format_examples(template.examples),
      format_context(opts),
      chunk_text
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_examples(nil), do: nil
  defp format_examples([]), do: nil

  defp format_examples(examples) do
    examples
    |> Enum.map(fn example ->
      formatted = FormatHandler.format_extractions(example.extractions)
      "#{example.text}\n#{formatted}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_context(opts) do
    case Keyword.get(opts, :previous_chunk) do
      nil -> nil
      prev ->
        window = Keyword.get(opts, :context_window_chars)
        text = if window, do: String.slice(prev, -window..-1//1), else: prev
        "[Previous text]: ...#{text}"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/lang_extract/prompt_builder_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/prompt_builder.ex test/lang_extract/prompt_builder_test.exs
git commit -m "Add PromptBuilder with basic description + chunk rendering"
```

### Task 13: PromptBuilder — with few-shot examples

**Files:**
- Modify: `test/lang_extract/prompt_builder_test.exs`

- [ ] **Step 1: Write the test**

```elixir
    test "renders few-shot examples in dynamic-key format" do
      template = %PromptTemplate{
        description: "Extract conditions.",
        examples: [
          %ExampleData{
            text: "Patient has diabetes.",
            extractions: [
              %Extraction{class: "condition", text: "diabetes", attributes: %{"type" => "chronic"}}
            ]
          }
        ]
      }

      result = PromptBuilder.build(template, "Patient has asthma.")

      # Description present
      assert result =~ "Extract conditions."
      # Example text present
      assert result =~ "Patient has diabetes."
      # Dynamic-key format in example
      assert result =~ "\"condition\""
      assert result =~ "\"diabetes\""
      assert result =~ "condition_attributes"
      # Chunk text at the end
      assert String.ends_with?(String.trim(result), "Patient has asthma.")
    end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/lang_extract/prompt_builder_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/prompt_builder_test.exs
git commit -m "Add PromptBuilder test for few-shot examples"
```

### Task 14: PromptBuilder — previous chunk context

**Files:**
- Modify: `test/lang_extract/prompt_builder_test.exs`

- [ ] **Step 1: Write tests for previous chunk context**

```elixir
    test "includes previous chunk context" do
      template = %PromptTemplate{description: "Extract."}

      result = PromptBuilder.build(template, "Current chunk.", previous_chunk: "Previous text here.")

      assert result =~ "[Previous text]: ...Previous text here."
      assert result =~ "Current chunk."
    end

    test "truncates previous chunk to context_window_chars" do
      template = %PromptTemplate{description: "Extract."}

      result = PromptBuilder.build(template, "Current.",
        previous_chunk: "This is a long previous chunk of text.",
        context_window_chars: 10
      )

      assert result =~ "[Previous text]: ...k of text."
      refute result =~ "This is a long"
    end

    test "omits context section when no previous chunk" do
      template = %PromptTemplate{description: "Extract."}

      result = PromptBuilder.build(template, "Current chunk.")

      refute result =~ "[Previous text]"
    end

    test "empty description is valid" do
      template = %PromptTemplate{
        description: "",
        examples: [
          %ExampleData{
            text: "Example text.",
            extractions: [%Extraction{class: "thing", text: "text", attributes: %{}}]
          }
        ]
      }

      result = PromptBuilder.build(template, "Target text.")

      assert result =~ "Example text."
      assert result =~ "Target text."
    end
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `mix test test/lang_extract/prompt_builder_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/prompt_builder_test.exs
git commit -m "Add PromptBuilder tests for previous chunk context"
```

### Task 15: Final full test suite run

- [ ] **Step 1: Run the full test suite**

Run: `mix test --trace`
Expected: ALL PASS

- [ ] **Step 2: Verify no warnings**

Run: `mix compile --warnings-as-errors`
Expected: PASS
