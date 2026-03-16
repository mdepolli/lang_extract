# Span Aligner Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a tokenizer and span aligner that maps extraction strings to byte positions in source text.

**Architecture:** Regex-based tokenizer tracks byte offsets per token. Two-phase aligner: exact matching via `List.myers_difference/2`, fuzzy sliding-window fallback. Pure Elixir, no dependencies.

**Tech Stack:** Elixir, Mix, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-15-lang-extract-span-aligner-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `mix.exs` | Project config, no deps |
| `lib/lang_extract.ex` | Top-level convenience `align/2,3` delegating to Aligner |
| `lib/lang_extract/token.ex` | Token struct |
| `lib/lang_extract/tokenizer.ex` | Regex tokenizer with byte offset tracking |
| `lib/lang_extract/span.ex` | Span struct |
| `lib/lang_extract/aligner.ex` | Two-phase alignment algorithm |
| `test/lang_extract/tokenizer_test.exs` | Tokenizer tests |
| `test/lang_extract/aligner_test.exs` | Aligner tests (exact, fuzzy, edge cases) |
| `test/test_helper.exs` | ExUnit setup |

---

## Chunk 1: Project Scaffold + Token Struct

### Task 1: Create the Mix project

**Files:**
- Create: `mix.exs`, `lib/lang_extract.ex`, `test/test_helper.exs`

- [ ] **Step 1: Generate Mix project**

Run from `/Users/marcelo/code`:

```bash
mix new lang_extract
```

- [ ] **Step 2: Verify it compiles and tests pass**

```bash
cd /Users/marcelo/code/lang_extract && mix test
```

Expected: `1 test, 0 failures` (the default generated test)

- [ ] **Step 3: Remove the default generated test and module body**

Delete `test/lang_extract_test.exs`. Replace `lib/lang_extract.ex` with:

```elixir
defmodule LangExtract do
  @moduledoc """
  Extracts structured data from text with source grounding.
  Maps extraction strings back to exact byte positions in source text.
  """

  alias LangExtract.Aligner

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
end
```

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "Scaffold Mix project with top-level LangExtract module"
```

### Task 2: Token struct

**Files:**
- Create: `lib/lang_extract/token.ex`

- [ ] **Step 1: Create the Token struct**

```elixir
defmodule LangExtract.Token do
  @moduledoc """
  A token with its byte position in the source text.

  Offsets are byte positions in the UTF-8 binary, matching `Regex.scan/3`
  with `return: :index` and consumable by `binary_part/3`.
  """

  @type token_type :: :word | :number | :punctuation | :whitespace

  @type t :: %__MODULE__{
          text: String.t(),
          type: token_type(),
          byte_start: non_neg_integer(),
          byte_end: non_neg_integer()
        }

  @enforce_keys [:text, :type, :byte_start, :byte_end]
  defstruct [:text, :type, :byte_start, :byte_end]
end
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/marcelo/code/lang_extract && mix compile
```

Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add lib/lang_extract/token.ex && git commit -m "Add Token struct with byte offset fields"
```

### Task 3: Span struct

**Files:**
- Create: `lib/lang_extract/span.ex`

- [ ] **Step 1: Create the Span struct**

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
          status: status()
        }

  @enforce_keys [:text, :status]
  defstruct [:text, :byte_start, :byte_end, :status]
end
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/marcelo/code/lang_extract && mix compile
```

- [ ] **Step 3: Commit**

```bash
git add lib/lang_extract/span.ex && git commit -m "Add Span struct for aligned extractions"
```

---

## Chunk 2: Tokenizer (TDD)

### Task 4: Tokenizer — basic ASCII words and punctuation

**Files:**
- Create: `lib/lang_extract/tokenizer.ex`, `test/lang_extract/tokenizer_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LangExtract.TokenizerTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Token, Tokenizer}

  describe "tokenize/1" do
    test "splits words and punctuation with correct byte offsets" do
      tokens = Tokenizer.tokenize("Hello, world!")

      assert [
               %Token{text: "Hello", type: :word, byte_start: 0, byte_end: 5},
               %Token{text: ",", type: :punctuation, byte_start: 5, byte_end: 6},
               %Token{text: " ", type: :whitespace, byte_start: 6, byte_end: 7},
               %Token{text: "world", type: :word, byte_start: 7, byte_end: 12},
               %Token{text: "!", type: :punctuation, byte_start: 12, byte_end: 13}
             ] = tokens
    end

    test "empty string returns empty list" do
      assert [] = Tokenizer.tokenize("")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/tokenizer_test.exs
