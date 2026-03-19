#!/usr/bin/env python3
"""Compare benchmark results between Elixir and Python runners."""

import argparse
import json
import sys
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

BENCHMARK_DIR = Path(__file__).resolve().parent.parent
MATCH_THRESHOLD = 0.8


def load_results(results_dir: Path) -> dict[str, list[dict]]:
    """Load all JSONL files from a results directory, keyed by task name."""
    results = {}
    for path in sorted(results_dir.glob("*.jsonl")):
        task_name = path.stem
        entries = []
        for line in path.read_text().strip().split("\n"):
            if line:
                entries.append(json.loads(line))
        results[task_name] = entries
    return results


def match_extractions(
    a_extractions: list[dict], b_extractions: list[dict]
) -> tuple[list[tuple[dict, dict]], list[dict], list[dict]]:
    """Match extractions between two libraries by text similarity."""
    matched = []
    a_used = set()
    b_used = set()

    for ai, a in enumerate(a_extractions):
        best_idx = None
        best_ratio = 0.0

        for bi, b in enumerate(b_extractions):
            if bi in b_used:
                continue
            if a["text"] == b["text"]:
                best_idx = bi
                best_ratio = 1.0
                break
            ratio = SequenceMatcher(None, a["text"], b["text"]).ratio()
            if ratio > best_ratio:
                best_ratio = ratio
                best_idx = bi

        if best_ratio >= MATCH_THRESHOLD and best_idx is not None:
            matched.append((a, b_extractions[best_idx]))
            a_used.add(ai)
            b_used.add(best_idx)

    a_only = [a for i, a in enumerate(a_extractions) if i not in a_used]
    b_only = [b for i, b in enumerate(b_extractions) if i not in b_used]

    return matched, a_only, b_only


def compare_task(elixir_entries: list[dict], python_entries: list[dict], task_name: str) -> dict:
    """Compare results for a single task."""
    elixir_by_source = {e["source"]: e for e in elixir_entries}
    python_by_source = {e["source"]: e for e in python_entries}

    all_sources = sorted(set(elixir_by_source) | set(python_by_source))

    total_elixir = 0
    total_python = 0
    total_matched = 0
    total_elixir_only = 0
    total_python_only = 0
    class_agreements = 0
    class_total = 0
    offset_deltas = []
    status_agreements = 0
    status_total = 0
    elixir_times = []
    python_times = []
    elixir_errors = 0
    python_errors = 0
    per_doc = []

    for source in all_sources:
        e_entry = elixir_by_source.get(source)
        p_entry = python_by_source.get(source)

        if e_entry and "error" in e_entry:
            elixir_errors += 1
            continue
        if p_entry and "error" in p_entry:
            python_errors += 1
            continue
        if not e_entry or not p_entry:
            continue

        e_ext = e_entry["extractions"]
        p_ext = p_entry["extractions"]

        total_elixir += len(e_ext)
        total_python += len(p_ext)

        matched, e_only, p_only = match_extractions(e_ext, p_ext)
        total_matched += len(matched)
        total_elixir_only += len(e_only)
        total_python_only += len(p_only)

        for a, b in matched:
            class_total += 1
            if a["class"] == b["class"]:
                class_agreements += 1

            status_total += 1
            if a["status"] == b["status"]:
                status_agreements += 1

            if a["byte_start"] is not None and b["byte_start"] is not None:
                delta = abs(a["byte_start"] - b["byte_start"])
                offset_deltas.append(delta)

        if e_entry.get("timing"):
            elixir_times.append(e_entry["timing"]["total_ms"])
        if p_entry.get("timing"):
            python_times.append(p_entry["timing"]["total_ms"])

        per_doc.append({
            "source": source,
            "elixir_count": len(e_ext),
            "python_count": len(p_ext),
            "matched": len(matched),
            "elixir_only": len(e_only),
            "python_only": len(p_only),
        })

    summary = {
        "task": task_name,
        "documents": len(all_sources),
        "elixir_errors": elixir_errors,
        "python_errors": python_errors,
        "total_elixir": total_elixir,
        "total_python": total_python,
        "matched": total_matched,
        "elixir_only": total_elixir_only,
        "python_only": total_python_only,
        "class_agreement_pct": round(class_agreements / class_total * 100, 1) if class_total else 0,
        "offset_mean_delta": round(sum(offset_deltas) / len(offset_deltas), 1) if offset_deltas else 0,
        "offset_max_delta": max(offset_deltas) if offset_deltas else 0,
        "status_agreement_pct": round(status_agreements / status_total * 100, 1) if status_total else 0,
        "avg_time_elixir_ms": round(sum(elixir_times) / len(elixir_times)) if elixir_times else 0,
        "avg_time_python_ms": round(sum(python_times) / len(python_times)) if python_times else 0,
        "per_document": per_doc,
    }

    return summary


