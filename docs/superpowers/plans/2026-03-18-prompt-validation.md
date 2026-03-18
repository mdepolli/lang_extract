# Prompt Validation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a prompt validator that checks few-shot examples against the aligner, catching bad extractions before they reach the LLM.

**Architecture:** `PromptValidator.validate/1` iterates template examples, runs each through the existing `Aligner`, and collects any non-exact alignments as `Issue` structs. `validate!/1` raises on failure. The validator is a pure function — no logging, no severity levels.

**Tech Stack:** Elixir, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-18-prompt-validation-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/lang_extract/prompt_validator.ex` | Create | `validate/1`, `validate!/1`, `Issue` struct, `ValidationError` exception |
| `test/lang_extract/prompt_validator_test.exs` | Create | All validation tests |

---

## Chunk 1: PromptValidator

### Task 1: Happy path — all examples align

**Files:**
- Create: `test/lang_extract/prompt_validator_test.exs`
- Create: `lib/lang_extract/prompt_validator.ex`

- [ ] **Step 1: Write the failing test**

```elixir
# test/lang_extract/prompt_validator_test.exs
defmodule LangExtract.PromptValidatorTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Extraction, ExampleData, PromptTemplate, PromptValidator}

  describe "validate/1" do
    test "returns :ok when all examples align exactly" do
      template = %PromptTemplate{
        description: "Extract conditions.",
        examples: [
          %ExampleData{
            text: "Patient has hypertension and diabetes.",
            extractions: [
              %Extraction{class: "condition", text: "hypertension", attributes: %{}},
              %Extraction{class: "condition", text: "diabetes", attributes: %{}}
            ]
          }
        ]
      }

      assert :ok = PromptValidator.validate(template)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/lang_extract/prompt_validator_test.exs --trace`
Expected: FAIL — `PromptValidator` module not found

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/lang_extract/prompt_validator.ex
defmodule LangExtract.PromptValidator do
  @moduledoc """
  Validates that few-shot examples in a `PromptTemplate` are self-consistent.

  Each extraction text should align exactly against its own example's source text.
  Catches typos, hallucinated spans, and copy-paste errors before they reach the LLM.

  The validator is a pure function — it reports what it finds. The caller decides
  what to do with the results (log, raise, ignore).
  """

  alias LangExtract.{Aligner, Extraction, ExampleData, PromptTemplate}

  defmodule Issue do
    @moduledoc """
    Describes a single alignment problem in a few-shot example.
    """

    @type t :: %__MODULE__{
            example_index: non_neg_integer(),
            extraction_index: non_neg_integer(),
            example_text: String.t(),
            extraction_text: String.t(),
            extraction_class: String.t(),
            status: :fuzzy | :not_found
          }

    @enforce_keys [
      :example_index,
      :extraction_index,
      :example_text,
      :extraction_text,
      :extraction_class,
      :status
    ]
    defstruct [
      :example_index,
      :extraction_index,
      :example_text,
      :extraction_text,
      :extraction_class,
      :status
    ]
  end

  defmodule ValidationError do
    @moduledoc """
    Raised by `PromptValidator.validate!/1` when alignment issues are found.
    """

    defexception [:issues]

    @impl true
    def message(%{issues: issues}) do
      count = length(issues)
      "prompt validation failed: #{count} alignment issue(s) found"
    end
  end

  @spec validate(PromptTemplate.t(), keyword()) :: :ok | {:error, [Issue.t()]}
  def validate(%PromptTemplate{} = template, opts \\ []) do
    issues =
      template.examples
      |> Enum.with_index()
      |> Enum.flat_map(fn {example, example_index} ->
        validate_example(example, example_index, opts)
      end)

    case issues do
      [] -> :ok
      issues -> {:error, issues}
    end
  end

  @spec validate!(PromptTemplate.t(), keyword()) :: :ok
  def validate!(%PromptTemplate{} = template, opts \\ []) do
    case validate(template, opts) do
      :ok -> :ok
      {:error, issues} -> raise ValidationError, issues: issues
    end
  end

  defp validate_example(%ExampleData{} = example, example_index, opts) do
    texts = Enum.map(example.extractions, & &1.text)
    spans = Aligner.align(example.text, texts, opts)

    example.extractions
    |> Enum.zip(spans)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{%Extraction{} = extraction, span}, extraction_index} ->
      case span.status do
        :exact ->
          []

        status ->
          [
            %Issue{
              example_index: example_index,
              extraction_index: extraction_index,
              example_text: example.text,
              extraction_text: extraction.text,
              extraction_class: extraction.class,
              status: status
            }
          ]
      end
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/lang_extract/prompt_validator_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/prompt_validator.ex test/lang_extract/prompt_validator_test.exs
git commit -m "Add PromptValidator with happy path"
```

### Task 2: Error cases — not_found and fuzzy

**Files:**
- Modify: `test/lang_extract/prompt_validator_test.exs`

