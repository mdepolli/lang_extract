# CLAUDE.md

## Project Overview

LangExtract is an Elixir port of [google/langextract](https://github.com/google/langextract) (Python).
It extracts structured data from text using LLMs, grounding every extraction to exact byte positions
in the source. The upstream Python library lives at `~/code/langextract`.

## Architecture

```
lib/lang_extract/
├── alignment/        # Tokenizer, Token, Aligner, Span
├── pipeline/         # FormatHandler, Parser, Extraction, ChunkError
├── prompt/           # Template, ExampleData, Builder, Validator
├── provider/         # Claude, OpenAI, Gemini implementations
├── client.ex         # Configured LLM client struct
├── orchestrator.ex   # Pipeline wiring + chunking
├── chunker.ex        # Sentence-aware text splitting
├── pipeline.ex       # Extraction pipeline public API
└── io.ex             # Serialization + JSONL
```

**Key data flow:** Orchestrator chunks source text → sends each chunk to the LLM →
Pipeline normalizes YAML response → Parser creates Extraction structs → Aligner maps
extractions back to byte positions in source.

**Return shape of `LangExtract.run/4`:**
`{:ok, {spans, chunk_errors}} | {:error, reason}`

- `chunk_errors` are `%Pipeline.ChunkError{}` structs with `byte_start`, `byte_end`, `reason`
- `{:error, reason}` is only for infrastructure failures (task exits, timeouts)

## Running Tests

```bash
mix test                          # 202 tests
mix compile --warnings-as-errors  # Must pass
mix format --check-formatted      # Must pass
mix credo --strict                # Must pass with zero issues
```

## Benchmarks

Both Elixir and Python benchmarks share the same corpus and task definitions.
Results are stored per-library with identical output format for comparison.

### Directory Structure

```
benchmark/
├── corpus/             # Shared corpus texts (Project Gutenberg excerpts)
├── corpus.json         # Manifest: slug → Gutenberg URL + max_bytes
├── tasks/              # Task definitions: dialogue.json, ner.json, literary_devices.json
├── scripts/
│   ├── run_python.py   # Python benchmark runner (uses ClaudeProvider adapter)
│   ├── compare.py      # Cross-library comparison (needs update for new format)
│   └── download_corpus.py  # Downloads/refreshes corpus from Project Gutenberg
├── results/
│   ├── elixir/         # Elixir results: {task}_{timestamp}/ dirs + {task}_latest symlinks
│   └── python/         # Python results: same structure
└── .venv/              # Python virtualenv for running Python benchmarks
```

### Running Benchmarks

**Elixir** (requires `ANTHROPIC_API_KEY`):
```bash
mix benchmark.run --task dialogue                           # All documents
mix benchmark.run --task dialogue --document romeo-and-juliet  # Single document
```

**Python** (requires `ANTHROPIC_API_KEY`, uses the `.venv` in `benchmark/`):
```bash
benchmark/.venv/bin/python benchmark/scripts/run_python.py --task dialogue
benchmark/.venv/bin/python benchmark/scripts/run_python.py --task dialogue --document romeo-and-juliet
```

### Output Format

Each document produces a JSON file in a timestamped run directory:
```
benchmark/results/elixir/dialogue_20260406_031016/romeo-and-juliet.json
```

A `{task}_latest` relative symlink always points to the most recent run.

Each JSON file has:
```json
{
  "source": "romeo-and-juliet",
  "task": "dialogue",
  "library": "elixir",
  "extractions": [{"class": "...", "text": "...", "byte_start": 0, "byte_end": 42, "status": "exact", "attributes": {}}],
  "timing": {"total_ms": 49145},
  "errors": [{"byte_start": 0, "byte_end": 1000, "reason": "..."}]
}
```

### Python Benchmark Runner Details

The Python runner at `benchmark/scripts/run_python.py` contains a `ClaudeProvider` class that
implements `langextract`'s `BaseLanguageModel` interface. It makes direct HTTP calls to the
Anthropic API — the Python library itself only supports Gemini, OpenAI, and Ollama natively.

**Critical:** The Python runner must read corpus files in binary mode (`file.read_bytes()`)
to get the same byte positions as Elixir. Python's `read_text()` normalizes `\r\n` to `\n`,
which shifts all byte offsets and makes cross-library comparison impossible.

### Corpus

Texts are downloaded from Project Gutenberg via `benchmark/scripts/download_corpus.py`,
which reads `corpus.json` for URLs and optional `max_bytes` truncation. Gutenberg
boilerplate (header/footer) is stripped automatically.

### Known Differences Between Elixir and Python

- **Alignment precision:** Python's aligner works at the token level with `difflib.SequenceMatcher`
  and normalizes tokens (lowercase + light stemming). Elixir's aligner also works at the token
  level but uses `List.myers_difference/2` for exact match and a frequency-overlap sliding window
  for fuzzy match. Python tends to produce more `exact` matches; Elixir produces more `fuzzy`.
- **Byte vs char positions:** Elixir uses byte offsets natively. Python uses character positions
  internally (`CharInterval`) which are converted to byte offsets in the benchmark runner.
- **Smart quotes:** LLMs sometimes output smart quotes (`\u2019`) where the source has ASCII
  apostrophes (`'`). The Elixir aligner handles this via fuzzy matching but Python's token
  normalization handles it more naturally.

## Key Design Decisions

- **YAML wire format:** The LLM outputs YAML (not JSON), matching the upstream Python library.
  Unquoted YAML values containing `: ` (colon-space) are automatically quoted before parsing
  in `FormatHandler.normalize/1`.
- **No previous chunk context:** Disabled (Python also disables by default). Passing previous
  chunk text caused the LLM to extract from context it was given but that the aligner couldn't
  find in the current chunk, resulting in many `not_found` spans.
- **Always chunked:** There is no single-document mode. All text goes through the chunker,
  matching Python's behavior. Short text just produces one chunk.
- **Pipeline namespace:** `FormatHandler`, `Parser`, `Extraction`, and `ChunkError` live under
  `LangExtract.Pipeline.*`. Pipeline is the public API for the extraction context.