def print_summary(summary: dict):
    """Print a formatted summary table for a task."""
    s = summary
    match_pct = round(s["matched"] / max(s["total_elixir"], s["total_python"], 1) * 100)

    print(f"\n=== {s['task'].upper()} Task ===")
    print(f"{'':20s} {'Elixir':>10s} {'Python':>10s} {'Agreement':>12s}")
    print(f"{'Documents:':20s} {s['documents']:>10d} {s['documents']:>10d}")
    print(f"{'Errors:':20s} {s['elixir_errors']:>10d} {s['python_errors']:>10d}")
    print(f"{'Total extractions:':20s} {s['total_elixir']:>10d} {s['total_python']:>10d}")
    print(f"{'Matched:':20s} {s['matched']:>10d} {'':>10s} {match_pct:>10d}%")
    print(f"{'Library-only:':20s} {s['elixir_only']:>10d} {s['python_only']:>10d}")
    print(f"{'Class agreement:':20s} {'':>10s} {'':>10s} {s['class_agreement_pct']:>10.1f}%")
    print(f"{'Offset mean delta:':20s} {'':>10s} {'':>10s} {s['offset_mean_delta']:>9.1f}b")
    print(f"{'Offset max delta:':20s} {'':>10s} {'':>10s} {s['offset_max_delta']:>9d}b")
    print(f"{'Status agreement:':20s} {'':>10s} {'':>10s} {s['status_agreement_pct']:>10.1f}%")
    e_time = f"{s['avg_time_elixir_ms'] / 1000:.1f}s" if s['avg_time_elixir_ms'] else "n/a"
    p_time = f"{s['avg_time_python_ms'] / 1000:.1f}s" if s['avg_time_python_ms'] else "n/a"
    print(f"{'Avg time/doc:':20s} {e_time:>10s} {p_time:>10s}")


def get_library_versions() -> dict:
    """Attempt to read library versions for reproducibility."""
    versions = {}
    try:
        import langextract
        versions["langextract"] = getattr(langextract, "__version__", "unknown")
    except ImportError:
        versions["langextract"] = "not installed"

    # Read Elixir version from mix.exs
    mix_path = BENCHMARK_DIR.parent / "mix.exs"
    if mix_path.exists():
        import re
        content = mix_path.read_text()
        match = re.search(r'version:\s*"([^"]+)"', content)
        versions["lang_extract"] = match.group(1) if match else "unknown"
    else:
        versions["lang_extract"] = "unknown"

    return versions


def main():
    parser = argparse.ArgumentParser(description="Compare benchmark results between Elixir and Python")
    parser.add_argument("--elixir", default=str(BENCHMARK_DIR / "results" / "elixir"), help="Elixir results dir")
    parser.add_argument("--python", default=str(BENCHMARK_DIR / "results" / "python"), help="Python results dir")
    args = parser.parse_args()

    elixir_results = load_results(Path(args.elixir))
    python_results = load_results(Path(args.python))

    all_tasks = sorted(set(elixir_results) | set(python_results))

    if not all_tasks:
        print("No results found. Run both benchmark runners first.")
        sys.exit(1)

    summaries = []
    for task_name in all_tasks:
        e_entries = elixir_results.get(task_name, [])
        p_entries = python_results.get(task_name, [])
        summary = compare_task(e_entries, p_entries, task_name)
        summaries.append(summary)
        print_summary(summary)

    # Write detailed report
    report = {
        "metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "model": "claude-sonnet-4-20250514",
            "temperature": 0,
            "match_threshold": MATCH_THRESHOLD,
            "library_versions": get_library_versions(),
        },
        "tasks": summaries,
    }

    report_path = BENCHMARK_DIR / "results" / "report.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)

    print(f"\nDetailed report: {report_path}")


if __name__ == "__main__":
    main()
