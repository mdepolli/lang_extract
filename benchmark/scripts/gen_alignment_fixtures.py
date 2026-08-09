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

A case may carry a fifth element: a config dict using the Elixir aligner's
option names (fuzzy_threshold, min_density, accept_lesser). It is mapped to
the upstream align_extractions kwargs here and frozen into the fixture, so
the Elixir test replays the same non-default configuration.

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

# (name, source, [extraction_texts], note_or_None[, config])
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
    (
        "dp_nested_inside_placement",
        "the quick brown fox jumps",
        ["quick brown fox", "brown"],
        "nested mention only fits inside the DP placement; upstream grounds it",
    ),
    (
        "dp_nested_mention_punctuated",
        "Patient has type 2 diabetes.",
        ["type 2 diabetes", "diabetes"],
        "common LLM shape: entity nested in its container extraction",
    ),
    # --- Non-default configs and adversarial gates: threshold knife-edges,
    #     density boundaries, stemming edges, fuzzy tie-breaks ---
    (
        "threshold_boundary_default_accepts",
        "Patient shows chronic inflammation markers today.",
        ["acute chronic inflammation markers"],
        "3-of-4 coverage sits exactly on the default 0.75 gate",
    ),
    (
        "threshold_high_rejects_same_case",
        "Patient shows chronic inflammation markers today.",
        ["acute chronic inflammation markers"],
        "same case as threshold_boundary_default_accepts; 0.9 needs all 4",
        {"fuzzy_threshold": 0.9},
    ),
    (
        "threshold_low_accepts",
        "Patient shows chronic inflammation markers today.",
        ["acute febrile inflammation markers"],
        "2-of-4 coverage fails default 0.75 but passes 0.5",
        {"fuzzy_threshold": 0.5},
    ),
    (
        "density_default_accepts_sparse",
        "alpha stray beta straw gamma strap delta",
        ["zip alpha beta gamma delta"],
        "4 matches over a 7-token span: density 4/7 clears the 1/3 default",
    ),
    (
        "density_high_rejects_sparse",
        "alpha stray beta straw gamma strap delta",
        ["zip alpha beta gamma delta"],
        "same span as density_default_accepts_sparse; 4/7 fails 0.6",
        {"min_density": 0.6},
    ),
    (
        "density_exactly_one_third",
        "alpha pad pod pud pid beta tail",
        ["alpha beta"],
        "2 matches over a 6-token span: density equals the 1/3 default; "
        "lesser disabled so the fuzzy phase is reached",
        {"accept_lesser": False},
    ),
    (
        "density_below_one_third",
        "alpha pad pod pud pid pex beta tail",
        ["alpha beta"],
        "2 matches over a 7-token span: density just under the 1/3 default",
        {"accept_lesser": False},
    ),
    (
        "lesser_disabled_not_found",
        "The quick brown fox jumps.",
        ["quick brown wolf"],
        "default would MATCH_LESSER on the quick-brown prefix block; with "
        "the gate off, 2-of-3 coverage fails the default threshold",
        {"accept_lesser": False},
    ),
    (
        "lesser_disabled_fuzzy_rescue",
        "The quick brown fox jumps.",
        ["quick brown wolf"],
        "with the threshold lowered too, fuzzy grounds what lesser would have",
        {"accept_lesser": False, "fuzzy_threshold": 0.6},
    ),
    (
        "ceil_artifact_upstream_rejects",
        "siga sigb sigc sigd sige sigf sigg appear in this sentence.",
        [
            "padz siga sigb sigc sigd sige sigf sigg "
            + " ".join(f"pad{c}" for c in "abcdefghijklmnopq")
        ],
        "25*0.28 rounds to 7.000000000000001, so upstream needs "
        "ceil = 8 and rejects the 7-match span; a matches/m ratio "
        "comparison accepts at exactly 0.28",
        {"fuzzy_threshold": 0.28},
    ),
    (
        "ceil_artifact_upstream_accepts",
        "the alpha beta gamma story",
        ["zip beta gamma"],
        "3*0.6666666666666667 rounds to 2.0, so upstream needs 2 of 3; a "
        "matches/m ratio comparison rejects because 2/3 rounds below the "
        "threshold",
        {"fuzzy_threshold": 0.6666666666666667},
    ),
    (
        "stemming_four_char_plural_strips",
        "The lab closed early.",
        ["labs"],
        "4-char plural is just over the >3 stemming length gate",
    ),
    (
        "stemming_double_s_kept",
        "The glass broke.",
        ["glasses"],
        "glasses stems to glasse while glass keeps its ss; no match",
    ),
    (
        "fuzzy_tie_prefers_earliest_span",
        "alpha pad beta pod alpha pud beta",
        ["alpha beta"],
        "two 3-token spans hold both matches; earliest source start wins",
        {"accept_lesser": False},
    ),
    (
        "fuzzy_prefers_tightest_span",
        "alpha pad pod beta pud alpha pex beta",
        ["alpha beta"],
        "a later 3-token span beats the earlier 4-token one",
        {"accept_lesser": False},
    ),
    (
        "repeated_extraction_tokens_lcs",
        "big cat big cat",
        ["big big cat"],
        "duplicate token inside the extraction; LCS reuses occurrences in order",
    ),
]

# Fixture config keys use the Elixir aligner's option names; mapped to the
# upstream align_extractions kwargs here.
UPSTREAM_PARAMS = {
    "fuzzy_threshold": "fuzzy_alignment_threshold",
    "min_density": "fuzzy_alignment_min_density",
    "accept_lesser": "accept_match_lesser",
}

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
    for case in CASES:
        name, source, extraction_texts, note = case[:4]
        config = case[4] if len(case) > 4 else None
        aligner = resolver_lib.WordAligner()
        extractions = [
            Extraction(extraction_class="t", extraction_text=text)
            for text in extraction_texts
        ]
        upstream_kwargs = {
            UPSTREAM_PARAMS[key]: value for key, value in (config or {}).items()
        }
        groups = aligner.align_extractions([extractions], source, **upstream_kwargs)
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

        fixture = {
            "name": name,
            "source": source,
            "extractions": extraction_texts,
            "results": results,
            "note": note,
        }
        if config:
            fixture["config"] = config
        fixtures.append(fixture)
        summary = ", ".join(
            f"{r['status']}[{r['byte_start']},{r['byte_end']}]" for r in results
        )
        print(f"{name}: {summary}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixtures, indent=2, ensure_ascii=False) + "\n")
    print(f"\nWrote {len(fixtures)} fixtures to {OUT}")


if __name__ == "__main__":
    main()
