#!/usr/bin/env python3
"""Generate alignment parity fixtures from upstream langextract's WordAligner.

Runs curated (source, extraction) cases through the upstream aligner and
freezes its statuses/spans into test/fixtures/alignment_parity.json. The
Elixir test suite (aligner_parity_test.exs) asserts LangExtract's aligner
against these verdicts, so upstream behavior is the executable spec.

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

# (name, source, extraction_text, note_or_None)
CASES = [
    ("exact_simple", "the quick brown fox", "quick brown", None),
    ("exact_multibyte", "café señor bueno", "señor", None),
    ("exact_case_insensitive", "Hello world", "hello", None),
    ("exact_across_punctuation", "Hello, world!", "Hello", None),
    ("repeated_duplicate", "hello world hello", "hello", None),
    (
        "stitched_dialogue",
        "“You young dog,” said the man, licking his lips, "
        "“what fat cheeks you ha’ got.”",
        "You young dog, what fat cheeks you ha’ got.",
        "real benchmark case: merged interrupted dialogue",
    ),
    (
        "lesser_single_token",
        "Patient reports back pain and a fever.",
        "headache and fever",
        None,
    ),
    ("plural_stemming", "The cheeks were red.", "cheek", None),
    (
        "sparse_density",
        "alpha one two three four five six beta one two three four five six gamma",
        "alpha beta gamma",
        None,
    ),
    (
        "smart_quote_contraction",
        "he said don’t go home",
        "don't go",
        "tokenizers differ on contractions; divergence candidates",
    ),
    (
        "partial_overlap",
        "Findings consistent with degenerative disc disease at L5-S1.",
        "mild degenerative disc disease",
        None,
    ),
    ("reordered_words", "Patient has severe heart problems today.", "problems heart", None),
    (
        "no_shared_tokens",
        "the quick brown fox",
        "completely different words here",
        None,
    ),
    (
        "colon_in_text",
        "He warned: never open the vault after midnight.",
        "never open the vault",
        None,
    ),
]

STATUS_MAP = {
    AlignmentStatus.MATCH_EXACT: "exact",
    AlignmentStatus.MATCH_GREATER: "fuzzy",
    AlignmentStatus.MATCH_LESSER: "fuzzy",
    AlignmentStatus.MATCH_FUZZY: "fuzzy",
    None: "not_found",
}


def char_to_byte(text: str, pos: int | None) -> int | None:
    if pos is None:
        return None
    return len(text[:pos].encode("utf-8"))


def main():
    fixtures = []
    for name, source, extraction_text, note in CASES:
        aligner = resolver_lib.WordAligner()
        extraction = Extraction(extraction_class="t", extraction_text=extraction_text)
        groups = aligner.align_extractions([[extraction]], source)
        aligned = list(groups[0]) if groups and groups[0] else []
        result = aligned[0] if aligned else extraction

        status = STATUS_MAP[result.alignment_status]
        ci = result.char_interval
        fixtures.append({
            "name": name,
            "source": source,
            "extraction": extraction_text,
            "upstream_status": status,
            "upstream_raw_status": (
                result.alignment_status.value if result.alignment_status else None
            ),
            "upstream_byte_start": char_to_byte(source, ci.start_pos if ci else None),
            "upstream_byte_end": char_to_byte(source, ci.end_pos if ci else None),
            "note": note,
        })
        print(f"{name}: {status} "
              f"[{fixtures[-1]['upstream_byte_start']}, {fixtures[-1]['upstream_byte_end']}]")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixtures, indent=2, ensure_ascii=False) + "\n")
    print(f"\nWrote {len(fixtures)} fixtures to {OUT}")


if __name__ == "__main__":
    main()
