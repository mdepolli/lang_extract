#!/usr/bin/env python3
"""Download Project Gutenberg texts for benchmarking."""

import json
import re
import sys
from pathlib import Path
from urllib.request import urlopen

BENCHMARK_DIR = Path(__file__).resolve().parent.parent
CORPUS_DIR = BENCHMARK_DIR / "corpus"
MANIFEST_PATH = BENCHMARK_DIR / "corpus.json"


def strip_gutenberg_boilerplate(text: str) -> str:
    """Remove Project Gutenberg header and footer."""
    start_markers = [
        r"\*\*\* START OF THE PROJECT GUTENBERG EBOOK .+? \*\*\*",
        r"\*\*\* START OF THIS PROJECT GUTENBERG EBOOK .+? \*\*\*",
    ]
    end_markers = [
        r"\*\*\* END OF THE PROJECT GUTENBERG EBOOK .+? \*\*\*",
        r"\*\*\* END OF THIS PROJECT GUTENBERG EBOOK .+? \*\*\*",
    ]

    for pattern in start_markers:
        match = re.search(pattern, text)
        if match:
            text = text[match.end():]
            break

    for pattern in end_markers:
        match = re.search(pattern, text)
        if match:
            text = text[:match.start()]
            break

    return text.strip()


def truncate_at_sentence(text: str, max_bytes: int) -> str:
    """Truncate at the last sentence boundary before max_bytes."""
    encoded = text.encode("utf-8")
    if len(encoded) <= max_bytes:
        return text

    truncated = encoded[:max_bytes].decode("utf-8", errors="ignore")
    # Find last sentence-ending punctuation
    for i in range(len(truncated) - 1, -1, -1):
        if truncated[i] in ".!?" and (i + 1 >= len(truncated) or truncated[i + 1] in ' \n\r"\''):
            return truncated[: i + 1]

    # Fallback: truncate at last space
    last_space = truncated.rfind(" ")
    if last_space > 0:
        return truncated[:last_space]
    return truncated


def download_corpus():
    """Download all texts from the corpus manifest."""
    CORPUS_DIR.mkdir(parents=True, exist_ok=True)

    with open(MANIFEST_PATH) as f:
        manifest = json.load(f)

    for entry in manifest:
        slug = entry["slug"]
        url = entry["url"]
        max_bytes = entry.get("max_bytes")
        out_path = CORPUS_DIR / f"{slug}.txt"

        if out_path.exists():
            print(f"  skip {slug} (already exists)")
            continue

        print(f"  downloading {slug}...", end=" ", flush=True)
        try:
            with urlopen(url) as resp:
                raw = resp.read().decode("utf-8-sig")

            text = strip_gutenberg_boilerplate(raw)

            if max_bytes is not None:
                text = truncate_at_sentence(text, max_bytes)

            out_path.write_text(text, encoding="utf-8")
            size_kb = len(text.encode("utf-8")) / 1024
            print(f"{size_kb:.1f} KB")
        except Exception as e:
            print(f"FAILED: {e}", file=sys.stderr)

    print(f"\nCorpus ready: {CORPUS_DIR}")


if __name__ == "__main__":
    download_corpus()
