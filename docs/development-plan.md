# LangExtract Development Plan

## Goal

Fully replicate the functionality of [google/langextract](https://github.com/google/langextract) as an idiomatic Elixir library. The library extracts structured data from text with source grounding — mapping LLM extraction strings back to exact byte positions in source text.

## Architecture Overview

The original Python library's pipeline:

```
extract(text, prompt, examples, model_id)
  → factory selects provider by model ID
  → tokenize + chunk document (sentence-aware)
  → for each batch of chunks:
      → build few-shot Q&A prompt (with previous chunk context)
      → LLM inference (parallel)
      → parse JSON/YAML output into extractions
      → align extractions to source byte positions
  → if multi-pass: repeat, merge with first-pass-wins overlap resolution
  → return AnnotatedDocument(s)
```

## Component Breakdown

| Component | LOC est. | Status | Actual LOC |
|---|---|---|---|
| Data structures | 250 | Done | ~55 (Token, Span, Extraction) |
| Tokenizer | 650 | Done | ~38 |
| Span alignment | 900 | Done | ~170 |
| Output parsing | 475 | Done | ~55 |
| Format handling | — | Done | ~99 |
| Prompt building | 275 | Done | ~89 (PromptBuilder, PromptTemplate, ExampleData) |
| Prompt validation | — | Not started | — |
| LLM provider calls | 500 | Not started | — |
| Chunking | 500 | Not started | — |
| Orchestration | 620 | Not started | — |
| I/O (serialization) | — | Not started | — |
| Visualization | 300 | Out of scope | — |

LOC estimates are from the original Python reference where available. Elixir implementations have been significantly more concise (~318 actual vs ~2,275 estimated for completed components).

## Component Details

### Done

- **Data structures** — `Token`, `Span`, and `Extraction` structs with enforced keys and typespecs. `Span` serves double duty: it holds alignment results (byte offsets, status) and enriched extraction data (`class`, `attributes`) when produced via `extract/3`.
- **Tokenizer** — Regex-based tokenizer producing tokens with byte offsets. Keeps contractions as single tokens (deliberate divergence from Python reference for better English alignment). The original also has a `UnicodeTokenizer` for CJK/emoji/grapheme clusters — we may need this later.
- **Span alignment** — Two-phase aligner: exact match via `List.myers_difference/2`, then fuzzy fallback via sliding window with token frequency overlap. Configurable fuzzy threshold (default 0.75). The original also does light plural stemming during normalization and has a `MATCH_LESSER` status for partial matches.
- **Output parsing** — Parses LLM JSON output into `Extraction` structs. Currently handles: markdown fence stripping and the `{"extractions": [...]}` wrapper key. Validates entries, skips invalid ones with warnings.
- **Top-level API** — `LangExtract.align/3` (delegates to `Aligner`) and `LangExtract.extract/3` (parse + align + merge class/attributes onto spans). This is a mini-orchestration layer that already wires together parsing and alignment.

### Remaining (in priority order)

1. **Format handling** — Centralized JSON/YAML formatting for both prompts and output parsing. The parser already handles markdown fence stripping and the `{"extractions": [...]}` wrapper key. This component would add: YAML parsing, `_attributes` suffix conventions, raw (unfenced) output handling, and `<think>` tag stripping for reasoning models. Refactor to centralize what the parser currently does inline.

2. **Prompt building** — More sophisticated than a simple template:
   - `PromptTemplateStructured`: description + list of few-shot `ExampleData` (text + expected extractions).
   - `QAPromptGenerator`: builds Q&A-formatted prompts using the format handler to serialize examples.
   - `ContextAwarePromptBuilder`: injects text from the previous chunk into the current prompt (configurable `context_window_chars`) for cross-chunk coreference resolution.
   - Templates can be loaded from YAML/JSON files.

3. **Prompt validation** — Pre-flight check that few-shot examples actually align with their own source text. Configurable strictness levels (off/warning/error). Catches badly-written examples before burning LLM tokens.

4. **LLM provider calls** — The original supports three providers, all with parallel inference via thread pools:
   - **Gemini**: API key or Vertex AI auth. Supports structured output via `response_schema`. Also has a batch API for high-volume work via GCS.
   - **OpenAI**: API key auth. JSON mode via system messages.
   - **Ollama**: Local inference, no auth needed.
   - Provider router with regex-based model ID matching (e.g., `^gemini` → Gemini provider).
   - Plugin system for community providers.
   - Our plan originally listed Claude — the original doesn't support it, but we should add it since this is an Elixir library.

5. **Chunking + Orchestration** (tightly coupled — develop together) —

   **Chunking** — Sentence-aware, three-tier strategy:
   1. Pack complete sentences up to `max_char_buffer`.
   2. If a single sentence exceeds buffer, break at newlines.
   3. If still too large, individual tokens become chunks.
   - Chunks grouped into batches of `batch_length` for inference.
   - Tokenizer provides sentence boundary detection with abbreviation awareness.

   **Orchestration** — The `Annotator` class wires the full pipeline:
   - Chunk documents → batch chunks → build prompts → LLM inference → parse → align → emit.
   - **Multi-pass extraction**: run the pipeline N times, merge results with first-pass-wins overlap resolution for non-overlapping extractions.
   - **Streaming**: emits completed documents as soon as all their chunks finish.
   - **Schema generation**: `GeminiSchema.from_examples()` introspects few-shot examples to build JSON Schema for Gemini's constrained decoding.
   - Will need an `AnnotatedDocument` struct (document ID + text + list of enriched spans) as the pipeline's return type.

6. **I/O** — JSONL serialization/deserialization for `AnnotatedDocument`s, URL fetching with multi-encoding support. Lower priority but needed for a complete library.

### Out of Scope

- **Visualization** — The original generates interactive HTML with color-coded highlights, animated playback, tooltips, and a Jupyter integration. Significant frontend work with limited Elixir relevance.
- **Progress tracking** — The original uses `tqdm` for terminal progress bars. Elixir would use `Logger` or a process-based approach; not a priority.
- **Backward compatibility layer** — The original has an extensive compat layer for v2.0 migration. Not relevant for a new library.

## Divergences from Python Reference

- **Byte offsets vs character offsets**: We use byte positions (natural for Elixir binaries); the original uses character intervals.
- **Contraction handling**: Our tokenizer keeps `don't` as one token; the original splits it into three.
- **YAML support**: The original supports both JSON and YAML output formats. We currently only support JSON. YAML may not be needed since modern LLMs handle JSON well with structured output modes.
- **Claude provider**: Not in the original; we should add it since Elixir users are likely to want it.
- **No `MATCH_LESSER` or `MATCH_GREATER` status**: Deliberate simplification. `MATCH_GREATER` is dead code in the original (defined but never set). `MATCH_LESSER` means a partial contiguous Myers match that preempts the fuzzy phase — but our fuzzy phase already handles the same scenario, and whether a partial contiguous match is better or worse than the best fuzzy window is case-dependent. Our three statuses (`:exact`, `:fuzzy`, `:not_found`) are cleaner. Revisit if we find cases where fuzzy picks a worse span than a partial Myers match would have.
- **Fuzzy matching algorithm**: Both implementations use a sliding window approach, but the original uses Python's `difflib.SequenceMatcher` with `Counter`-based pre-check optimization, while ours uses token frequency overlap. The original also normalizes tokens with light plural stemming (e.g., stripping trailing "s"); ours only downcases.

## Known Limitations / Tech Debt

- **O(n²) sliding window**: The fuzzy matcher's `slide_window` uses `Enum.at/2` (O(n)) inside a reduce, making it O(n²) overall. Acceptable for the current spike but will matter when chunking large documents. Fix: convert source words to a tuple or use a zipper.
- **No `LangExtract.align/3` test**: The public API delegate has no direct test — the underlying `Aligner.align/3` is tested, but a smoke test for the top-level function would catch delegation bugs.
- **Fixed fuzzy window size**: The original tests multiple window sizes for better recall. We use a fixed window equal to extraction token count. Variable sizes can be added if recall is insufficient.
