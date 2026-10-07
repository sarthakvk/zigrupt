"""Generate auditable tables and an SVG directly from raw independent runs."""
from __future__ import annotations

from collections import Counter, defaultdict
import csv
import html
import json
from pathlib import Path
import statistics
import sys
from typing import Any

from run import IMPLEMENTATIONS, workloads


def stats(values: list[float]) -> dict[str, float | int]:
    return {"n": len(values), "median": statistics.median(values), "min": min(values),
            "max": max(values), "cv": statistics.stdev(values) / statistics.mean(values) if len(values) > 1 and statistics.mean(values) else 0}


def compare(a: list[float], b: list[float], higher_better: bool) -> dict[str, Any]:
    if len(a) < 3 or len(b) < 3:
        return {"verdict": "inconclusive", "ratio": None}
    above, below = min(a) > max(b), max(a) < min(b)
    verdict = "win" if (above if higher_better else below) else "loss" if (below if higher_better else above) else "inconclusive"
    return {"verdict": verdict, "ratio": statistics.median(a) / statistics.median(b)}


def quality(runs: list[dict[str, Any]], repeats: int, smoke: bool) -> bool:
    return not smoke and len(runs) == repeats and all(
        r["valid"] and r["elapsed_ns"] >= 500_000_000 and r.get("warm_elapsed_ns", 0) >= 500_000_000
        and r.get("jit_ms", 0) == 0 for r in runs)


def format_stat(s: dict[str, Any], scale: float = 1) -> str:
    return f"{s['median'] / scale:.3f} [{s['min'] / scale:.3f}–{s['max'] / scale:.3f}]"


def svg(output: Path, groups: dict[tuple[str, str, str, float | None], list[dict[str, Any]]]) -> None:
    rows = [(w.key, impl, groups[w.key, impl, "throughput", None]) for w in workloads()
            for impl in w.implementations if groups.get((w.key, impl, "throughput", None))]
    if not rows:
        return
    maximum = max(max(r["events_per_second"] for r in runs) for _, _, runs in rows)
    colors = dict(zip(IMPLEMENTATIONS, ("#0072b2", "#d55e00", "#009e73", "#cc79a7")))
    height = 70 + 25 * len(rows)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="{height}" viewBox="0 0 1000 {height}">',
             '<rect width="100%" height="100%" fill="white"/>',
             '<g font-family="sans-serif" font-size="12" fill="#222">',
             '<text x="20" y="25">Unique events/s: median bars, min–max whiskers (not best runs)</text>']
    for i, (key, impl, runs) in enumerate(rows):
        s = stats([r["events_per_second"] for r in runs])
        y = 50 + i * 25
        x = lambda v: 295 + v / maximum * 550
        parts += [f'<text x="10" y="{y + 12}">{html.escape(key)} {impl}</text>',
                  f'<rect x="295" y="{y}" width="{x(s["median"]) - 295:.2f}" height="16" fill="{colors[impl]}"/>',
                  f'<path d="M{x(s["min"]):.2f},{y + 8} H{x(s["max"]):.2f}" stroke="black"/>',
                  f'<text x="860" y="{y + 12}">{s["median"] / 1e6:.2f} M/s</text>']
    parts.append('</g></svg>')
    (output / "throughput.svg").write_text("\n".join(parts) + "\n")