- [ ] **Step 1: Add tests for failed alignments**

```elixir
    test "returns error with :not_found when extraction text is not in source" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Patient has hypertension.",
            extractions: [
              %Extraction{class: "drug", text: "tylenol", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, [issue]} = PromptValidator.validate(template)
      assert issue.example_index == 0
      assert issue.extraction_index == 0
      assert issue.extraction_text == "tylenol"
      assert issue.extraction_class == "drug"
      assert issue.status == :not_found
      assert issue.example_text == "Patient has hypertension."
    end

    test "respects fuzzy_threshold — same extraction is :not_found at high threshold" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "the quick brown fox jumps",
            extractions: [
              %Extraction{class: "phrase", text: "quick brown dog", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, [issue]} = PromptValidator.validate(template, fuzzy_threshold: 0.99)
      assert issue.status == :not_found
    end

    test "returns error with :fuzzy when extraction partially matches" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "the quick brown fox jumps",
            extractions: [
              # 2 of 3 tokens match — fuzzy at low threshold
              %Extraction{class: "phrase", text: "quick brown dog", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, [issue]} = PromptValidator.validate(template, fuzzy_threshold: 0.6)
      assert issue.status == :fuzzy
    end
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `mix test test/lang_extract/prompt_validator_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/prompt_validator_test.exs
git commit -m "Add validation tests for not_found and fuzzy cases"
```

### Task 3: Multiple issues and edge cases

**Files:**
- Modify: `test/lang_extract/prompt_validator_test.exs`

- [ ] **Step 1: Add tests for multiple issues and degenerate cases**

```elixir
    test "collects multiple issues across multiple examples" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Patient has hypertension.",
            extractions: [
              %Extraction{class: "condition", text: "hypertension", attributes: %{}},
              %Extraction{class: "drug", text: "aspirin", attributes: %{}}
            ]
          },
          %ExampleData{
            text: "Prescribed lisinopril.",
            extractions: [
              %Extraction{class: "drug", text: "metformin", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, issues} = PromptValidator.validate(template)
      assert length(issues) == 2

      [first, second] = issues
      assert first.example_index == 0
      assert first.extraction_index == 1
      assert first.extraction_text == "aspirin"
      assert second.example_index == 1
      assert second.extraction_index == 0
      assert second.extraction_text == "metformin"
    end

    test "returns :ok for template with no examples" do
      template = %PromptTemplate{description: "Extract."}
      assert :ok = PromptValidator.validate(template)
    end

    test "returns :ok for example with no extractions" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [%ExampleData{text: "Some text."}]
      }

      assert :ok = PromptValidator.validate(template)
    end

    test "extraction with empty text produces :not_found issue" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Some text here.",
            extractions: [
              %Extraction{class: "thing", text: "", attributes: %{}}
            ]
          }
        ]
      }

      assert {:error, [issue]} = PromptValidator.validate(template)
      assert issue.status == :not_found
      assert issue.extraction_text == ""
    end

    test "duplicate extraction texts within one example both align" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Take aspirin daily with aspirin.",
            extractions: [
              %Extraction{class: "drug", text: "aspirin", attributes: %{}},
              %Extraction{class: "drug", text: "aspirin", attributes: %{}}
            ]
          }
        ]
      }

      assert :ok = PromptValidator.validate(template)
    end
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `mix test test/lang_extract/prompt_validator_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/prompt_validator_test.exs
git commit -m "Add validation tests for multiple issues, edge cases"
```

### Task 4: validate!/1

**Files:**
- Modify: `test/lang_extract/prompt_validator_test.exs`

- [ ] **Step 1: Add tests for the bang variant**

```elixir
  describe "validate!/1" do
    test "returns :ok when all examples align" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Patient has diabetes.",
            extractions: [
              %Extraction{class: "condition", text: "diabetes", attributes: %{}}
            ]
          }
        ]
      }

      assert :ok = PromptValidator.validate!(template)
    end

    test "raises ValidationError with issues when alignment fails" do
      template = %PromptTemplate{
        description: "Extract.",
        examples: [
          %ExampleData{
            text: "Patient has diabetes.",
            extractions: [
              %Extraction{class: "drug", text: "tylenol", attributes: %{}}
            ]
          }
        ]
      }

      error = assert_raise PromptValidator.ValidationError, fn ->
        PromptValidator.validate!(template)
      end

      assert length(error.issues) == 1
      assert Exception.message(error) =~ "1 alignment issue(s) found"
    end
  end
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `mix test test/lang_extract/prompt_validator_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/prompt_validator_test.exs
git commit -m "Add validate!/1 tests"
```

### Task 5: Final verification

- [ ] **Step 1: Run the full test suite**

Run: `mix test --trace`
Expected: ALL PASS

- [ ] **Step 2: Verify no warnings**

Run: `mix compile --warnings-as-errors`
Expected: PASS
