#!/usr/bin/env python3
"""Run langextract (Python) benchmark against corpus texts."""

import argparse
import json
import os
import sys
import time
from pathlib import Path

BENCHMARK_DIR = Path(__file__).resolve().parent.parent

# Add langextract to path if installed locally
sys.path.insert(0, str(Path.home() / "code" / "langextract"))

import requests

import langextract as lx
from langextract.core import base_model, types as core_types
from langextract.core.data import ExampleData, Extraction


class ClaudeProvider(base_model.BaseLanguageModel):
    """Minimal Anthropic Claude provider for langextract."""

    def __init__(self, api_key: str, model_id: str = "claude-sonnet-4-20250514",
                 temperature: float = 0, max_tokens: int = 4096, **kwargs):
        super().__init__(**kwargs)
        self.api_key = api_key
        self.model_id = model_id
        self.temperature = temperature
        self.max_tokens = max_tokens

    def infer(self, batch_prompts, **kwargs):
        for prompt in batch_prompts:
            resp = requests.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": self.api_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": self.model_id,
                    "max_tokens": self.max_tokens,
                    "temperature": self.temperature,
                    "messages": [{"role": "user", "content": prompt}],
                },
                timeout=120,
            )
            resp.raise_for_status()
            data = resp.json()
            text = next(
                (b["text"] for b in data.get("content", []) if b.get("type") == "text"),
                "",
            )
            yield [core_types.ScoredOutput(score=1.0, output=text)]


STATUS_MAP = {
    "match_exact": "exact",
    "match_greater": "fuzzy",
    "match_lesser": "fuzzy",
    "match_fuzzy": "fuzzy",
}


def load_task(task_name: str) -> dict:
    path = BENCHMARK_DIR / "tasks" / f"{task_name}.json"
    with open(path) as f:
        return json.load(f)


def build_examples(task_def: dict) -> list[ExampleData]:
    examples = []
    for ex in task_def["examples"]:
        extractions = [
            Extraction(
                extraction_class=e["class"],
                extraction_text=e["text"],
                attributes=e.get("attributes", {}),
            )
            for e in ex["extractions"]
        ]
        examples.append(ExampleData(text=ex["text"], extractions=extractions))
    return examples


def normalize_status(alignment_status) -> str:
    if alignment_status is None:
        return "not_found"
    return STATUS_MAP.get(alignment_status.value, "not_found")


def char_to_byte_offset(text: str, char_pos: int | None) -> int | None:
    if char_pos is None:
        return None
    return len(text[:char_pos].encode("utf-8"))


def normalize_extraction(extraction, source_text: str) -> dict:
    char_interval = extraction.char_interval
    byte_start = char_to_byte_offset(source_text, char_interval.start_pos if char_interval else None)
    byte_end = char_to_byte_offset(source_text, char_interval.end_pos if char_interval else None)

    return {
        "class": extraction.extraction_class,
        "text": extraction.extraction_text,
        "byte_start": byte_start,
        "byte_end": byte_end,
        "status": normalize_status(extraction.alignment_status),
        "attributes": extraction.attributes or {},
    }


def run_benchmark(task_name: str, corpus_dir: Path, out_dir: Path):
    task_def = load_task(task_name)
    examples = build_examples(task_def)
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    model = ClaudeProvider(api_key=api_key, temperature=0)

    corpus_files = sorted(corpus_dir.glob("*.txt"))
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{task_name}.jsonl"

    print(f"Running task '{task_name}' on {len(corpus_files)} documents...")

    lines = []
    for file in corpus_files:
        slug = file.stem
        source_text = file.read_text(encoding="utf-8")
        print(f"  {slug} ({len(source_text.encode('utf-8'))} bytes)...", end=" ", flush=True)

        try:
            start = time.perf_counter()
            result = lx.extract(
                text_or_documents=source_text,
                prompt_description=task_def["description"],
                examples=examples,
                model=model,
                max_workers=1,
                show_progress=False,
            )
            elapsed_ms = int((time.perf_counter() - start) * 1000)

            extractions = [
                normalize_extraction(e, source_text)
                for e in (result.extractions or [])
            ]
            print(f"{len(extractions)} extractions in {elapsed_ms}ms")

            lines.append(json.dumps({
                "source": slug,
                "task": task_name,
                "library": "python",
                "extractions": extractions,
                "timing": {"total_ms": elapsed_ms},
            }))

        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)
            lines.append(json.dumps({
                "source": slug,
                "task": task_name,
                "library": "python",
                "extractions": [],
                "timing": None,
                "error": str(e),
            }))

    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nResults written to {out_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run Python langextract benchmark")
    parser.add_argument("--task", required=True, help="Task name (e.g., ner)")
    parser.add_argument("--corpus", default=str(BENCHMARK_DIR / "corpus"), help="Corpus directory")
    parser.add_argument("--out", default=str(BENCHMARK_DIR / "results" / "python"), help="Output directory")
    args = parser.parse_args()

    run_benchmark(args.task, Path(args.corpus), Path(args.out))
