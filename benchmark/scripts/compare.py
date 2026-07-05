#!/usr/bin/env python3
"""Compare benchmark results between Elixir and Python runners.

Reads the latest run of each task via the {task}_latest symlinks that both
runners maintain, e.g. results/elixir/dialogue_latest/romeo-and-juliet.json.

Result schema (identical for both libraries — see CLAUDE.md):
  - "errors" is always a list ([] when clean)
  - total document failure: "timing": null + one errors entry with null offsets
  - extraction byte offsets are null for "not_found" status

Offset metrics are restricted to pairs where BOTH sides report "exact":
fuzzy spans are not positionally comparable (Python's match_lesser maps to
"fuzzy" with spans smaller than the extraction; Elixir fuzzy spans are the
best sliding-window, often larger).

Attribute agreement is strict dict equality over matched pairs that carry
attributes. Both libraries pass attributes through verbatim, so for
free-text values (dialogue speakers) this measures model phrasing
stability across runs (~60% is normal); its value is as a tripwire —
a library that mangled attributes would drive it toward zero.
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

BENCHMARK_DIR = Path(__file__).resolve().parent.parent
MATCH_THRESHOLD = 0.8
LATEST_SUFFIX = "_latest"


def load_results(results_dir: Path) -> dict[str, dict[str, dict]]:
    """Return {task: {source: entry}} from the latest run of each task."""
    results = {}
    for link in sorted(results_dir.glob(f"*{LATEST_SUFFIX}")):
        if not link.is_dir():
            continue
        task = link.name[: -len(LATEST_SUFFIX)]
        docs = {}
        for path in sorted(link.glob("*.json")):
            entry = json.loads(path.read_text())
            docs[entry["source"]] = entry
        if docs:
            results[task] = docs
    return results


def is_failure(entry: dict) -> bool:
    return entry.get("timing") is None


def offset_distance(a: dict, b: dict) -> float:
    if a.get("byte_start") is None or b.get("byte_start") is None:
        return float("inf")
    return abs(a["byte_start"] - b["byte_start"])


def match_extractions(
    a_extractions: list[dict], b_extractions: list[dict]
) -> tuple[list[tuple[dict, dict]], list[dict], list[dict]]:
    """Match extractions between two libraries.

    Pass 1 pairs exact-text matches, breaking ties by nearest byte_start so
    repeated identical strings (common in dialogue) pair positionally instead
    of by list order. Pass 2 pairs the remainder greedily by text similarity.
    """
    matched = []
    a_used: set[int] = set()
    b_used: set[int] = set()

    b_by_text: dict[str, list[int]] = {}
    for bi, b in enumerate(b_extractions):
        b_by_text.setdefault(b["text"], []).append(bi)

    for ai, a in enumerate(a_extractions):
        candidates = [bi for bi in b_by_text.get(a["text"], []) if bi not in b_used]
        if not candidates:
            continue
        best = min(candidates, key=lambda bi: offset_distance(a, b_extractions[bi]))
        matched.append((a, b_extractions[best]))
        a_used.add(ai)
        b_used.add(best)

    for ai, a in enumerate(a_extractions):
        if ai in a_used:
            continue
        best_idx = None
        best_ratio = 0.0
        for bi, b in enumerate(b_extractions):
            if bi in b_used:
                continue
            ratio = SequenceMatcher(None, a["text"], b["text"]).ratio()
            if ratio > best_ratio:
                best_ratio = ratio
                best_idx = bi
        if best_idx is not None and best_ratio >= MATCH_THRESHOLD:
            matched.append((a, b_extractions[best_idx]))
            a_used.add(ai)
            b_used.add(best_idx)

    a_only = [a for i, a in enumerate(a_extractions) if i not in a_used]
    b_only = [b for i, b in enumerate(b_extractions) if i not in b_used]

    return matched, a_only, b_only


def status_counts(extractions: list[dict]) -> dict[str, int]:
    counts = {"exact": 0, "fuzzy": 0, "not_found": 0}
    for e in extractions:
        counts[e["status"]] = counts.get(e["status"], 0) + 1
    return counts


def compare_task(
    elixir_docs: dict[str, dict], python_docs: dict[str, dict], task_name: str
) -> dict:
    """Compare the latest results for a single task."""
    all_sources = sorted(set(elixir_docs) | set(python_docs))

    totals = {
        "elixir": 0,
        "python": 0,
        "matched": 0,
        "elixir_only": 0,
        "python_only": 0,
    }
    elixir_statuses = {"exact": 0, "fuzzy": 0, "not_found": 0}
    python_statuses = {"exact": 0, "fuzzy": 0, "not_found": 0}
    class_agreements = class_total = 0
    status_agreements = status_total = 0
    attr_agreements = attr_total = 0
    offset_deltas: list[int] = []
    offset_exact_agreements = 0
    elixir_times: list[int] = []
    python_times: list[int] = []
    usage = {
        "elixir": {"input": 0, "output": 0, "request_ms": [], "docs": 0},
        "python": {"input": 0, "output": 0, "request_ms": [], "docs": 0},
    }
    failures = {"elixir": 0, "python": 0}
    chunk_errors = {"elixir": 0, "python": 0}
    missing = {"elixir": 0, "python": 0}
    per_doc = []

    for source in all_sources:
        e_entry = elixir_docs.get(source)
        p_entry = python_docs.get(source)

        if e_entry is None:
            missing["elixir"] += 1
        elif is_failure(e_entry):
            failures["elixir"] += 1
        if p_entry is None:
            missing["python"] += 1
        elif is_failure(p_entry):
            failures["python"] += 1

        comparable = (
            e_entry is not None
            and p_entry is not None
            and not is_failure(e_entry)
            and not is_failure(p_entry)
        )
        if not comparable:
            continue

        chunk_errors["elixir"] += len(e_entry["errors"])
        chunk_errors["python"] += len(p_entry["errors"])

        e_ext = e_entry["extractions"]
        p_ext = p_entry["extractions"]
        totals["elixir"] += len(e_ext)
        totals["python"] += len(p_ext)
        for status, n in status_counts(e_ext).items():
            elixir_statuses[status] += n
        for status, n in status_counts(p_ext).items():
            python_statuses[status] += n

        matched, e_only, p_only = match_extractions(e_ext, p_ext)
        totals["matched"] += len(matched)
        totals["elixir_only"] += len(e_only)
        totals["python_only"] += len(p_only)

        for a, b in matched:
            class_total += 1
            if a["class"] == b["class"]:
                class_agreements += 1

            status_total += 1
            if a["status"] == b["status"]:
                status_agreements += 1

            # Only pairs where either side carries attributes count, so
            # attribute-free tasks report n=0 instead of a vacuous 100%.
            a_attrs = a.get("attributes") or {}
            b_attrs = b.get("attributes") or {}
            if a_attrs or b_attrs:
                attr_total += 1
                if a_attrs == b_attrs:
                    attr_agreements += 1

            both_exact = a["status"] == "exact" and b["status"] == "exact"
            if both_exact and a["byte_start"] is not None and b["byte_start"] is not None:
                delta = abs(a["byte_start"] - b["byte_start"])
                offset_deltas.append(delta)
                if delta == 0:
                    offset_exact_agreements += 1

        elixir_times.append(e_entry["timing"]["total_ms"])
        python_times.append(p_entry["timing"]["total_ms"])

        # Usage blocks exist only in post-Phase-0 runs; older results skip.
        for side, entry in (("elixir", e_entry), ("python", p_entry)):
            doc_usage = entry.get("usage")
            if doc_usage:
                usage[side]["input"] += doc_usage.get("input_tokens") or 0
                usage[side]["output"] += doc_usage.get("output_tokens") or 0
                usage[side]["request_ms"] += [
                    r["ms"] for r in doc_usage.get("requests", []) if r.get("ms") is not None
                ]
                usage[side]["docs"] += 1

        per_doc.append({
            "source": source,
            "elixir_count": len(e_ext),
            "python_count": len(p_ext),
            "matched": len(matched),
            "elixir_only": len(e_only),
            "python_only": len(p_only),
        })

    def pct(n: int, d: int) -> float:
        return round(n / d * 100, 1) if d else 0.0

    return {
        "task": task_name,
        "documents": len(all_sources),
        "compared_documents": len(per_doc),
        "missing": missing,
        "failures": failures,
        "chunk_errors": chunk_errors,
        "total_elixir": totals["elixir"],
        "total_python": totals["python"],
        "elixir_statuses": elixir_statuses,
        "python_statuses": python_statuses,
        "matched": totals["matched"],
        "elixir_only": totals["elixir_only"],
        "python_only": totals["python_only"],
        "class_agreement_pct": pct(class_agreements, class_total),
        "status_agreement_pct": pct(status_agreements, status_total),
        "attribute_agreement_pct": pct(attr_agreements, attr_total),
        "attributed_pairs": attr_total,
        "offset_pairs_compared": len(offset_deltas),
        "offset_identical_pct": pct(offset_exact_agreements, len(offset_deltas)),
        "offset_mean_delta": round(sum(offset_deltas) / len(offset_deltas), 1)
        if offset_deltas
        else 0,
        "offset_max_delta": max(offset_deltas) if offset_deltas else 0,
        "avg_time_elixir_ms": round(sum(elixir_times) / len(elixir_times))
        if elixir_times
        else 0,
        "avg_time_python_ms": round(sum(python_times) / len(python_times))
        if python_times
        else 0,
        "usage": {
            side: usage_summary(usage[side], total_ms)
            for side, total_ms in (
                ("elixir", sum(elixir_times)),
                ("python", sum(python_times)),
            )
        },
        "per_document": per_doc,
    }


def usage_summary(side_usage: dict, total_wall_ms: int) -> dict | None:
    """Aggregate one library's usage; None when no result carried usage."""
    if side_usage["docs"] == 0:
        return None
    request_ms = side_usage["request_ms"]
    return {
        "documents_with_usage": side_usage["docs"],
        "input_tokens": side_usage["input"],
        "output_tokens": side_usage["output"],
        "output_tokens_per_sec": round(side_usage["output"] * 1000 / total_wall_ms, 1)
        if total_wall_ms
        else None,
        "request_count": len(request_ms),
        "mean_request_ms": round(sum(request_ms) / len(request_ms)) if request_ms else None,
    }