```

Expected: FAIL — `Tokenizer` module not found

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule LangExtract.Tokenizer do
  @moduledoc """
  Regex-based tokenizer that splits text into tokens with byte offsets.

  Whitespace tokens are preserved for continuous offset mapping.
  No text normalization is applied.
  """

  alias LangExtract.Token

  @token_pattern ~r/\p{L}[\p{L}\p{M}\x{2019}'\-]*|\d[\d.,]*|[^\s]|\s+/u

  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(text) when is_binary(text) do
    @token_pattern
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{byte_start, length}] ->
      byte_end = byte_start + length
      token_text = binary_part(text, byte_start, length)

      %Token{
        text: token_text,
        type: classify(token_text),
        byte_start: byte_start,
        byte_end: byte_end
      }
    end)
  end

  defp classify(text) do
    cond do
      Regex.match?(~r/^\p{L}/u, text) -> :word
      Regex.match?(~r/^\d/, text) -> :number
      Regex.match?(~r/^\s/, text) -> :whitespace
      true -> :punctuation
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/tokenizer_test.exs
```

Expected: 2 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/tokenizer.ex test/lang_extract/tokenizer_test.exs && git commit -m "Add tokenizer with basic ASCII support"
```

### Task 5: Tokenizer — numbers, contractions, whitespace runs

**Files:**
- Modify: `test/lang_extract/tokenizer_test.exs`

- [ ] **Step 1: Add more tests**

Add to the `describe "tokenize/1"` block:

```elixir
    test "keeps contractions as single tokens" do
      tokens = Tokenizer.tokenize("don't won't")
      words = Enum.filter(tokens, &(&1.type == :word))
      assert [%Token{text: "don't"}, %Token{text: "won't"}] = words
    end

    test "groups numbers with separators" do
      tokens = Tokenizer.tokenize("costs $1,234.56 total")
      number = Enum.find(tokens, &(&1.type == :number))
      assert %Token{text: "1,234.56", byte_start: 7, byte_end: 15} = number
    end

    test "preserves whitespace runs" do
      tokens = Tokenizer.tokenize("a  b")
      ws = Enum.find(tokens, &(&1.type == :whitespace))
      assert %Token{text: "  ", byte_start: 1, byte_end: 3} = ws
    end
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/tokenizer_test.exs
```

Expected: 5 tests, 0 failures (should pass with existing implementation)

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/tokenizer_test.exs && git commit -m "Add tokenizer tests for contractions, numbers, whitespace"
```

### Task 6: Tokenizer — Unicode (multibyte characters)

**Files:**
- Modify: `test/lang_extract/tokenizer_test.exs`

- [ ] **Step 1: Add Unicode tests**

Add to the `describe "tokenize/1"` block:

```elixir
    test "handles multibyte UTF-8 characters with correct byte offsets" do
      # é is 2 bytes in UTF-8, ñ is 2 bytes
      tokens = Tokenizer.tokenize("café señor")

      cafe = Enum.find(tokens, &(&1.text == "café"))
      assert %Token{byte_start: 0, byte_end: 5} = cafe  # c(1) a(1) f(1) é(2) = 5 bytes

      senor = Enum.find(tokens, &(&1.text == "señor"))
      assert %Token{byte_start: 6, byte_end: 12} = senor  # s(1) e(1) ñ(2) o(1) r(1) = 6 bytes
    end

    test "byte offsets can round-trip via binary_part" do
      source = "café señor"
      tokens = Tokenizer.tokenize(source)

      for token <- tokens do
        length = token.byte_end - token.byte_start
        assert binary_part(source, token.byte_start, length) == token.text
      end
    end

    test "handles CJK characters (3 bytes each in UTF-8)" do
      # 你 = 3 bytes, 好 = 3 bytes, space = 1 byte, 世 = 3 bytes, 界 = 3 bytes
      tokens = Tokenizer.tokenize("你好 世界")

      hello = Enum.find(tokens, &(&1.text == "你好"))
      assert %Token{byte_start: 0, byte_end: 6} = hello

      world = Enum.find(tokens, &(&1.text == "世界"))
      assert %Token{byte_start: 7, byte_end: 13} = world
    end

    test "handles emoji (4 bytes in UTF-8)" do
      # 🎉 = 4 bytes
      source = "hello 🎉 world"
      tokens = Tokenizer.tokenize(source)

      emoji = Enum.find(tokens, &(&1.text == "🎉"))
      assert %Token{byte_start: 6, byte_end: 10} = emoji

      world = Enum.find(tokens, &(&1.text == "world"))
      assert %Token{byte_start: 11, byte_end: 16} = world
    end
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/tokenizer_test.exs
```

