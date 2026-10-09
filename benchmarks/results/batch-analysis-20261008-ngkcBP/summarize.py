#!/usr/bin/env python3
"""Aggregate performance measurements, retaining every reported repetition."""
from __future__ import annotations

import csv
import json
from pathlib import Path
from statistics import median

OUT = Path(__file__).resolve().parent


def main() -> None:
    runs = [json.loads(line) for line in (OUT / "runs.jsonl").read_text().splitlines()]
    rows: list[dict[str, object]] = []
    for topology in ["1p1c", "1p3c", "2p2c"]:
        baseline = [rep["meps"] for run in runs if run["topology"] == topology and run["variant"] == "baseline"
                    for rep in run["throughput"]]
        for variant, batch in [("baseline", None), *(('head', b) for b in [1, 4, 16, 64, 256, 1024])]:
            group = [run for run in runs if (run["topology"], run["variant"], run["batch"]) == (topology, variant, batch)]
            if not group:
                continue
            rates = [rep["meps"] for run in group for rep in run["throughput"]]
            latencies = [rep for run in group for rep in run["latency"]]
            row: dict[str, object] = {"topology": topology, "variant": variant, "max_batch": batch,
                                     "n": len(rates), "meps_median": median(rates), "meps_min": min(rates), "meps_max": max(rates),
                                     "vs_baseline_pct": 100 * (median(rates) / median(baseline) - 1) if baseline else None,
                                     "short_throughput_runs": sum(rep["ms"] < 500 for run in group for rep in run["throughput"]),
                                     "short_latency_runs": sum(rep["ms"] < 500 for rep in latencies)}
            for key in ["p50_ns", "p99_ns"]:
                values = [rep[key] for rep in latencies]
                row[key + "_median"] = median(values)
                row[key + "_min"] = min(values)
                row[key + "_max"] = max(values)
            for round_id in [1, 2]:
                values = [rep["meps"] for run in group if run["round"] == round_id for rep in run["throughput"]]
                row[f"r{round_id}_meps_median"] = median(values) if values else None
            rows.append(row)
    (OUT / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")
    with (OUT / "summary.csv").open("w") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    lines = ["| Topology | Revision / batch limit | Runs | Throughput median [min–max], M events/s | Δ vs HEAD~2 | Latency p50 / p99, µs |",
             "|---|---|---:|---:|---:|---:|"]
    for row in rows:
        label = "HEAD~2 (no batching)" if row["variant"] == "baseline" else f"HEAD / {row['max_batch']}"
        delta = row["vs_baseline_pct"]
        delta_text = f"{delta:+.1f}%" if delta is not None else "—"
        lines.append(f"| {row['topology']} | {label} | {row['n']} | {row['meps_median']:.3f} [{row['meps_min']:.3f}–{row['meps_max']:.3f}] | {delta_text} | {row['p50_ns_median'] / 1000:.2f} / {row['p99_ns_median'] / 1000:.2f} |")
    (OUT / "TABLE.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"\nCompleted configurations: {len(runs)}/42; throughput repetitions: {sum(len(run['throughput']) for run in runs)}; latency repetitions: {sum(len(run['latency']) for run in runs)}")
    print(f"Short throughput runs: {sum(row['short_throughput_runs'] for row in rows)}; short latency runs: {sum(row['short_latency_runs'] for row in rows)}")


if __name__ == "__main__":
    main()