def print_summary(s: dict):
    """Print a formatted summary table for a task."""
    match_pct = round(s["matched"] / max(s["total_elixir"], s["total_python"], 1) * 100)

    def statuses(d: dict) -> str:
        return f"{d['exact']}e/{d['fuzzy']}f/{d['not_found']}n"

    print(f"\n=== {s['task'].upper()} Task ===")
    print(f"{'':22s} {'Elixir':>12s} {'Python':>12s} {'Agreement':>12s}")
    print(f"{'Documents compared:':22s} {s['compared_documents']:>12d} {s['compared_documents']:>12d}")
    print(f"{'Failed documents:':22s} {s['failures']['elixir']:>12d} {s['failures']['python']:>12d}")
    print(f"{'Chunk errors:':22s} {s['chunk_errors']['elixir']:>12d} {s['chunk_errors']['python']:>12d}")
    print(f"{'Total extractions:':22s} {s['total_elixir']:>12d} {s['total_python']:>12d}")
    print(f"{'By status (e/f/n):':22s} {statuses(s['elixir_statuses']):>12s} {statuses(s['python_statuses']):>12s}")
    print(f"{'Matched:':22s} {s['matched']:>12d} {'':>12s} {match_pct:>10d}%")
    print(f"{'Library-only:':22s} {s['elixir_only']:>12d} {s['python_only']:>12d}")
    print(f"{'Class agreement:':22s} {'':>12s} {'':>12s} {s['class_agreement_pct']:>10.1f}%")
    print(f"{'Status agreement:':22s} {'':>12s} {'':>12s} {s['status_agreement_pct']:>10.1f}%")
    if s["attributed_pairs"]:
        print(f"{'Attribute agreement:':22s} {'':>12s} {'':>12s} {s['attribute_agreement_pct']:>10.1f}%  ({s['attributed_pairs']} attributed pairs)")
    print(f"{'Offsets identical:':22s} {'':>12s} {'':>12s} {s['offset_identical_pct']:>10.1f}%  ({s['offset_pairs_compared']} exact pairs)")
    print(f"{'Offset mean delta:':22s} {'':>12s} {'':>12s} {s['offset_mean_delta']:>9.1f}b")
    print(f"{'Offset max delta:':22s} {'':>12s} {'':>12s} {s['offset_max_delta']:>9d}b")
    e_time = f"{s['avg_time_elixir_ms'] / 1000:.1f}s" if s["avg_time_elixir_ms"] else "n/a"
    p_time = f"{s['avg_time_python_ms'] / 1000:.1f}s" if s["avg_time_python_ms"] else "n/a"
    print(f"{'Avg time/doc:':22s} {e_time:>12s} {p_time:>12s}")

    e_usage, p_usage = s["usage"]["elixir"], s["usage"]["python"]
    if e_usage or p_usage:
        def cell(u, key, fmt="{:,}"):
            return fmt.format(u[key]) if u and u[key] is not None else "n/a"

        print(f"{'Input tokens:':22s} {cell(e_usage, 'input_tokens'):>12s} {cell(p_usage, 'input_tokens'):>12s}")
        print(f"{'Output tokens:':22s} {cell(e_usage, 'output_tokens'):>12s} {cell(p_usage, 'output_tokens'):>12s}")
        print(f"{'Output tokens/sec:':22s} {cell(e_usage, 'output_tokens_per_sec', '{}'):>12s} {cell(p_usage, 'output_tokens_per_sec', '{}'):>12s}")
        print(f"{'Mean request:':22s} {cell(e_usage, 'mean_request_ms'):>11s}ms {cell(p_usage, 'mean_request_ms'):>11s}ms")


