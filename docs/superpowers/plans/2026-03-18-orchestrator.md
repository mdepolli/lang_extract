# Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the full extraction pipeline end-to-end: configure a client, build a prompt, call an LLM, parse, align, return enriched spans.

**Architecture:** `LangExtract.new/2` creates a `%Client{}` with a resolved provider module and options. `LangExtract.run/3,4` delegates to `Orchestrator.run/4` which chains prompt building → provider inference → format normalization → parsing → alignment → span enrichment.

**Tech Stack:** Elixir, HTTPower (for integration tests), ExUnit

**Spec:** `docs/superpowers/specs/2026-03-18-orchestrator-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `lib/lang_extract/client.ex` | Create | Client struct (`provider`, `options`) |
| `lib/lang_extract/orchestrator.ex` | Create | Pipeline: `run/4` |
| `lib/lang_extract.ex` | Modify | Add `new/2`, `run/3,4`, `resolve_provider/1` |
| `test/lang_extract/orchestrator_test.exs` | Create | Full pipeline tests with HTTPower.Test stubs |

---

### Task 1: Client struct

**Files:**
- Create: `lib/lang_extract/client.ex`

- [ ] **Step 1: Create the Client struct**

```elixir
# lib/lang_extract/client.ex
defmodule LangExtract.Client do
  @moduledoc """
  A configured LLM client for extraction.

  Created via `LangExtract.new/2`. Holds the provider module and its options.
  """

  @type t :: %__MODULE__{
          provider: module(),
          options: keyword()
        }

  @enforce_keys [:provider]
  defstruct [:provider, options: []]
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/lang_extract/client.ex
git commit -m "Add Client struct"
```

### Task 2: LangExtract.new/2 + resolve_provider

**Files:**
- Modify: `lib/lang_extract.ex`
- Modify: `test/lang_extract/orchestrator_test.exs`

- [ ] **Step 1: Write tests for new/2**

```elixir
# test/lang_extract/orchestrator_test.exs
defmodule LangExtract.OrchestratorTest do
  use ExUnit.Case, async: true

  alias LangExtract.Client

  describe "LangExtract.new/2" do
    test "creates client with :claude provider" do
      client = LangExtract.new(:claude, api_key: "sk-test")

      assert %Client{provider: LangExtract.Provider.Claude, options: opts} = client
      assert opts[:api_key] == "sk-test"
    end

    test "creates client with :openai provider" do
      client = LangExtract.new(:openai, api_key: "sk-test")

      assert %Client{provider: LangExtract.Provider.OpenAI} = client
    end

    test "creates client with :gemini provider" do
      client = LangExtract.new(:gemini, api_key: "gm-test")

      assert %Client{provider: LangExtract.Provider.Gemini} = client
    end

    test "raises ArgumentError for unknown provider" do
      assert_raise ArgumentError, ~r/unknown provider/, fn ->
        LangExtract.new(:unknown, api_key: "test")
      end
    end

    test "defaults options to empty list" do
      client = LangExtract.new(:claude)

      assert client.options == []
    end
  end
end
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `mix test test/lang_extract/orchestrator_test.exs --trace`
Expected: FAIL — `LangExtract.new/2` not defined

- [ ] **Step 3: Add new/2 to LangExtract**

Add to `lib/lang_extract.ex` — add aliases and the new functions after the existing `extract/3`:

```elixir
  alias LangExtract.{Client, Provider}

  @doc """
  Creates a configured LLM client for extraction.

  ## Examples

      client = LangExtract.new(:claude, api_key: "sk-...")
      client = LangExtract.new(:openai, api_key: "sk-...", model: "gpt-4o")
      client = LangExtract.new(:gemini, api_key: "gm-...")

  """
  @spec new(atom(), keyword()) :: Client.t()
  def new(provider, opts \\ []) do
    module = resolve_provider(provider)
    %Client{provider: module, options: opts}
  end

  defp resolve_provider(:claude), do: Provider.Claude
  defp resolve_provider(:openai), do: Provider.OpenAI
  defp resolve_provider(:gemini), do: Provider.Gemini

  defp resolve_provider(other) do
    raise ArgumentError,
          "unknown provider: #{inspect(other)}. Expected :claude, :openai, or :gemini"
  end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `mix test test/lang_extract/orchestrator_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract.ex test/lang_extract/orchestrator_test.exs
git commit -m "Add LangExtract.new/2 with provider resolution"
```

### Task 3: Orchestrator.run/4 + LangExtract.run/3,4 — happy path

**Files:**
- Create: `lib/lang_extract/orchestrator.ex`
- Modify: `lib/lang_extract.ex`
- Modify: `test/lang_extract/orchestrator_test.exs`

- [ ] **Step 1: Write the happy path test**

```elixir
  describe "LangExtract.run/3,4" do
    setup do
      HTTPower.Test.setup()
    end

    test "full pipeline: prompt → LLM → parse → align → enriched spans" do
      HTTPower.Test.stub(fn conn ->
        # Simulate Claude returning dynamic-key format
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "extractions" => [
                    %{"word" => "fox", "word_attributes" => %{"type" => "noun"}}
                  ]
                })
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")

      template = %LangExtract.Prompt.Template{
        description: "Extract words from the text."
      }

      assert {:ok, [span]} = LangExtract.run(client, "the quick brown fox", template)
      assert span.class == "word"
      assert span.text == "fox"
      assert span.status == :exact
      assert span.attributes == %{"type" => "noun"}
      assert span.byte_start == 16
      assert span.byte_end == 19
    end
  end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `mix test test/lang_extract/orchestrator_test.exs --trace`
