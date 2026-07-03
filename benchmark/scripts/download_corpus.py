#!/usr/bin/env python3
"""Download Project Gutenberg texts for benchmarking.

Files are written byte-exact (no newline translation) and pinned by sha256
in corpus.json: Gutenberg occasionally re-edits texts, and a silently
shifted corpus invalidates every stored byte offset. A re-download whose
content no longer matches the pin fails loudly instead of writing.
"""

import hashlib
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


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save_manifest(manifest: list[dict]) -> None:
    lines = ",\n".join("  " + json.dumps(entry) for entry in manifest)
    MANIFEST_PATH.write_text("[\n" + lines + "\n]\n", encoding="utf-8")


def check_existing(entry: dict, out_path: Path) -> bool:
    """Verify or pin an already-downloaded file. Returns manifest_updated."""
    slug = entry["slug"]
    actual = sha256_of(out_path.read_bytes())
    expected = entry.get("sha256")

    if expected is None:
        entry["sha256"] = actual
        print(f"  pin  {slug} (sha256 recorded)")
        return True

    if actual != expected:
        print(
            f"  MISMATCH {slug}: local file differs from manifest sha256 - "
            f"byte offsets are not comparable with pinned results",
            file=sys.stderr,
        )
    else:
        print(f"  ok   {slug}")
    return False


def download(entry: dict, out_path: Path) -> bool:
    """Download, verify against the pin, and write. Returns manifest_updated."""
    slug = entry["slug"]
    expected = entry.get("sha256")

    print(f"  downloading {slug}...", end=" ", flush=True)
    with urlopen(entry["url"]) as resp:
        raw = resp.read().decode("utf-8-sig")

    text = strip_gutenberg_boilerplate(raw)
    if entry.get("max_bytes") is not None:
        text = truncate_at_sentence(text, entry["max_bytes"])

    data = text.encode("utf-8")
    actual = sha256_of(data)

    if expected is not None and actual != expected:
        print(
            f"FAILED: upstream content changed (sha256 {actual[:12]}... != "
            f"pinned {expected[:12]}...); not writing",
            file=sys.stderr,
        )
        return False

    out_path.write_bytes(data)
    print(f"{len(data) / 1024:.1f} KB")

    if expected is None:
        entry["sha256"] = actual
        return True
    return False


def download_corpus():
    """Download all texts from the corpus manifest."""
    CORPUS_DIR.mkdir(parents=True, exist_ok=True)

    with open(MANIFEST_PATH) as f:
        manifest = json.load(f)

    manifest_updated = False

    for entry in manifest:
        out_path = CORPUS_DIR / f"{entry['slug']}.txt"
        try:
            if out_path.exists():
                manifest_updated |= check_existing(entry, out_path)
            else:
                manifest_updated |= download(entry, out_path)
        except Exception as e:
            print(f"FAILED: {e}", file=sys.stderr)

    if manifest_updated:
        save_manifest(manifest)
        print(f"\nManifest updated with sha256 pins: {MANIFEST_PATH}")

    print(f"\nCorpus ready: {CORPUS_DIR}")


if __name__ == "__main__":
    download_corpus()
