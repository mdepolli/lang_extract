# Benchmark Baselines

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
  pieces: 53/15/5 vs 55/16/6 on moby-dick/romeo/carol). Remaining suspect:
  per-request generation time — prompt/output format (YAML + verbatim
  instruction vs JSON) shifting output length or adaptive-thinking spend.
  Undiagnosable until the runners record the API `usage` block; neither
  does today.

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