Expected: 9 tests, 0 failures

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/tokenizer_test.exs && git commit -m "Add Unicode byte offset tests for tokenizer"
```

---

## Chunk 3: Aligner — Exact Match (TDD)

### Task 7: Aligner — exact single-word match

**Files:**
- Create: `lib/lang_extract/aligner.ex`, `test/lang_extract/aligner_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LangExtract.AlignerTest do
  use ExUnit.Case, async: true

  alias LangExtract.{Aligner, Span}

  describe "exact matching" do
    test "aligns a single word" do
      assert [%Span{text: "fox", byte_start: 16, byte_end: 19, status: :exact}] =
               Aligner.align("the quick brown fox", ["fox"])
    end

    test "aligns a multi-word phrase" do
      assert [%Span{text: "quick brown", byte_start: 4, byte_end: 15, status: :exact}] =
               Aligner.align("the quick brown fox", ["quick brown"])
    end

    test "matches case-insensitively" do
      assert [%Span{text: "hello", byte_start: 0, byte_end: 5, status: :exact}] =
               Aligner.align("Hello world", ["hello"])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/aligner_test.exs
```

Expected: FAIL — `Aligner` module not found

- [ ] **Step 3: Write the Aligner with Phase 1 (exact match)**

```elixir
defmodule LangExtract.Aligner do
  @moduledoc """
  Maps extraction strings to byte spans in source text.

  Phase 1: Exact contiguous match via `List.myers_difference/2`.
  Phase 2: Fuzzy sliding-window fallback.
  """

  alias LangExtract.{Span, Tokenizer}

  @default_fuzzy_threshold 0.75

  @spec align(String.t(), [String.t()], keyword()) :: [Span.t()]
  def align(source, extractions, opts \\ []) do
    fuzzy_threshold = Keyword.get(opts, :fuzzy_threshold, @default_fuzzy_threshold)
    source_tokens = Tokenizer.tokenize(source)
    source_words = reject_whitespace(source_tokens)

    Enum.map(extractions, fn extraction ->
      align_one(extraction, source_words, fuzzy_threshold)
    end)
  end

  defp align_one("", _source_words, _threshold) do
    %Span{text: "", byte_start: nil, byte_end: nil, status: :not_found}
  end

  defp align_one(extraction, source_words, threshold) do
    ext_tokens = extraction |> Tokenizer.tokenize() |> reject_whitespace()

    case exact_match(extraction, source_words, ext_tokens) do
      {:ok, span} -> span
      :no_match -> fuzzy_match(extraction, source_words, ext_tokens, threshold)
    end
  end

  defp exact_match(extraction, source_words, ext_tokens) do
    source_texts = Enum.map(source_words, &String.downcase(&1.text))
    ext_texts = Enum.map(ext_tokens, &String.downcase(&1.text))
    ext_length = length(ext_texts)

    diff = List.myers_difference(source_texts, ext_texts)

    {match, _index} =
      Enum.reduce(diff, {nil, 0}, fn
        {:eq, segment}, {best, src_idx} ->
          seg_len = length(segment)

          best =
            if seg_len >= ext_length and is_nil(best) do
              {src_idx, src_idx + ext_length - 1}
            else
              best
            end

          {best, src_idx + seg_len}

        {:del, segment}, {best, src_idx} ->
          {best, src_idx + length(segment)}

        {:ins, _segment}, {best, src_idx} ->
          {best, src_idx}
      end)

    case match do
      {start_idx, end_idx} ->
        first = Enum.at(source_words, start_idx)
        last = Enum.at(source_words, end_idx)

        {:ok,
         %Span{
           text: extraction,
           byte_start: first.byte_start,
           byte_end: last.byte_end,
           status: :exact
         }}

      nil ->
        :no_match
    end
  end

  # Fuzzy match placeholder — implemented in Task 9
  defp fuzzy_match(extraction, _source_words, _ext_tokens, _threshold) do
    %Span{text: extraction, byte_start: nil, byte_end: nil, status: :not_found}
  end

  defp reject_whitespace(tokens) do
    Enum.reject(tokens, &(&1.type == :whitespace))
  end
