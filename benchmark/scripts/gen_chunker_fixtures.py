#!/usr/bin/env python3
"""Generate chunker parity fixtures from upstream langextract's ChunkIterator.

Runs curated (text, max_char_buffer) cases through the upstream chunker and
freezes each chunk's text and byte offsets into
test/fixtures/chunker_parity.json. The Elixir test suite
(chunker_parity_test.exs) asserts LangExtract.Chunker against these
verdicts, so upstream behavior is the executable spec.

Upstream chunks are token intervals: chunk text spans the first token's
start to the last token's end, so leading/trailing whitespace between
chunks belongs to no chunk. Char positions are converted to byte offsets
here (the Elixir side is byte-native).

Regenerate after pulling upstream: benchmark/.venv/bin/python
benchmark/scripts/gen_chunker_fixtures.py
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / "code" / "langextract"))

from langextract import chunking
from langextract.core import tokenizer as tokenizer_lib

REPO = Path(__file__).resolve().parent.parent.parent
OUT = REPO / "test" / "fixtures" / "chunker_parity.json"

DONNE = (
    "No man is an island,\n"
    "Entire of itself,\n"
    "Every man is a piece of the continent,\n"
    "A part of the main."
)

# Dialogue excerpt from the Great Expectations corpus text (hardcoded so
# fixtures don't shift if the corpus is re-downloaded). Smart quotes, an
# Mrs. abbreviation, and hard-wrapped lines — the realistic case behind
# the closing-punctuation divergence this suite exists to prevent.
JOE = (
    "“Mrs. Joe has been out a dozen times, looking for you, Pip. And she’s\n"
    "out now, making it a baker’s dozen.”\n"
    "\n"
    "“Is she?”\n"
    "\n"
    "“Yes, Pip,” said Joe; “and what’s worse, she’s got Tickler with her.”"
)

# (name, text, [max_char_buffer, ...], note_or_None)
CASES = [
    (
        "quote_after_terminator",
        'He left. "Come back," she said.',
        [10, 12, 20, 31, 100],
        "ASCII closing quote consumed across the whitespace gap",
    ),
    (
        "knife_edge_budget",
        "Aaaa bbbbb ccccc ddd. Bbbbb cccc. Cccc ddd.",
        [20, 21, 22, 43],
        "budget measured from first non-whitespace token",
    ),
    (
        "newline_break_in_oversized",
        "aaa bbb ccc\nddd eee fff",
        [11, 15, 23],
        "oversized sentences split at the most recent newline",
    ),
    ("donne_poem", DONNE, [40], "upstream ChunkIterator docstring example A"),
    (
        "oversized_token",
        "This is antidisestablishmentarianism.",
        [20],
        "upstream ChunkIterator docstring example B",
    ),
    (
        "whole_sentences",
        "Roses are red. Violets are blue. Flowers are nice. And so are you.",
        [60],
        "upstream ChunkIterator docstring example C",
    ),
    (
        "fragment_then_sentence",
        "wwwwwwwwww xxxxxxxxxx yyyyyyyyyy. Zz aa.",
        [21],
        "broken-sentence fragments never merge with the next sentence",
    ),
    (
        "sentence_then_fragment",
        "Aa bb. cccccccccc dddddddddd eeee.",
        [21],
        "an oversized sentence starts its own chunk run",
    ),
    ("lone_cr", "First line\rSecond line", [8, 100], "lone \\r counts as a newline"),
    (
        "crlf_lines",
        "First sentence here.\r\nSecond sentence there.\r\nThird one closes it.",
        [25],
        None,
    ),
    (
        "crlf_hard_wrap",
        "Aaaa bbbb cccc dddd\r\neeee ffff gggg hhhh\r\niiii jjjj kkkk llll.",
        [21, 40, 41, 62],
        "budget counts code points: \\r\\n is two, not one grapheme",
    ),
    ("abbreviations", "Dr. Smith is here. He is nice.", [18, 100], None),
    ("abbreviation_run", "Mr. Dr. Smith arrived. Then left.", [22, 100], None),
    (
        "spaced_abbreviation",
        "Dr . Smith arrived.",
        [10, 100],
        "previous *token* (whitespace-blind) feeds the abbreviation check",
    ),
    ("quoted_exclamation", 'She yelled ("stop!") loudly. Done.', [28, 100], None),
    ("smart_quote_dialogue", JOE, [40, 100, 1000], None),
    (
        "multibyte_boundaries",
        "Ahab saw the \U0001f433 breach. Café déjà vu — again. "
        "日本語のテキストです。 "
        "Ça alors, señor Ahab! "
        "The \U0001f433\U0001f433 returned at dawn. Fin de l'histoire.",
        [20, 25, 30, 40, 60],
        None,
    ),
    (
        "oversized_multibyte",
        "\U0001f433\U0001f433\U0001f433 café déjà 日本語 "
        "señor — one very long sentence indeed.",
        [10],
        None,
    ),
    ("decimal_number", "Pi is 3.14. Next sentence.", [12, 100], None),
    ("cjk_terminators", "日本語の文です。次の文です。", [6, 100], None),
    (
        "boundary_free",
        " ".join(f"word{i}" for i in range(1, 61)),
        [50],
        None,
    ),
    ("single_long_token", "x" * 60, [25], None),
    ("leading_trailing_ws", "   Padded sentence.   Second one.   ", [20, 100], None),
    ("whitespace_only", "   \n\t  ", [10], None),
    ("empty", "", [10], None),
    ("no_terminator", "this is a long run on sentence without any punctuation at all", [20], None),
    (
        "exact_budget",
        "Hello. World.",
        [13],
        "chunk length exactly at the buffer is not an overflow",
    ),
]


def byte_offset(text: str, char_pos: int) -> int:
    return len(text[:char_pos].encode("utf-8"))


def chunk_case(text: str, max_char_buffer: int) -> list[dict]:
    tokenizer = tokenizer_lib.RegexTokenizer()
    chunks = []
    for chunk in chunking.ChunkIterator(text, max_char_buffer, tokenizer):
        interval = chunk.char_interval
        chunks.append({
            "text": chunk.chunk_text,
            "byte_start": byte_offset(text, interval.start_pos),
            "byte_end": byte_offset(text, interval.end_pos),
        })
    return chunks


def main() -> None:
    fixtures = []
    for name, text, buffers, note in CASES:
        for buffer in buffers:
            fixtures.append({
                "name": f"{name}_{buffer}",
                "text": text,
                "max_char_buffer": buffer,
                "chunks": chunk_case(text, buffer),
                "note": note,
            })
    OUT.write_text(json.dumps(fixtures, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {len(fixtures)} fixtures to {OUT}")


if __name__ == "__main__":
    main()