Expected: FAIL — `LangExtract.run/3` not defined

- [ ] **Step 3: Write the Orchestrator module**

```elixir
# lib/lang_extract/orchestrator.ex
defmodule LangExtract.Orchestrator do
  @moduledoc """
  Wires the full extraction pipeline.

  Builds a prompt, calls the LLM provider, normalizes and parses the response,
  aligns extractions to source text, and returns enriched spans.
  """

  alias LangExtract.{
    Alignment.Aligner,
    Alignment.Span,
    Client,
    Extraction,
    FormatHandler,
    Parser,
    Prompt
  }

  @spec run(Client.t(), String.t(), Prompt.Template.t(), keyword()) ::
          {:ok, [Span.t()]} | {:error, term()}
  def run(%Client{} = client, source, %Prompt.Template{} = template, opts \\ []) do
    prompt = Prompt.Builder.build(template, source)

    with {:ok, raw_output} <- client.provider.infer(prompt, client.options),
         {:ok, normalized} <- FormatHandler.normalize(raw_output),
         {:ok, extractions} <- Parser.parse(normalized) do
      texts = Enum.map(extractions, & &1.text)
      spans = Aligner.align(source, texts, opts)

      enriched =
        Enum.zip(extractions, spans)
        |> Enum.map(fn {%Extraction{} = extraction, %Span{} = span} ->
          %Span{span | class: extraction.class, attributes: extraction.attributes}
        end)

      {:ok, enriched}
    end
  end
end
```

- [ ] **Step 4: Add run/3,4 delegate to LangExtract**

Add after `new/2` in `lib/lang_extract.ex`:

```elixir
  alias LangExtract.Orchestrator

  @doc """
  Runs the full extraction pipeline: prompt → LLM → parse → align.

  ## Options

    * `:fuzzy_threshold` - minimum overlap ratio for fuzzy match (default `0.75`)

  ## Examples

      client = LangExtract.new(:claude, api_key: "sk-...")
      template = %LangExtract.Prompt.Template{description: "Extract entities."}
      {:ok, spans} = LangExtract.run(client, "the quick brown fox", template)

  """
  @spec run(Client.t(), String.t(), Prompt.Template.t(), keyword()) ::
          {:ok, [Alignment.Span.t()]} | {:error, term()}
  def run(%Client{} = client, source, template, opts \\ []) do
    Orchestrator.run(client, source, template, opts)
  end
```

- [ ] **Step 5: Run test, verify it passes**

Run: `mix test test/lang_extract/orchestrator_test.exs --trace`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/lang_extract/orchestrator.ex lib/lang_extract.ex test/lang_extract/orchestrator_test.exs
git commit -m "Add Orchestrator with full pipeline, LangExtract.run/3,4"
```

### Task 4: Error propagation + edge case tests

**Files:**
- Modify: `test/lang_extract/orchestrator_test.exs`

- [ ] **Step 1: Add error and edge case tests**

```elixir
    test "propagates provider error" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{"error" => "unauthorized"}, status: 401)
      end)

      client = LangExtract.new(:claude, api_key: "bad-key")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:error, :unauthorized} = LangExtract.run(client, "some text", template)
    end

    test "propagates format handler error for invalid LLM output" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "not valid json at all"}]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:error, :invalid_format} = LangExtract.run(client, "some text", template)
    end

    test "returns ok with empty list when LLM returns no extractions" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"extractions" => []})}
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:ok, []} = LangExtract.run(client, "some text", template)
    end

    test "extraction not found in source returns span with :not_found status" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "extractions" => [%{"thing" => "nonexistent", "thing_attributes" => %{}}]
                })
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:ok, [span]} = LangExtract.run(client, "hello world", template)
      assert span.status == :not_found
      assert span.class == "thing"
    end

    test "fuzzy_threshold option is passed through to aligner" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "extractions" => [
                    %{"phrase" => "quick brown dog", "phrase_attributes" => %{}}
                  ]
                })
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      # Default threshold (0.75) — not_found (2/3 = 0.67 < 0.75)
      assert {:ok, [span]} =
               LangExtract.run(client, "the quick brown fox jumps", template)

      assert span.status == :not_found

      # Low threshold — fuzzy match
      assert {:ok, [span]} =
               LangExtract.run(client, "the quick brown fox jumps", template,
                 fuzzy_threshold: 0.6
               )

      assert span.status == :fuzzy
    end

    test "multiple extractions aligned independently" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "extractions" => [
                    %{"animal" => "fox", "animal_attributes" => %{}},
                    %{"animal" => "dog", "animal_attributes" => %{}}
                  ]
                })
            }
          ]
        })
      end)

      client = LangExtract.new(:claude, api_key: "sk-test")
      template = %LangExtract.Prompt.Template{description: "Extract."}

      assert {:ok, [fox, dog]} =
               LangExtract.run(
                 client,
                 "the quick brown fox jumps over the lazy dog",
                 template
               )

      assert fox.text == "fox"
      assert fox.status == :exact
      assert dog.text == "dog"
      assert dog.status == :exact
    end
```

- [ ] **Step 2: Run tests, verify they pass**

Run: `mix test test/lang_extract/orchestrator_test.exs --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/orchestrator_test.exs
git commit -m "Add orchestrator error propagation and edge case tests"
```

### Task 5: Final verification

- [ ] **Step 1: Run the full test suite**

Run: `mix test --trace`
Expected: ALL PASS

- [ ] **Step 2: Verify no warnings**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 3: Run credo**

Run: `mix credo --strict`
Expected: No issues
