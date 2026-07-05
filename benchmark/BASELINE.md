# Benchmark Baselines

## Instrumented baseline — 2026-07-05 (Phase 0, pre-streaming)

All four runs at `27db4343` (clean, phase-0-instrumentation branch), both
libraries pinned to concurrency 2, first runs carrying `usage` blocks
(token counts + per-request latency). This is the controlled baseline the
Phase 1 streaming refactor measures against.

|                     | Dialogue E / P      | NER E / P           |
| ------------------- | ------------------- | ------------------- |
| Avg time/doc        | 64.4s / 66.4s       | 106.3s / 49.7s      |
| Input tokens        | 267,356 / 255,244   | 384,157 / 415,404   |
| Output tokens       | 127,530 / 130,009   | **233,072 / 86,017**|
| Output tokens/sec   | 165.0 / 163.2       | **182.8 / 144.3**   |
| Mean request        | 3,513ms / 3,359ms   | 5,815ms / 2,572ms   |
| Chunk errors        | 0 / 0               | 2 / 0               |

**The ner timing gap is resolved: output volume, not pipeline speed.**
Elixir generates 2.7× the output tokens for the same extraction count and
does so at *higher* throughput (182.8 vs 144.3 tok/s) — the 2.3× mean-
request gap is fully accounted for by token volume. Per-extraction output
(≈118 tokens Elixir, ≈42 Python, vs ≈12–15 visible) shows both sides are
dominated by adaptive-thinking spend; our YAML + verbatim-instruction
prompt elicits ~3× the thinking of Python's JSON prompt on entity-dense
chunks. Dialogue is the control: near-identical token profiles and even
timing. Follow-up (optional, prompt-tuning territory): capture the
thinking/visible split by comparing response text size to `output_tokens`.

Run directories: `dialogue_20260705_062044`/`_062045`,
`ner_20260705_063408`/`_063409` (elixir/python respectively).

### Format A/B (2026-07-05, corpus-scale, under the Q/A scaffold)

Arm A (fenced YAML, clean at `c840dbc5`: `dialogue_20260705_155859`,
`ner_20260705_161416`) vs arm B (fenced JSON, dirty probe:
`dialogue_20260705_163429`, `ner_20260705_165037`):

