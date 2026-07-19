#!/usr/bin/env python3
"""Generate alignment parity fixtures from upstream langextract's WordAligner.

Runs curated (source, extractions) cases through the upstream aligner and
freezes its statuses/spans into test/fixtures/alignment_parity.json. The
Elixir test suite (aligner_parity_test.exs) asserts LangExtract's aligner
against these verdicts, so upstream behavior is the executable spec.

Each case aligns a LIST of extractions in one call, mirroring per-chunk
alignment in production. Order matters: the monotonic occurrence DP (#485)
assigns repeated mentions to successive occurrences based on model output
order.

Regenerate after pulling upstream: benchmark/.venv/bin/python
benchmark/scripts/gen_alignment_fixtures.py
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / "code" / "langextract"))

from langextract import resolver as resolver_lib
from langextract.data import AlignmentStatus, Extraction

REPO = Path(__file__).resolve().parent.parent.parent
OUT = REPO / "test" / "fixtures" / "alignment_parity.json"

# (name, source, [extraction_texts], note_or_None)
CASES = [
    ("exact_simple", "the quick brown fox", ["quick brown"], None),
    ("exact_multibyte", "café señor bueno", ["señor"], None),
    ("exact_case_insensitive", "Hello world", ["hello"], None),
    ("exact_across_punctuation", "Hello, world!", ["Hello"], None),
    ("repeated_duplicate", "hello world hello", ["hello"], None),
    (
        "stitched_dialogue",
        "“You young dog,” said the man, licking his lips, "
        "“what fat cheeks you ha’ got.”",
        ["You young dog, what fat cheeks you ha’ got."],
        "real benchmark case: merged interrupted dialogue",
    ),
    (
        "lesser_single_token",
        "Patient reports back pain and a fever.",
        ["headache and fever"],
        None,
    ),
    ("plural_stemming", "The cheeks were red.", ["cheek"], None),
    (
        "sparse_density",
        "alpha one two three four five six beta one two three four five six gamma",
        ["alpha beta gamma"],
        None,
    ),
    (
        "smart_quote_contraction",
        "he said don’t go home",
        ["don't go"],
        "tokenizers differ on contractions; divergence candidates",
    ),
    (
        "partial_overlap",
        "Findings consistent with degenerative disc disease at L5-S1.",
        ["mild degenerative disc disease"],
        None,
    ),
    ("reordered_words", "Patient has severe heart problems today.", ["problems heart"], None),
    (
        "no_shared_tokens",
        "the quick brown fox",
        ["completely different words here"],
        None,
    ),
    (
        "colon_in_text",
        "He warned: never open the vault after midnight.",
        ["never open the vault"],
        None,
    ),
    # --- Occurrence DP cases (#485): repeated mentions, output order ---
    (
        "dp_two_identical",
        "hello world again hello world",
        ["hello world", "hello world"],
        "repeats map to successive occurrences",
    ),
    (
        "dp_three_mentions_two_extracted",
        "Ahab spoke. Then Ahab paused. Finally Ahab left.",
        ["Ahab", "Ahab"],
        None,
    ),
    (
        "dp_repeat_with_unique_between",
        "Ahab called Starbuck. Later Ahab smiled.",
        ["Ahab", "Starbuck", "Ahab"],
        None,
    ),
    (
        "dp_second_occurrence_after_unique",
        "spam eggs spam",
        ["eggs", "spam"],
        "chain through the unique mention forces the later occurrence",
    ),
    (
        "dp_out_of_order_emission",
        "Alice met Bob at noon.",
        ["Bob", "Alice"],
        "monotonic chain drops one; legacy phases recover it",
    ),
    (
        "dp_contested_overlap",
        "big cat sat big cat",
        ["big cat", "cat sat"],
        "DP chain vs legacy phase may produce overlapping spans",
    ),
    (
        "dp_multibyte_repeats",
        "café bar opened. café bar closed.",
        ["café bar", "café bar"],
        None,
    ),
    (
        "dp_paraphrase_among_repeats",
        "Queequeg smiled. Queequeg nodded.",
        ["Queequeg", "Queequeg", "Queequeg vanished"],
        "third extraction has no exact occurrence; falls to legacy phases",
    ),
]

STATUS_MAP = {
    AlignmentStatus.MATCH_EXACT: "exact",
    # MATCH_GREATER is defined upstream but never assigned; mapped defensively.
    AlignmentStatus.MATCH_GREATER: "fuzzy",
    AlignmentStatus.MATCH_LESSER: "lesser",
    AlignmentStatus.MATCH_FUZZY: "fuzzy",
    None: "not_found",
}


def char_to_byte(text: str, pos: int | None) -> int | None:
    if pos is None:
        return None
    return len(text[:pos].encode("utf-8"))


def main():
    fixtures = []
    for name, source, extraction_texts, note in CASES:
        aligner = resolver_lib.WordAligner()
        extractions = [
            Extraction(extraction_class="t", extraction_text=text)
            for text in extraction_texts
        ]
        groups = aligner.align_extractions([extractions], source)
        aligned = list(groups[0]) if groups and groups[0] else []

        # align_extractions may reorder; report results in input order.
        # Identical texts compare equal, so match by identity.
        by_id = {id(e): e for e in aligned}
        results = []
        for extraction in extractions:
            result = by_id.get(id(extraction), extraction)
            ci = result.char_interval
            results.append({
                "status": STATUS_MAP[result.alignment_status],
                "raw_status": (
                    result.alignment_status.value if result.alignment_status else None
                ),
                "byte_start": char_to_byte(source, ci.start_pos if ci else None),
                "byte_end": char_to_byte(source, ci.end_pos if ci else None),
            })

        fixtures.append({
            "name": name,
            "source": source,
            "extractions": extraction_texts,
            "results": results,
            "note": note,
        })
        summary = ", ".join(
            f"{r['status']}[{r['byte_start']},{r['byte_end']}]" for r in results
        )
        print(f"{name}: {summary}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixtures, indent=2, ensure_ascii=False) + "\n")
    print(f"\nWrote {len(fixtures)} fixtures to {OUT}")


if __name__ == "__main__":
    main()