end
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/aligner_test.exs
```

Expected: 3 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/aligner.ex test/lang_extract/aligner_test.exs && git commit -m "Add aligner with Phase 1 exact match via Myers diff"
```

### Task 8: Aligner — exact match edge cases

**Files:**
- Modify: `test/lang_extract/aligner_test.exs`

- [ ] **Step 1: Add edge case tests**

Add to the `describe "exact matching"` block:

```elixir
    test "aligns multiple extractions independently" do
      source = "the quick brown fox jumps over the lazy dog"

      assert [
               %Span{text: "quick brown", status: :exact},
               %Span{text: "lazy dog", status: :exact}
             ] = Aligner.align(source, ["quick brown", "lazy dog"])
    end

    test "first occurrence wins for duplicates" do
      source = "hello world hello"

      assert [%Span{text: "hello", byte_start: 0, byte_end: 5, status: :exact}] =
               Aligner.align(source, ["hello"])
    end

    test "matches across punctuation boundaries" do
      source = "Hello, world!"

      assert [%Span{text: "Hello", byte_start: 0, byte_end: 5, status: :exact}] =
               Aligner.align(source, ["Hello"])
    end
```

Add a new describe block:

```elixir
  describe "edge cases" do
    test "empty source returns not_found" do
      assert [%Span{status: :not_found}] = Aligner.align("", ["hello"])
    end

    test "empty extraction returns not_found" do
      assert [%Span{text: "", status: :not_found}] = Aligner.align("hello", [""])
    end

    test "extraction longer than source returns not_found" do
      assert [%Span{status: :not_found}] =
               Aligner.align("hi", ["this is much longer than source"])
    end
  end
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/aligner_test.exs
```

Expected: 9 tests, 0 failures

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/aligner_test.exs && git commit -m "Add exact match edge case tests"
```

---

## Chunk 4: Aligner — Fuzzy Match (TDD)

### Task 9: Fuzzy sliding-window match

**Files:**
- Modify: `lib/lang_extract/aligner.ex`, `test/lang_extract/aligner_test.exs`

- [ ] **Step 1: Write the failing tests**

Add a new describe block to the test file:

```elixir
  describe "fuzzy matching" do
    test "matches when most tokens overlap" do
      source = "the quick brown fox jumps"
      # LLM returned "quick brown dog" — "dog" not in source, falls to fuzzy.
      # Windows of size 3 over source words:
      #   [the,quick,brown]=2/3  [quick,brown,fox]=2/3  [brown,fox,jumps]=1/3
      # First best window wins: indices 0-2, byte_start=0 ("the"), byte_end=15 ("brown")
      extraction = "quick brown dog"

      assert [%Span{byte_start: 0, byte_end: 15, status: :fuzzy}] =
               Aligner.align(source, [extraction])
    end

    test "returns not_found below threshold" do
      source = "the quick brown fox"
      extraction = "completely different words here"

      assert [%Span{status: :not_found}] = Aligner.align(source, [extraction])
    end

    test "respects custom fuzzy threshold" do
      source = "the quick brown fox jumps"
      # 1 of 3 tokens match — 0.33 ratio
      extraction = "quick red cat"

      # Default threshold 0.75 → not found
      assert [%Span{status: :not_found}] = Aligner.align(source, [extraction])

      # Lowered threshold → fuzzy match
      assert [%Span{status: :fuzzy}] =
               Aligner.align(source, [extraction], fuzzy_threshold: 0.3)
    end
  end
