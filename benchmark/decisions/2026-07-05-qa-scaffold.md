# Q/A prompt scaffold

- **Date:** 2026-07-05
- **Status:** adopted in `Prompt.Builder` — `Q:`/`A:` example pairs with a
  trailing bare `A:` answer primer, mirroring langextract's
  `QAPromptGenerator`
- **Evidence:** five single-document probes (moby-dick ner) plus a
  request-body diff

## Context

The instrumented baseline resolved the ner timing gap as output volume:
Elixir elicited ~2× Python's thinking spend per extraction on entity-dense
chunks. These probes chased the prompt-side lever. Dirty-tree,
single-run (±10% noise), ~$1.50 total — directional, not citable.

## Experiment

| Variant                          | Output tokens | Tok/ext | Errors |
| -------------------------------- | ------------- | ------- | ------ |
| Baseline (YAML + instruction)    | 30,200        | 117     | 0      |
| No verbatim instruction          | 27,721        | 103     | 0      |
| JSON output                      | 32,764        | 170     | 3      |
| Q/A scaffold (`A:` primer)       | 24,068        | 90      | 0      |
| Full mimicry (Q/A + JSON)        | 27,868        | 103     | 0      |
| Q/A + fenced YAML answers        | **21,631**    | **85**  | 0      |
| Python reference                 | 14,529        | 58      | 0      |

## Findings

Transport exonerated (request bodies byte-identical in structure);
verbatim instruction exonerated (and its removal did NOT degrade alignment
on this doc — baseline moby has 23 not_found intrinsically). **The lever
is the `Q:`/`A:` scaffold with trailing answer primer (~20%)** — adopted.

Attribution correction: example answers were *always* code-fenced (by
`WireFormat.format_extractions`); the "Q/A + fences" row double-fenced, so
its extra −8% over the scaffold row is within single-run noise, not a
fence effect. The JSON probe row under-mimicked upstream (unfenced JSON),
so the format question stayed open pending a corpus A/B under the adopted
scaffold — resolved in [the JSON wire-format decision](2026-07-05-json-wire-format.md).
Residual ~1.5× vs Python is below the single-run noise floor to attribute
further; if pursued: capture response content-block sizes to split visible
output from thinking spend directly.