def first_meta(results: dict[str, dict[str, dict]]) -> dict:
    """Provenance stamp from the first result entry that carries one."""
    for docs in results.values():
        for entry in docs.values():
            if entry.get("meta"):
                return entry["meta"]
    return {}


def main():
    parser = argparse.ArgumentParser(
        description="Compare benchmark results between Elixir and Python"
    )
    parser.add_argument(
        "--elixir",
        default=str(BENCHMARK_DIR / "results" / "elixir"),
        help="Elixir results dir",
    )
    parser.add_argument(
        "--python",
        default=str(BENCHMARK_DIR / "results" / "python"),
        help="Python results dir",
    )
    args = parser.parse_args()

    elixir_results = load_results(Path(args.elixir))
    python_results = load_results(Path(args.python))

    all_tasks = sorted(set(elixir_results) | set(python_results))

    if not all_tasks:
        print(
            "No results found. Run both benchmark runners first; this script "
            "reads the {task}_latest symlinks in each results directory."
        )
        sys.exit(1)

    summaries = []
    for task_name in all_tasks:
        e_docs = elixir_results.get(task_name, {})
        p_docs = python_results.get(task_name, {})
        summary = compare_task(e_docs, p_docs, task_name)
        summaries.append(summary)
        print_summary(summary)

    report = {
        "metadata": {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "match_threshold": MATCH_THRESHOLD,
            "elixir": first_meta(elixir_results),
            "python": first_meta(python_results),
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
