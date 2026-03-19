# LangExtract Chunking — Design Spec

## Goal

Split long documents into chunks that fit within a character budget, respecting sentence boundaries. Integrate with the orchestrator so `run/4` can process documents that exceed LLM token limits.

## Architecture

```
source text
  → Chunker.chunk(text, max_chunk_size: 4000)
  → [%Chunk{text: "...", byte_start: 0}, %Chunk{text: "...", byte_start: 1523}, ...]

Orchestrator.run/4 (when :max_chunk_size is set):
  → chunk source
  → Task.async_stream: per chunk → build prompt (with previous_chunk) → infer → normalize → parse → align
  → adjust byte offsets per chunk
  → concatenate all spans
  → {:ok, [%Span{}]}
```

## Modules

### `LangExtract.Chunker`

Splits text into chunks respecting sentence boundaries.

**Public API:**

```elixir
@spec chunk(String.t(), keyword()) :: [Chunk.t()]
Chunker.chunk(text, max_chunk_size: 4000)
```

**Options:**
- `:max_chunk_size` — maximum characters per chunk (required)

**Return type:** List of `%Chunk{}` structs.

### `LangExtract.Chunker.Chunk`

A struct representing a text chunk with its position in the source.

```elixir
%Chunk{
  text: "The patient was diagnosed...",
  byte_start: 0    # byte offset in the original source
}
```

```elixir
defmodule LangExtract.Chunker.Chunk do
  @type t :: %__MODULE__{
          text: String.t(),
          byte_start: non_neg_integer()
        }

  @enforce_keys [:text, :byte_start]
  defstruct [:text, :byte_start]
end
```

`byte_start` is needed so the orchestrator can adjust span byte offsets when merging results across chunks. It is the byte offset of the chunk's first character in the original source binary.

### Sentence Detection

Sentence boundaries are detected by walking the token list produced by `Alignment.Tokenizer.tokenize/1`. A sentence ends when:

1. A punctuation token matches `.`, `!`, or `?` **and** the preceding word token + punctuation is not a known abbreviation
2. Trailing closing punctuation (`"`, `'`, `)`, `]`, `}`, `»`) is consumed into the same sentence
3. A newline followed by an uppercase-starting token is treated as a sentence break

**Known abbreviations:** `MapSet.new(["Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "St."])` — matching the original library.

**Implementation:** A `find_sentences/1` function that takes a list of tokens and returns a list of `{start_index, end_index}` ranges (indices into the token list). This is a pure function, testable in isolation.

### Three-Tier Chunking

The `chunk/2` function uses a three-tier strategy:

**Tier 1 — Sentence packing:** Pack whole sentences into a chunk until adding the next sentence would exceed `max_chunk_size`. This is the common case.

**Tier 2 — Newline splitting:** If a single sentence exceeds `max_chunk_size`, break it at newline boundaries within the sentence. Walk tokens, track the most recent newline position, and split when the accumulated text would exceed the budget. The newline token belongs to the preceding chunk; the next chunk starts at the first token after the newline. If the sentence has no newlines, it is emitted as a single oversized chunk (this is acceptable — the text simply won't fit in one LLM call, and the caller should increase `max_chunk_size`).

**Tier 3 — Token fallback:** If the very first token of a sentence exceeds `max_chunk_size` (e.g., a very long URL), it becomes its own chunk regardless of size.

**Text extraction:** Chunks are extracted from the source binary using `binary_part/3` with the token byte offsets, preserving exact byte positions. The `byte_start` field on each chunk records where it starts in the original source.

### Orchestrator Integration

`Orchestrator.run/4` gains support for `:max_chunk_size`:

```elixir
# No chunking (default)
LangExtract.run(client, source, template)

# With chunking
LangExtract.run(client, source, template, max_chunk_size: 4000)
```

When `:max_chunk_size` is present in opts:

1. Call `Chunker.chunk(source, max_chunk_size: n)` to get chunks
2. Process chunks with `Task.async_stream` (ordered, max_concurrency from opts or default 3):
   - For each chunk, build prompt via `Prompt.Builder.build(template, chunk.text, previous_chunk: prev_chunk_text)`
   - Call `provider.infer(prompt, client.options)`
   - Normalize + parse + align against `chunk.text`
   - Adjust byte offsets: add `chunk.byte_start` to each span's `byte_start` and `byte_end`. If `span.byte_start` is nil (status `:not_found`), the span is kept as-is without adjustment.
3. Concatenate all enriched spans from all chunks
4. Return `{:ok, all_spans}`

**`previous_chunk` context:** For each chunk, `previous_chunk` is the raw source text of the preceding `%Chunk{}` struct — not the LLM output from processing the prior chunk. This is available before any inference runs, so all chunks can be processed in parallel. For the first chunk, `previous_chunk` is `nil`.

**Error handling:** A chunk returning `{:error, reason}` from the pipeline is treated as a failure — enumeration stops and `run/4` returns that error. A task crash is also treated as a failure. The implementation collects `Task.async_stream` results and short-circuits on the first `{:error, _}` using `Enum.reduce_while/3`.

**Timeout:** LLM call timeouts are handled by HTTPower's built-in timeout (default 60s). No additional timeout layer is added at the orchestrator level. This can be revisited if needed.

**Concurrency option:** `:max_concurrency` controls parallel LLM calls (default 3). Passed through to `Task.async_stream`.

When `:max_chunk_size` is absent, `run/4` behaves exactly as today — single prompt, no chunking.

## File Structure

```
lib/lang_extract/chunker.ex          # NEW: chunk/2, Chunk struct, sentence detection
lib/lang_extract/orchestrator.ex     # MODIFIED: chunking + Task.async_stream in run/4
test/lang_extract/chunker_test.exs   # NEW
test/lang_extract/orchestrator_test.exs  # MODIFIED: add chunking tests
```

## Edge Cases to Test

### Chunker — Sentence detection
- Simple sentences separated by `.` → correct boundaries
- Abbreviations (`Dr.`, `Mr.`) do not break sentences
- `!` and `?` end sentences
- Trailing closing punctuation consumed into same sentence: `He said "hello."`
- Newline + uppercase starts a new sentence
- Newline + lowercase does not start a new sentence
- Empty text → `[]`
- Text with no sentence-ending punctuation → one sentence spanning entire text

### Chunker — chunk/2
- Text fits within max_chunk_size → single chunk
- Multiple sentences packed into chunks
- Single sentence exceeds max_chunk_size → split at newlines (tier 2)
- Single sentence exceeds max_chunk_size with no newlines → emitted as oversized chunk
- Single token exceeds max_chunk_size → token becomes its own chunk (tier 3)
- byte_start offsets are correct for each chunk
- Chunks cover the entire source text (no gaps, no overlaps)

### Orchestrator — chunking integration
- `:max_chunk_size` triggers chunking + parallel inference
- Span byte offsets are adjusted correctly across chunks
- `:not_found` span byte offsets are not adjusted (remain nil)
- Previous chunk context is passed to prompt builder (first chunk gets nil)
- Provider error in one chunk fails the entire run
- No `:max_chunk_size` → same behavior as before (no chunking)

## Out of Scope

- Variable chunk overlap (chunks don't overlap — context is provided via `previous_chunk` in the prompt)
- Multi-pass extraction with overlap resolution
- Token-count-based chunking (we use character count, not LLM tokens)
- Configurable abbreviation lists