```

- [ ] **Step 2: Run tests to verify the new ones fail**

```bash
cd /Users/marcelo/code/lang_extract && mix test test/lang_extract/aligner_test.exs
```

Expected: fuzzy tests fail (placeholder returns `:not_found` for all)

- [ ] **Step 3: Implement the fuzzy sliding window**

Replace the `fuzzy_match` placeholder in `aligner.ex`:

```elixir
  defp fuzzy_match(extraction, source_words, ext_tokens, threshold) do
    ext_texts = Enum.map(ext_tokens, &String.downcase(&1.text))
    ext_length = length(ext_texts)

    if ext_length == 0 do
      %Span{text: extraction, byte_start: nil, byte_end: nil, status: :not_found}
    else
      ext_freq = build_freq(ext_texts)
      source_texts = Enum.map(source_words, &String.downcase(&1.text))

      best = slide_window(source_texts, source_words, ext_freq, ext_length)

      case best do
        {ratio, start_idx, end_idx} when ratio >= threshold ->
          first = Enum.at(source_words, start_idx)
          last = Enum.at(source_words, end_idx)

          %Span{
            text: extraction,
            byte_start: first.byte_start,
            byte_end: last.byte_end,
            status: :fuzzy
          }

        _ ->
          %Span{text: extraction, byte_start: nil, byte_end: nil, status: :not_found}
      end
    end
  end

  # NOTE: Enum.at/2 in the reduce is O(n), making this O(n^2) overall.
  # Acceptable for a spike. For production, use a zipper or convert to a tuple.
  defp slide_window(source_texts, _source_words, ext_freq, window_size) do
    source_length = length(source_texts)

    if source_length < window_size do
      {0.0, 0, 0}
    else
      # Build initial window frequency
      {init_window, rest} = Enum.split(source_texts, window_size)
      init_freq = build_freq(init_window)
      init_overlap = compute_overlap(init_freq, ext_freq)
      init_best = {init_overlap / window_size, 0, window_size - 1}

      {best, _freq} =
        rest
        |> Enum.with_index(window_size)
        |> Enum.reduce({init_best, init_freq}, fn {incoming, idx}, {{best_ratio, _, _} = best, freq} ->
          outgoing = Enum.at(source_texts, idx - window_size)
          freq = freq |> add_token(incoming) |> remove_token(outgoing)
          overlap = compute_overlap(freq, ext_freq)
          ratio = overlap / window_size

          best = if ratio > best_ratio, do: {ratio, idx - window_size + 1, idx}, else: best
          {best, freq}
        end)

      best
    end
  end

  defp build_freq(tokens) do
    Enum.frequencies(tokens)
  end

  defp add_token(freq, token) do
    Map.update(freq, token, 1, &(&1 + 1))
  end

  defp remove_token(freq, token) do
    case Map.get(freq, token) do
      1 -> Map.delete(freq, token)
      n when n > 1 -> Map.put(freq, token, n - 1)
      _ -> freq
    end
  end

  defp compute_overlap(window_freq, ext_freq) do
    Enum.reduce(ext_freq, 0, fn {token, ext_count}, acc ->
      window_count = Map.get(window_freq, token, 0)
      acc + min(window_count, ext_count)
    end)
  end
```

- [ ] **Step 4: Run all tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test
```

Expected: 14 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/lang_extract/aligner.ex test/lang_extract/aligner_test.exs && git commit -m "Add fuzzy sliding-window match (Phase 2)"
```

---

## Chunk 5: Unicode Alignment + Format + Final Verification

### Task 10: Unicode alignment

**Files:**
- Modify: `test/lang_extract/aligner_test.exs`

- [ ] **Step 1: Add Unicode alignment tests**

Add to the `describe "exact matching"` block:

```elixir
    test "aligns multibyte UTF-8 text with correct byte offsets" do
      source = "café señor bueno"

      assert [%Span{text: "señor", byte_start: 6, byte_end: 12, status: :exact}] =
               Aligner.align(source, ["señor"])
    end

    test "byte offsets round-trip via binary_part" do
      source = "naïve résumé format"

      [span] = Aligner.align(source, ["résumé"])
      assert span.status == :exact

      length = span.byte_end - span.byte_start
      assert binary_part(source, span.byte_start, length) == "résumé"
    end
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test
```

Expected: 16 tests, 0 failures

- [ ] **Step 3: Commit**

```bash
git add test/lang_extract/aligner_test.exs && git commit -m "Add Unicode alignment tests"
```

### Task 11: Format and final verification

- [ ] **Step 1: Run formatter**

```bash
cd /Users/marcelo/code/lang_extract && mix format
```

- [ ] **Step 2: Run all tests**

```bash
cd /Users/marcelo/code/lang_extract && mix test
```

Expected: 16 tests, 0 failures

- [ ] **Step 3: Commit if formatter made changes**

```bash
cd /Users/marcelo/code/lang_extract && git diff --quiet || (git add -A && git commit -m "Run mix format")
```

- [ ] **Step 4: Verify the top-level convenience function works**

Run in iex:

```bash
cd /Users/marcelo/code/lang_extract && mix run -e '
  source = "the quick brown fox jumps over the lazy dog"
  results = LangExtract.align(source, ["quick brown", "lazy dog", "purple elephant"])
  IO.inspect(results, label: "results")
'
```

Expected: two `:exact` spans with correct byte offsets, one `:not_found`
