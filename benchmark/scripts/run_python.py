#!/usr/bin/env python3
"""Run langextract (Python) benchmark against corpus texts."""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BENCHMARK_DIR = Path(__file__).resolve().parent.parent

# Add langextract to path if installed locally
sys.path.insert(0, str(Path.home() / "code" / "langextract"))

import requests

import langextract as lx
from langextract.core import base_model, types as core_types
from langextract.core.data import ExampleData, Extraction


ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
RETRYABLE_STATUS = {408, 429, 500, 502, 503, 529}


class ClaudeProvider(base_model.BaseLanguageModel):
    """Minimal Anthropic Claude provider for langextract."""

    MAX_ATTEMPTS = 4

    def __init__(self, api_key: str, model_id: str = "claude-sonnet-5",
                 temperature: float | None = None, max_tokens: int = 8192, **kwargs):
        super().__init__(**kwargs)
        self.api_key = api_key
        self.model_id = model_id
        self.temperature = temperature
        self.max_tokens = max_tokens

    def _request(self, body: dict) -> dict:
        """POST to the Messages API, retrying transient failures with backoff.

        Mirrors the Elixir runner's Req defaults: transient retries on
        429/5xx/timeouts, 120s read timeout, honoring retry-after.
        """
        delay = 1.0
        for attempt in range(1, self.MAX_ATTEMPTS + 1):
            resp = None
            error: Exception | None = None
            try:
                resp = requests.post(
                    ANTHROPIC_URL,
                    headers={
                        "x-api-key": self.api_key,
                        "anthropic-version": "2023-06-01",
                        "content-type": "application/json",
                    },
                    json=body,
                    timeout=(10, 120),
                )
            except (requests.ConnectionError, requests.Timeout) as e:
                error = e
            if resp is not None:
                if resp.status_code not in RETRYABLE_STATUS:
                    resp.raise_for_status()
                    return resp.json()
                error = requests.HTTPError(
                    f"HTTP {resp.status_code} from Anthropic API", response=resp
                )
                retry_after = resp.headers.get("retry-after", "")
                if retry_after.isdigit():
                    delay = max(delay, int(retry_after))
            if attempt == self.MAX_ATTEMPTS:
                raise error
            time.sleep(delay)
            delay *= 2
        raise AssertionError("unreachable")

    def _completion_text(self, data: dict) -> str:
        stop_reason = data.get("stop_reason")
        if stop_reason == "max_tokens":
            raise RuntimeError(
                "response truncated at max_tokens - raise ClaudeProvider max_tokens"
            )
        text = next(
            (b["text"] for b in data.get("content", []) if b.get("type") == "text"),
            None,
        )
        if not text:
            raise RuntimeError(f"no text content in response (stop_reason={stop_reason})")
        return text

    def _complete(self, prompt: str) -> str:
        body = {
            "model": self.model_id,
            "max_tokens": self.max_tokens,
            "messages": [{"role": "user", "content": prompt}],
        }
        if self.temperature is not None:
            body["temperature"] = self.temperature
        return self._completion_text(self._request(body))

    def infer(self, batch_prompts, **kwargs):
        for prompt in batch_prompts:
            yield [core_types.ScoredOutput(score=1.0, output=self._complete(prompt))]


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


def run_document(file: Path, task_def: dict, task_name: str,
                 examples: list[ExampleData], model, run_dir: Path) -> None:
    slug = file.stem
    source_bytes = file.read_bytes()
    source_text = source_bytes.decode("utf-8")
    print(f"  {slug} ({len(source_bytes)} bytes)...", end=" ", flush=True)

    try:
        start = time.perf_counter()
        result = lx.extract(
            text_or_documents=source_text,
            prompt_description=task_def["description"],
            examples=examples,
            model=model,
            format_type=core_types.FormatType.YAML,
            max_char_buffer=1000,
            max_workers=2,
            show_progress=False,
        )
        elapsed_ms = int((time.perf_counter() - start) * 1000)

        extractions = [
            normalize_extraction(e, source_text)
            for e in (result.extractions or [])
        ]
        print(f"{len(extractions)} extractions in {elapsed_ms}ms")

        output = {
            "source": slug,
            "task": task_name,
            "library": "python",
            "extractions": extractions,
            "timing": {"total_ms": elapsed_ms},
        }

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        output = {
            "source": slug,
            "task": task_name,
            "library": "python",
            "extractions": [],
            "timing": None,
            "error": str(e),
        }

    out_path = run_dir / f"{slug}.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2)


def run_benchmark(task_name: str, corpus_dir: Path, out_dir: Path,
                  document: str | None = None):
    task_def = load_task(task_name)
    examples = build_examples(task_def)
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    model = ClaudeProvider(api_key=api_key)

    if document:
        corpus_files = [corpus_dir / f"{document}.txt"]
    else:
        corpus_files = sorted(corpus_dir.glob("*.txt"))

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    run_dir = out_dir / f"{task_name}_{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"Running task '{task_name}' on {len(corpus_files)} documents...")

    for file in corpus_files:
        run_document(file, task_def, task_name, examples, model, run_dir)

    latest_link = out_dir / f"{task_name}_latest"
    if latest_link.is_symlink():
        latest_link.unlink()
    elif latest_link.exists():
        latest_link.unlink()
    latest_link.symlink_to(run_dir.name)

    print(f"\nResults written to {run_dir}/")
    print(f"Symlink updated: {latest_link} -> {run_dir.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run Python langextract benchmark")
    parser.add_argument("--task", required=True, help="Task name (e.g., ner)")
    parser.add_argument("--document", help="Single document slug to run")
    parser.add_argument("--corpus", default=str(BENCHMARK_DIR / "corpus"), help="Corpus directory")
    parser.add_argument("--out", default=str(BENCHMARK_DIR / "results" / "python"), help="Output directory")
    args = parser.parse_args()

    run_benchmark(args.task, Path(args.corpus), Path(args.out), args.document)