|                        | A: YAML (dial / ner) | B: JSON (dial / ner) |
| ---------------------- | -------------------- | -------------------- |
| Chunk errors           | 0 / 0                | 0 / 0                |
| Extractions            | 1,389 / 2,033        | 1,331 / 1,970        |
| exact / fuzzy / nf     | 1319/68/2 · 1943/46/44 | 1314/**17/0** · 1894/32/44 |
| Output tokens          | 109,674 / 149,548    | 124,657 / **111,888** |
| Avg time/doc           | 76s / 95s            | 80s / **82s**        |

**Verdict: JSON adopted as the wire format.** The historical JSON-breakage
on dialogue quotes did not reproduce under fences + scaffold (0 errors in
440 quote-dense chunks — it was a framing artifact); dialogue alignment is
*better* under JSON; ner costs 25% fewer tokens. The one trade-off: +14%
dialogue output tokens from JSON string-escaping (Python pays the same).
Arm B ran dirty as probes must — the citable post-switch baseline is the
next clean-stamped run pair.

### Prompt-probe series (2026-07-05, single-document, moby-dick ner)

Five dirty-tree probes (~$1.50 total; not citable, ±10% single-run noise)
plus a free request-body diff, chasing the 2× thinking spend:

| Variant                          | Output tokens | Tok/ext | Errors |
| -------------------------------- | ------------- | ------- | ------ |
| Baseline (YAML + instruction)    | 30,200        | 117     | 0      |
| No verbatim instruction          | 27,721        | 103     | 0      |
| JSON output                      | 32,764        | 170     | 3      |
| Q/A scaffold (`A:` primer)       | 24,068        | 90      | 0      |
| Full mimicry (Q/A + JSON)        | 27,868        | 103     | 0      |
| Q/A + fenced YAML answers        | **21,631**    | **85**  | 0      |
| Python reference                 | 14,529        | 58      | 0      |

Findings: transport exonerated (request bodies byte-identical in
structure); verbatim instruction exonerated (and its removal did NOT
degrade alignment on this doc — baseline moby has 23 not_found
intrinsically). **The lever is the `Q:`/`A:` scaffold with trailing
answer primer (~20%)** — adopted in Prompt.Builder. Attribution
correction: example answers were *always* code-fenced (by
`WireFormat.format_extractions`); the "Q/A + fences" row double-fenced,
so its extra −8% over the scaffold row is within single-run noise, not a
fence effect. The JSON probe row also under-mimicked upstream (unfenced
JSON), so the format question remains open pending a corpus A/B under
the adopted scaffold: fenced YAML vs fenced JSON, judged on chunk
errors, alignment parity, extraction counts, and token cost. Residual
~1.5× vs Python is below the single-run noise floor to attribute
further; if pursued beyond the A/B: capture response content-block
sizes to split visible output from thinking spend directly.

Definitive parity runs between LangExtract (Elixir) and upstream
[google/langextract](https://github.com/google/langextract) (Python), 12
Project Gutenberg documents per task. This snapshot exists because
`benchmark/results/` is gitignored; it preserves the citable numbers and full
provenance.

## Dialogue — 2026-07-04

|                        | Elixir            | Python            |
| ---------------------- | ----------------- | ----------------- |
| Documents / failures   | 12 / 0            | 12 / 0            |
| Chunk errors           | 0                 | 0                 |
| Total extractions      | 1,224             | 1,216             |
| Exact                  | 1,147 (93.7%)     | 1,139 (93.7%)     |
| Fuzzy                  | 75                | 76                |
| Not found              | 2                 | 1                 |
| Avg time/doc           | 74.5s             | 73.0s             |

Cross-library agreement (998 matched pairs, 82% match rate):

- Class agreement: 100.0%
- Status agreement: 92.4%
- Attribute agreement: 58.7% (strict dict equality on speaker labels — a
  free-text field, so this measures model phrasing stability, not library
  behavior; both libraries pass attributes through verbatim)
- Byte offsets identical: 95.8% of the 907 both-exact pairs
  (mean delta 41.4 bytes, max 14,479 bytes on the disagreeing tail)

| Provenance         | Elixir                          | Python                          |
| ------------------ | ------------------------------- | ------------------------------- |
| Run directory      | `dialogue_20260704_180711`      | `dialogue_20260704_182234`      |
| Runner commit      | `e3a52ccd` (clean)              | `e3a52ccd` (clean)              |

## NER — 2026-07-04 (post occurrence-DP port)

|                        | Elixir            | Python            |
| ---------------------- | ----------------- | ----------------- |
| Documents / failures   | 12 / 0            | 12 / 0            |
| Chunk errors           | 0                 | 0                 |
| Total extractions      | 1,978             | 2,028             |
| Exact / fuzzy / not_found | 1,884 / 49 / 45 | 1,990 / 38 / 0    |
| Avg time/doc           | 109.3s            | 60.9s             |

Cross-library agreement (1,714 matched pairs, 85% match rate):

- Class agreement: 98.4% (person/place/organization taxonomy)
- Status agreement: 93.9%
- Byte offsets identical: 70.8% of 1,607 both-exact pairs — but this
  headline is dominated by sampling variance, not aligner behavior. The
  conditional decomposition:
  - Unique texts: **93.0%** identical
  - Repeated texts where both sides extracted the same mention count:
    **90.9%** identical (the honest aligner-parity number for repeats)
  - Repeated texts overall: 65.2% — for 172 of 267 repeated texts the two
    model runs extracted *different* mention counts (no sampling controls
    on claude-sonnet-5), which forces offset mismatches no aligner can
    reconcile.
- Duplicate groundings (same text, same offsets within a document):
  Elixir 64, Python 0 — down from 594 before the occurrence-DP port. The
  residual comes from the documented standalone-vs-joint leftover-phase
  divergence (see `@known_divergences` in `aligner_parity_test.exs`).
- Elixir's 45 not_found: 5 are the documented contraction-tokenization
  divergence (smart-quote possessives); the rest are model-attributed
  entities absent from their chunk (concentrated in Moby-Dick's
  quotation-heavy front matter).
- Timing: Elixir runs ~1.7× slower per doc on ner (dialogue was even).
  Reproduced across three runs (109.3s, 105.9s pre-port, 102.1s in the
  2026-07-05 re-measure at `b982eed3` after the unordered-stream fix). Two
  hypotheses eliminated: stream-ordering starvation (unordered stream, same
  concurrency 2 → no change) and chunk counts (both chunkers cut ~the same
  pieces: 53/15/5 vs 55/16/6 on moby-dick/romeo/carol).
  **Resolved by the 2026-07-05 instrumented baseline (above): output
  volume — prompt-elicited thinking spend — not pipeline speed.**

| Provenance         | Elixir                          | Python                          |
| ------------------ | ------------------------------- | ------------------------------- |
| Run directory      | `ner_20260704_194734`           | `ner_20260704_185324`           |
| Runner commit      | `ee74a310` (clean)              | `db2cbe14` (clean)              |

The differing runner commits are intentional: the Python side ran before the
occurrence-DP port (`ee74a31`) and stays valid — no Python-side code changed
between the two commits. The pre-port Elixir run (`ner_20260704_185323`,
stamped `db2cbe14`) measured 52.0% offsets identical and 594 duplicate
groundings; it is superseded, kept here only as the before/after record of
the port.

## Shared provenance

| Field           | Value                                            |
| --------------- | ------------------------------------------------ |
| Library versions| lang_extract 0.4.0 (+ main), langextract 1.6.0 @ `0dff5479` |
| Model           | claude-sonnet-5 (no sampling controls available) |
| Max tokens      | 8,192                                            |
| Chunk size      | 1,000 chars                                      |
| Wire format     | Elixir YAML (native), Python JSON (upstream default) |

Full stamps live in each result file's `meta` key; comparison reports are
generated by `benchmark/scripts/compare.py` (match threshold 0.8).

## Reading these numbers

- Each library runs its **native wire format**. Upstream's YAML path cannot
  parse Sonnet 5 output (verified broken at v1.6.0), so same-format runs
  would only benchmark that gap.
- claude-sonnet-5 accepts no sampling controls, so **count-level metrics
  (totals, exact/fuzzy splits) are single-run samples** — expect ±1–2%
  between reruns. Conditional metrics (class/status/offset agreement on
  matched pairs) are stable across runs.
- The dialogue baseline follows the aligner parity port (upstream v1.6.0
  lesser + LCS semantics, commit `3d2132f`) and the verbatim prompt
  instruction (`e9b5339`). Before those, the Elixir exact rate was 77.5%
  with 93 not-found spans on the same corpus. The ner baseline additionally
  includes the occurrence-DP port (`ee74a31`).

To reproduce: `mix benchmark.run --task <task>` and
`benchmark/.venv/bin/python benchmark/scripts/run_python.py --task <task>`,
then `benchmark/.venv/bin/python benchmark/scripts/compare.py`.