def report(output: Path) -> None:
    manifest = json.loads((output / "manifest.json").read_text())
    records = [json.loads(line) for line in (output / "runs.jsonl").read_text().splitlines()]
    settings = manifest["settings"]
    repeats, smoke = settings["repeats"], settings["smoke"]
    groups: dict[tuple[str, str, str, float | None], list[dict[str, Any]]] = defaultdict(list)
    all_groups: dict[tuple[str, str, str, float | None], list[dict[str, Any]]] = defaultdict(list)
    summaries: list[dict[str, Any]] = []
    for r in records:
        if r["mode"] not in ("throughput", "latency"):
            continue
        key = (r["workload"], r["implementation"], r["mode"], r["fraction"])
        all_groups[key].append(r)
        if r["valid"]:
            groups[key].append(r)
    for (workload, impl, mode, fraction), runs in sorted(groups.items(), key=str):
        row: dict[str, Any] = {"workload": workload, "implementation": impl, "mode": mode, "fraction": fraction,
                               "rankable": quality(all_groups[workload, impl, mode, fraction], repeats, smoke)}
        fields = ("events_per_second", "deliveries_per_second", "cpu_cores", "peak_rss_bytes", "elapsed_ns", "warm_elapsed_ns",
                  "steady_allocations", "steady_allocated_bytes", "gc_count", "gc_ms", "jit_ms",
                  "ring_requested_bytes", "allocator_live_bytes", "heap_used_bytes", "measurement_bytes")
        for field in fields:
            if all(field in r for r in runs):
                row[field] = stats([r[field] for r in runs])
        if mode == "latency":
            row["offered_rate"] = runs[0]["offered_rate"]
            row["consumers"] = [{name: stats([r["consumers"][cid][name] for r in runs])
                                  for name in ("p50_ns", "p99_ns", "p999_ns")}
                                 for cid in range(len(runs[0]["consumers"]))]
            row["worst"] = {name: stats([max(c[name] for c in r["consumers"]) for r in runs])
                            for name in ("p50_ns", "p99_ns", "p999_ns")}
        summaries.append(row)
    comparisons: list[dict[str, Any]] = []
    for w in workloads():
        for impl in w.implementations[1:]:
            comparison: dict[str, Any] = {"workload": w.key, "competitor": impl}
            for mode, fraction, metrics in (("throughput", None, ("events_per_second",)),
                                             ("latency", 0.5, ("p50_ns", "p99_ns", "p999_ns")),
                                             ("latency", 0.9, ("p50_ns", "p99_ns", "p999_ns"))):
                a = all_groups[w.key, "zigrupt", mode, fraction]
                b = all_groups[w.key, impl, mode, fraction]
                rankable = quality(a, repeats, smoke) and quality(b, repeats, smoke)
                for metric in metrics:
                    name = "throughput" if mode == "throughput" else f"{metric}@{fraction}"
                    if a and b and all(r["valid"] for r in a + b):
                        values = lambda rows: [r[metric] if mode == "throughput" else max(c[metric] for c in r["consumers"]) for r in rows]
                        result = compare(values(a), values(b), mode == "throughput")
                        if not rankable:
                            result["verdict"] = "inconclusive"
                            result["reason"] = "smoke, short run, JIT activity, or incomplete repeats"
                    else:
                        result = {"verdict": "inconclusive", "ratio": None, "reason": "blocked, missing, or invalid runs"}
                    comparison[name] = result
            verdicts = {comparison[name]["verdict"] for name in comparison if isinstance(comparison[name], dict)}
            comparison["tradeoff"] = "win" in verdicts and "loss" in verdicts
            comparisons.append(comparison)
    (output / "summary.json").write_text(json.dumps({"measurements": summaries, "comparisons": comparisons}, indent=2) + "\n")
    with (output / "summary.csv").open("w", newline="") as file:
        fields = ["workload", "implementation", "mode", "fraction", "rankable", "metric", "consumer", "n", "median", "min", "max", "cv"]
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for row in summaries:
            base = {field: row[field] for field in fields[:5]}
            for name, value in row.items():
                if isinstance(value, dict) and "median" in value:
                    writer.writerow({**base, "metric": name, "consumer": "all", **value})
            for cid, consumer in enumerate(row.get("consumers", [])):
                for name, value in consumer.items():
                    writer.writerow({**base, "metric": name, "consumer": cid, **value})
    passed = sum(r["mode"] == "check" and r["valid"] for r in records)
    failed = [r for r in records if r["mode"] != "blocked" and not r["valid"]]
    blocked = [r for r in records if r["mode"] == "blocked"]
    lines = ["# Zigrupt competitive baseline", "",
             f"Run: {manifest['started']}. {'**SMOKE TEST — not ranked.**' if smoke else 'Host-local baseline; not a universal ranking.'}", "",
             f"- Physical CPUs: `{manifest['physical_cpus']}`; one worker per physical core, fixed producer-then-consumer placement.",
             f"- {passed} correctness cases passed; {len(failed)} invalid runs; {len(blocked)} implementation/workload combinations blocked.",
             f"- {repeats} independent processes per measured cell, seeded randomized order. Target measurement {settings['seconds']} s; warmup {settings['warm_seconds']} s (event counts calibrated, actual durations in JSON).",
             "- Results are **median [minimum–maximum]**. Wins/losses require disjoint observed ranges and complete, valid repeats; overlapping ranges are inconclusive. This is not a confidence interval or a significance test.",
             "- Runs shorter than 0.5 s, with warmup shorter than 0.5 s, or with measured JVM compilation activity cannot support wins/losses. Invalid runs are never ranked.",
             "- Ratios are **Zigrupt / competitor**: throughput >1 favors Zigrupt; latency <1 favors Zigrupt. Latency comparisons use the worst consumer per run.",
             "- CPU is process CPU seconds / measured wall seconds; RSS is the executable's address-space high-water RSS (`VmHWM`) before teardown, excluding launcher memory before exec. Startup is excluded from throughput/CPU, not RSS. JVM heap is fixed and pre-touched at 256 MiB.",
             "- No production code or competitor implementation was changed. See `../../SPEC.md` for payload, validation, schedule, native batching and producer-backoff details.", "",
             "## Coverage", "", "| Workload | Status |", "|---|---|"]
    for w in workloads():
        reasons = sorted({r["reason"] for r in blocked if r["workload"] == w.key})
        lines.append(f"| {w.key} | {'; '.join(reasons) if reasons else 'Measured (see quality and variability below)'} |")
    lines += ["", "## Throughput and resource costs", "", "![Throughput](throughput.svg)", "",
              "| Workload | Implementation | M unique events/s | M deliveries/s | CPU cores | Peak RSS MiB | Quality |",
              "|---|---|---:|---:|---:|---:|---|"]
    for row in summaries:
        if row["mode"] != "throughput":
            continue
        lines.append(f"| {row['workload']} | {row['implementation']} | {format_stat(row['events_per_second'], 1e6)} | {format_stat(row['deliveries_per_second'], 1e6)} | {format_stat(row['cpu_cores'])} | {format_stat(row['peak_rss_bytes'], 2**20)} | {'rankable' if row['rankable'] else 'inconclusive'} |")
    lines += ["", "## Zigrupt ratios and outcomes", "",
              "Each entry is ratio + outcome for Zigrupt. **Tradeoff** means opposite outcomes across throughput or latency metrics, not an overall winner.", "",
              "| Workload | Competitor | Throughput | p99 @50% | p99.9 @50% | p99 @90% | p99.9 @90% | Tradeoff |",
              "|---|---|---|---|---|---|---|---|"]
    def cell(result: dict[str, Any]) -> str:
        return f"{result['ratio']:.3f}× {result['verdict']}" if result['ratio'] is not None else "— inconclusive"
    for row in comparisons:
        columns = [cell(row[name]) for name in ("throughput", "p99_ns@0.5", "p999_ns@0.5", "p99_ns@0.9", "p999_ns@0.9")]
        lines.append(f"| {row['workload']} | {row['competitor']} | {' | '.join(columns)} | {'**yes**' if row['tradeoff'] else '—'} |")
    lines += ["", "## Scheduled-arrival latency", "",
              "All values below are microseconds, median [min–max] across runs. Histograms report bucket upper bounds (≤0.2% relative quantization error above 1 µs; exact below 1,024 ns). **Worst** is the max consumer per run, not a merged histogram. Rates come from `rates.json`, independently per workload, using the slowest median saturation throughput.", "",
              "| Workload | Implementation | Load | Offered events/s | Consumer | p50 µs | p99 µs | p99.9 µs |",
              "|---|---|---:|---:|---|---:|---:|---:|"]
    for row in summaries:
        if row["mode"] != "latency":
            continue
        for cid, consumer in [*enumerate(row["consumers"]), ("**worst**", row["worst"])]:
            columns = [format_stat(consumer[name], 1000) for name in ("p50_ns", "p99_ns", "p999_ns")]
            lines.append(f"| {row['workload']} | {row['implementation']} | {row['fraction']:.0%} | {row['offered_rate']} | {cid} | {' | '.join(columns)} |")
    lines += ["", "## Latency resource costs and allocation/GC evidence", "",
              "Native allocation counts: Rust global allocator calls; Zig allocator supplied to the bus (measurement arrays allocated before warmup). Java: worker-thread allocated bytes, not total JVM/native allocation. These are different scopes, not interchangeable allocation counters. Missing means unmeasured, not zero. `summary.json` retains setup memory, durations and all resource ranges.", "",
              "| Workload | Implementation | Mode/load | CPU cores | RSS MiB | Steady allocation calls / Java bytes | GC collections | JIT ms |",
              "|---|---|---|---:|---:|---:|---:|---:|"]
    for row in summaries:
        allocation = row.get("steady_allocations", row.get("steady_allocated_bytes"))
        alloc_text = format_stat(allocation) if allocation else "unmeasured"
        gc_text = format_stat(row["gc_count"]) if "gc_count" in row else "N/A"
        jit_text = format_stat(row["jit_ms"]) if "jit_ms" in row else "N/A"
        mode = row["mode"] if row["fraction"] is None else f"latency {row['fraction']:.0%}"
        lines.append(f"| {row['workload']} | {row['implementation']} | {mode} | {format_stat(row['cpu_cores'])} | {format_stat(row['peak_rss_bytes'], 2**20)} | {alloc_text} | {gc_text} | {jit_text} |")
    lines += ["", "## Interpretation and next experiments", ""]
    outcomes = Counter(row["throughput"]["verdict"] for row in comparisons if row["throughput"]["ratio"] is not None)
    lines += [f"Observed throughput comparisons: {dict(outcomes)}. Latency and throughput must be read separately; no overall winner is asserted.", "",
              "Ranked follow-up opportunities should be read with `../../FINDINGS.md` (measurement-specific analysis). The suite does not optimize Zigrupt. More cores are required to resolve the blocked multi-producer workloads.", "",
              "## Reproducibility and limitations", "",
              "- `manifest.json`: CPU topology/governor, OS, toolchain versions, pinned commits, source/binary hashes, JVM flags, run settings and load averages.",
              "- `runs.jsonl`: every correctness, calibration, throughput and latency run, exact commands, per-consumer results, errors and exclusions.",
              "- `rates.json`: auditable common-rate derivation; `summary.json`/`summary.csv`: all statistical summaries and ratios.",
              "- Shared laptop, dynamic frequency, no OS CPU isolation or thermal control. Fixed placement and randomized order reduce bias but do not eliminate noise. Short samples are particularly weak evidence for p99.9.",
              "- Payload checksum, per-producer order checks and rolling broadcast hash are included in all handlers. Results measure this verified application workload, not a zero-work queue microbenchmark.",
              "- Cumulative checksums/hashes are not a mathematical proof against every possible corruption. Preflight additionally compares exact broadcast traces, wraps repeatedly and deliberately blocks the slowest consumer."]
    if failed:
        lines += ["", "## Invalid runs (excluded)", ""]
        lines += [f"- {r['workload']} {r['implementation']} {r['mode']}: `{r.get('error', 'invalid')}`" for r in failed]
    (output / "REPORT.md").write_text("\n".join(lines) + "\n")
    svg(output, groups)


if __name__ == "__main__":
    report(Path(sys.argv[1]))
