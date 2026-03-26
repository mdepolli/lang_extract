  ┌───────────────────┬────────────────────┬────────────────────┬────────────────────┐
  │      Metric       │        NER         │      Dialogue      │  Literary Devices  │
  ├───────────────────┼────────────────────┼────────────────────┼────────────────────┤
  │ Errors            │ Elixir 0, Python 2 │ Elixir 2, Python 0 │ Elixir 1, Python 0 │
  ├───────────────────┼────────────────────┼────────────────────┼────────────────────┤
  │ Extractions       │ 1940 vs 1286       │ 1728 vs 943        │ 1384 vs 862        │
  ├───────────────────┼────────────────────┼────────────────────┼────────────────────┤
  │ Match rate        │ 62%                │ 49%                │ 45%                │
  ├───────────────────┼────────────────────┼────────────────────┼────────────────────┤
  │ Class agreement   │ 100%               │ 100%               │ 100%               │
  ├───────────────────┼────────────────────┼────────────────────┼────────────────────┤
  │ Offset mean delta │ 1517b              │ 639b               │ 518b               │
  ├───────────────────┼────────────────────┼────────────────────┼────────────────────┤
  │ Status agreement  │ 69%                │ 62%                │ 46%                │
  ├───────────────────┼────────────────────┼────────────────────┼────────────────────┤
  │ Avg time/doc      │ 55s vs 100s        │ 77s vs 113s        │ 52s vs 84s         │
  └───────────────────┴────────────────────┴────────────────────┴────────────────────┘

  Key takeaways:

  - Elixir is consistently faster — roughly 1.5-2x
  - Elixir finds significantly more extractions — often 1.5-2x more per document
  - Class agreement is perfect (100%) when extractions match — both libraries agree on entity types
  - Match rates are low (45-62%) largely because Elixir extracts so many more items, inflating the "library-only" count
  - Offset deltas are high — suggests the byte-offset alignment logic differs between the two libraries
  - 3 :invalid_format errors on the Elixir side — root causes identified below

  ## invalid_format errors (Elixir)

  Investigated with `--debug-raw-responses` flag. Three distinct failure modes:

  1. **great-expectations (dialogue)**: LLM produced invalid JSON —
     `"speaker": "a terrible voice" / "a man"` (slash to indicate ambiguity)
  2. **the-yellow-wallpaper (dialogue)**: LLM produced invalid JSON —
     `"speaker": "I" (narrator)` (parenthetical note outside the string)
  3. **the-happy-prince (literary_devices)**: LLM got the title page chunk
     (no literary text) and refused, returning prose instead of JSON

  Python's library uses YAML as its default output format, which is more lenient
  and parses cases 1 and 2 as strings. Case 3 would fail in both libraries but
  Python errors on a different chunk (different chunking boundaries).