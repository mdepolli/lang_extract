# JSON wire format (was YAML)

- **Date:** 2026-07-05
- **Status:** adopted — encode side switched on main (0.6.0-era); the YAML
  decode/tolerance path was removed entirely in 0.7.0
- **Evidence:** corpus A/B under the Q/A scaffold, 12 documents per task

## Context

The wire format was YAML, originally adopted because early JSON runs broke
on quote-dense dialogue chunks. The [Q/A scaffold decision](2026-07-05-qa-scaffold.md)
left the format question open: its JSON probe row had under-mimicked
upstream (unfenced), so a fair corpus-scale comparison was owed — fenced
YAML vs fenced JSON, judged on chunk errors, alignment parity, extraction
counts, and token cost.

## Experiment

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

## Verdict

**JSON adopted as the wire format.** The historical JSON-breakage on
dialogue quotes did not reproduce under fences + scaffold (0 errors in
440 quote-dense chunks — it was a framing artifact); dialogue alignment is
*better* under JSON; ner costs 25% fewer tokens. The one trade-off: +14%
dialogue output tokens from JSON string-escaping (Python pays the same).
Arm B ran dirty as probes must — the citable post-switch baseline is the
clean-stamped run pair in `benchmark/BASELINE.md`.
