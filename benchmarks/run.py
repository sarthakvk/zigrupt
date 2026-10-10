"""Run the competitive benchmark suite and save throughput and latency CSV files."""

from __future__ import annotations

import argparse
import csv
import hashlib
import itertools
import json
import math
import os
import random
import statistics
import subprocess
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import build as benchmark_build
from build import BIN, ROOT, adapter_hashes, tree_hash

IMPLEMENTATIONS = ("zigrupt", "java", "rust")
TOPOLOGIES = ((1, 1), (2, 1), (2, 2), (4, 1), (1, 3), (3, 3))
CASES = {f"{p}p{c}c": (p, c) for p, c in TOPOLOGIES}
LATENCY_FRACTIONS = (0.5, 0.6, 0.7, 0.8, 0.9, 0.95)
JVM_FLAGS = [
    "-Xms256m",
    "-Xmx256m",
    "-XX:+AlwaysPreTouch",
    "-XX:+UseSerialGC",
    "-XX:-TieredCompilation",
    "-Xbatch",
    "-XX:CICompilerCount=2",
]
COMMON_FIELDS = [
    "timestamp",
    "workload",
    "implementation",
    "mode",
    "repeat",
    "valid",
    "error",
    "producers",
    "consumer_count",
    "capacity",
    "payload",
    "cpus",
    "warm_events",
    "events",
    "offered_rate",
    "fraction",
    "warm_elapsed_ns",
    "elapsed_ns",
    "events_per_second",
    "deliveries_per_second",
    "cpu_cores",
    "peak_rss_bytes",
    "ring_requested_bytes",
    "allocator_live_bytes",
    "heap_used_bytes",
    "measurement_bytes",
    "steady_allocations",
    "steady_allocated_bytes",
    "gc_count",
    "gc_ms",
    "jit_ms",
    "blocked_publications",
    "max_batch_size",
    "reason",
]
LATENCY_FIELDS = COMMON_FIELDS + ["consumer", "p50_ns", "p99_ns", "p999_ns", "samples"]


@dataclass(frozen=True)
class Workload:
    producers: int
    consumers: int
    capacity: int
    payload: int

    @property
    def key(self) -> str:
        return f"{self.producers}p{self.consumers}c-{self.capacity}-{self.payload}b"


def workloads(cases: list[str]) -> list[Workload]:
    return [
        Workload(p, c, capacity, payload)
        for (p, c), capacity, payload in itertools.product(
            (CASES[case] for case in dict.fromkeys(cases)), (2048, 32768), (8, 64)
        )
    ]


def estimated_runtime(
    args: argparse.Namespace, jobs: list[tuple[Workload, str]], core_count: int
) -> float:
    # Checks and calibration are event-count based, so allow a rough second each.
    seconds = len(jobs) * (1 + args.cooldown)
    if args.check_only:
        return seconds
    eligible_count = sum(
        w.producers + w.consumers <= core_count for w, _ in jobs
    )
    warm_seconds = 0.03 if args.smoke else args.warm_seconds
    measure_seconds = 0.03 if args.smoke else args.seconds
    seconds += eligible_count * (1 + args.cooldown)
    seconds += (
        eligible_count
        * args.repeats
        * (1 + len(LATENCY_FRACTIONS))
        * (warm_seconds + measure_seconds + args.cooldown)
    )
    return seconds


def format_duration(seconds: float) -> str:
    minutes, seconds = divmod(math.ceil(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def cpu_topology() -> list[dict[str, Any]]:
    def read(cpu_root: Path, relative: str) -> str | None:
        file = cpu_root / relative
        return file.read_text().strip() if file.exists() else None

    result: list[dict[str, Any]] = []
    for cpu in sorted(os.sched_getaffinity(0)):
        root = Path(f"/sys/devices/system/cpu/cpu{cpu}")
        result.append(
            {
                "cpu": cpu,
                "core": read(root, "topology/core_id"),
                "socket": read(root, "topology/physical_package_id"),
                "core_type": read(root, "topology/core_type"),
                "capacity": read(root, "cpu_capacity"),
                "siblings": read(root, "topology/thread_siblings_list"),
                "governor": read(root, "cpufreq/scaling_governor"),
                "min_khz": read(root, "cpufreq/scaling_min_freq"),
                "max_khz": read(root, "cpufreq/scaling_max_freq"),
            }
        )
    return result


def physical_cpus(topology: list[dict[str, Any]]) -> list[int]:
    groups: dict[tuple[Any, ...], dict[tuple[Any, ...], int]] = {}
    for row in topology:
        if row["core"] is None or row["socket"] is None:
            raise RuntimeError(
                "Physical core topology unavailable; cannot enforce placement"
            )
        group = (row["socket"], row["core_type"], row["capacity"])
        groups.setdefault(group, {}).setdefault(
            (row["socket"], row["core"]), row["cpu"]
        )
    return list(max(groups.values(), key=len).values())


def expected_checksum(total: int, payload: int) -> int:
    words = payload // 8
    return (words * total * (total - 1) // 2 + total * words * (words - 1) // 2) % (
        1 << 64
    )


def validate(
    result: dict[str, Any], w: Workload, warm: int, count: int, rate: int
) -> None:
    if not result.get("valid") or result["elapsed_ns"] <= 0:
        raise ValueError("Adapter did not report a valid completed run")
    consumers = result["consumers"]
    if len(consumers) != w.consumers:
        raise ValueError("Wrong number of consumers")
    for consumer in consumers:
        if consumer["count"] != warm + count or consumer[
            "checksum"
        ] != expected_checksum(warm + count, w.payload):
            raise ValueError("Count/checksum mismatch")
        if consumer["order_hash"] != consumers[0]["order_hash"]:
            raise ValueError("Broadcast order mismatch")
        if rate and (
            consumer["samples"] != count
            or not 0 <= consumer["p50_ns"] <= consumer["p99_ns"] <= consumer["p999_ns"]
        ):
            raise ValueError("Invalid latency samples")


def command(
    impl: str,
    w: Workload,
    warm: int,
    count: int,
    rate: int,
    check: bool,
    cpus: list[int],
) -> list[str]:
    args = list(
        map(
            str,
            (
                w.producers,
                w.consumers,
                w.capacity,
                w.payload,
                warm,
                count,
                rate,
                int(check),
                *cpus,
            ),
        )
    )
    if impl == "java":
        return [
            "java",
            *JVM_FLAGS,
            f"-XX:ActiveProcessorCount={len(cpus)}",
            f"-Djava.library.path={BIN}",
            "-cp",
            f"{BIN / 'java-adapter'}:{BIN / 'java-library'}",
            "Bench",
            *args,
        ]
    return [str(BIN / impl), *args]


def rounded(value: float, producers: int) -> int:
    return max(producers, ((int(value) + producers - 1) // producers) * producers)


class Runner:
    def __init__(self, output: Path, cpus: list[int], args: argparse.Namespace) -> None:
        self.output = output
        self.cpus = cpus
        self.args = args
        self.results: list[dict[str, Any]] = []

    def save(self, result: dict[str, Any]) -> None:
        self.results.append(result)
        latency = result["mode"] == "latency"
        path = self.output / ("latency.csv" if latency else "throughput.csv")
        fields = LATENCY_FIELDS if latency else COMMON_FIELDS
        row = {key: result.get(key) for key in fields}
        consumer_data = result.get("consumers")
        row["consumer_count"] = result.get(
            "consumer_count",
            len(consumer_data) if isinstance(consumer_data, list) else consumer_data,
        )
        row["cpus"] = ":".join(map(str, result.get("cpus", [])))
        consumers = (
            consumer_data
            if latency and result.get("valid") and isinstance(consumer_data, list)
            else []
        )
        with path.open("a", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=fields)
            if file.tell() == 0:
                writer.writeheader()
            for index, consumer in enumerate(consumers):
                writer.writerow(
                    {
                        **row,
                        "consumer": index,
                        **{
                            field: consumer.get(field)
                            for field in ("p50_ns", "p99_ns", "p999_ns", "samples")
                        },
                    }
                )
            if not consumers:
                writer.writerow(row)

    def sample(
        self,
        impl: str,
        w: Workload,
        mode: str,
        repeat: int,
        warm: int,
        count: int,
        rate: int = 0,
        fraction: float | None = None,
    ) -> dict[str, Any]:
        nworkers = w.producers + w.consumers
        # SMT/reused CPUs are permitted ONLY for correctness tests, never rankings.
        placement = self.cpus[:nworkers]
        if mode == "check" and len(placement) < nworkers:
            allowed = sorted(os.sched_getaffinity(0))
            placement = [allowed[i % len(allowed)] for i in range(nworkers)]
        if len(placement) != nworkers:
            raise RuntimeError("Insufficient physical cores")
        cmd = command(impl, w, warm, count, rate, mode == "check", placement)
        record: dict[str, Any] = {
            "implementation": impl,
            "workload": w.key,
            **asdict(w),
            "mode": mode,
            "consumer_count": w.consumers,
            "repeat": repeat,
            "warm_events": warm,
            "events": count,
            "offered_rate": rate,
            "fraction": fraction,
            "cpus": placement,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "valid": False,
        }
        try:
            process = subprocess.run(
                cmd,
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
                timeout=self.args.timeout,
                preexec_fn=lambda: os.sched_setaffinity(0, placement),
            )
            record["stderr"] = process.stderr
            if process.returncode:
                raise RuntimeError(
                    f"exit {process.returncode}: {process.stderr[-3000:]}"
                )
            result = json.loads(process.stdout)
            validate(result, w, warm, count, rate)
            if impl == "zigrupt":
                if result.get("max_batch_size") != w.capacity:
                    raise ValueError(
                        "Zigrupt consumer batch limit must equal ring capacity"
                    )
                if mode == "check" and (
                    not all(
                        1 <= c.get("max_observed_batch", 0) <= w.capacity
                        for c in result["consumers"]
                    )
                    or result["consumers"][-1].get("max_observed_batch", 0) <= 1
                ):
                    raise ValueError("Missing native consumer batching evidence")
            record.update(result)
            record["events_per_second"] = count * 1e9 / result["elapsed_ns"]
            record["deliveries_per_second"] = w.consumers * record["events_per_second"]
            record["cpu_cores"] = result["cpu_ns"] / result["elapsed_ns"]
            if mode == "check" and result["blocked_publications"] != w.capacity:
                raise ValueError("Missing slow-consumer backpressure evidence")
        except (subprocess.TimeoutExpired, RuntimeError, ValueError, KeyError) as error:
            record["valid"] = False
            record["error"] = str(error)
            print(f"INVALID {mode} {w.key} {impl}: {error}", flush=True)
        self.save(record)
        time.sleep(self.args.cooldown)
        return record


def build_issue(standalone: bool = False) -> str | None:
    metadata = BIN / "build.json"
    if not metadata.exists():
        return "build metadata is missing"
    build = json.loads(metadata.read_text())
    if not standalone and build.get("standalone"):
        return "full suite binaries are missing"
    if build["zigrupt_source_sha256"] != tree_hash(ROOT.parent / "src"):
        return "Zigrupt source changed"
    expected_adapters = adapter_hashes(standalone)
    if any(
        build["adapter_sha256"].get(name) != digest
        for name, digest in expected_adapters.items()
    ):
        return "benchmark adapter changed"
    required_binaries = (
        ("zigrupt",) if standalone else ("zigrupt", "rust", "libbenchplatform.so")
    )
    for name in required_binaries:
        expected = build["binaries_sha256"].get(name)
        binary = BIN / name
        if (
            expected is None
            or not binary.exists()
            or hashlib.sha256(binary.read_bytes()).hexdigest() != expected
        ):
            return f"binary changed or is missing: {name}"
    if not standalone and (
        build.get("java_classes_sha256") != tree_hash(BIN / "java-adapter")
        or build.get("java_library_classes_sha256") != tree_hash(BIN / "java-library")
    ):
        return "Java classes changed"
    return None


def main() -> None:
    default_output = Path("results") / datetime.now(timezone.utc).strftime(
        "run-%Y%m%dT%H%M%S%fZ"
    )
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=default_output,
        help="directory for the CSV files; must not already exist",
    )
    parser.add_argument(
        "--case",
        nargs="+",
        choices=list(CASES),
        default=list(CASES),
        help="producer/consumer cases to run",
    )
    parser.add_argument(
        "--repeats",
        type=int,
        default=5,
        help="independent measurement rounds (minimum: 3)",
    )
    parser.add_argument(
        "--seconds",
        type=float,
        default=2,
        help="target measurement duration per sample",
    )
    parser.add_argument(
        "--warm-seconds",
        type=float,
        default=3,
        help="target warmup duration per sample",
    )
    parser.add_argument("--seed", type=int, default=20261007, help="random order seed")
    parser.add_argument(
        "--cooldown", type=float, default=0.25, help="pause between samples in seconds"
    )
    parser.add_argument(
        "--timeout", type=float, default=180, help="maximum seconds per sample"
    )
    parser.add_argument(
        "--smoke", action="store_true", help="Tiny unranked end-to-end verification"
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="run correctness checks without performance measurements",
    )
    parser.add_argument(
        "--standalone",
        action="store_true",
        help="benchmark Zigrupt alone using the same adapter and measurements",
    )
    args = parser.parse_args()
    if (
        args.repeats < 3
        or args.seconds <= 0
        or args.warm_seconds <= 0
        or args.cooldown < 0
        or args.timeout <= 0
    ):
        parser.error(
            "Use at least three repeats, positive durations and timeout, and nonnegative cooldown"
        )
    selected_implementations = (
        IMPLEMENTATIONS[:1] if args.standalone else IMPLEMENTATIONS
    )
    output = (ROOT / args.output).resolve()
    if output.exists():
        parser.error(f"output directory already exists: {output}")
    cpus = physical_cpus(cpu_topology())
    jobs = [(w, impl) for w in workloads(args.case) for impl in selected_implementations]
    estimate = estimated_runtime(args, jobs, len(cpus))
    print(f"Approximate benchmark runtime: {format_duration(estimate)}", flush=True)
    issue = build_issue(args.standalone)
    if issue:
        print(f"Building benchmarks ({issue})...", flush=True)
        benchmark_build.main(standalone=args.standalone)
        issue = build_issue(args.standalone)
        if issue:
            raise RuntimeError(f"Benchmark build is still invalid: {issue}")
    output.mkdir(parents=True, exist_ok=False)
    runner = Runner(output, cpus, args)
    rng = random.Random(args.seed)
    rng.shuffle(jobs)
    checks: dict[tuple[str, str], bool] = {}
    print(f"Checking {len(jobs)} workloads...", flush=True)
    for w, impl in jobs:
        warm = rounded(w.capacity * 4, w.producers)
        count = rounded(w.capacity * 8, w.producers)
        r = runner.sample(impl, w, "check", 0, warm, count)
        checks[w.key, impl] = r["valid"]
    if args.check_only:
        print(f"Saved {output / 'throughput.csv'}", flush=True)
        return
    eligible: list[tuple[Workload, str]] = []
    for w, impl in jobs:
        if w.producers + w.consumers > len(cpus):
            runner.save(
                {
                    "workload": w.key,
                    "implementation": impl,
                    "mode": "blocked",
                    "valid": False,
                    "producers": w.producers,
                    "consumer_count": w.consumers,
                    "capacity": w.capacity,
                    "payload": w.payload,
                    "reason": f"requires {w.producers + w.consumers} physical cores; only {len(cpus)} available",
                }
            )
        elif not checks[w.key, impl]:
            runner.save(
                {
                    "workload": w.key,
                    "implementation": impl,
                    "mode": "blocked",
                    "valid": False,
                    "producers": w.producers,
                    "consumer_count": w.consumers,
                    "capacity": w.capacity,
                    "payload": w.payload,
                    "reason": "correctness preflight failed",
                }
            )
        else:
            eligible.append((w, impl))
    estimates: dict[tuple[str, str], float] = {}
    print(f"Calibrating {len(eligible)} workloads...", flush=True)
    for w, impl in eligible:
        n = rounded(
            max(w.capacity * 32, 100_000 if args.smoke else 2_000_000), w.producers
        )
        pilot = runner.sample(impl, w, "calibration", 0, n, n)
        if pilot["valid"]:
            estimates[w.key, impl] = pilot["events_per_second"]
    eligible = [(w, impl) for w, impl in eligible if (w.key, impl) in estimates]
    for repeat in range(args.repeats):
        print(f"Throughput round {repeat + 1}/{args.repeats}", flush=True)
        rng.shuffle(eligible)
        for w, impl in eligible:
            estimate = estimates[w.key, impl]
            warm = rounded(
                max(
                    w.capacity * 4,
                    estimate * (0.03 if args.smoke else args.warm_seconds),
                ),
                w.producers,
            )
            n = rounded(
                max(w.capacity * 8, estimate * (0.03 if args.smoke else args.seconds)),
                w.producers,
            )
            runner.sample(impl, w, "throughput", repeat, warm, n)
    rates: dict[str, dict[str, Any]] = {}
    for w in workloads(args.case):
        per_impl: dict[str, float] = {}
        for impl in selected_implementations:
            runs = [
                r
                for r in runner.results
                if r["workload"] == w.key
                and r["implementation"] == impl
                and r["mode"] == "throughput"
            ]
            if len(runs) == args.repeats and all(r["valid"] for r in runs):
                per_impl[impl] = statistics.median(r["events_per_second"] for r in runs)
        if len(per_impl) == len(selected_implementations):
            slowest = min(per_impl.values())
            rates[w.key] = {
                "saturation_medians": per_impl,
                "slowest": slowest,
                "rates": {str(f): max(1, int(slowest * f)) for f in LATENCY_FRACTIONS},
            }
    latency_jobs = [
        (w, impl, f) for w, impl in eligible if w.key in rates for f in LATENCY_FRACTIONS
    ]
    for repeat in range(args.repeats):
        print(f"Latency round {repeat + 1}/{args.repeats}", flush=True)
        rng.shuffle(latency_jobs)
        for w, impl, fraction in latency_jobs:
            rate = rates[w.key]["rates"][str(fraction)]
            warm = rounded(
                max(w.capacity * 4, rate * (0.03 if args.smoke else args.warm_seconds)),
                w.producers,
            )
            n = rounded(
                max(w.capacity * 8, rate * (0.03 if args.smoke else args.seconds)),
                w.producers,
            )
            runner.sample(impl, w, "latency", repeat, warm, n, rate, fraction)
    if not (output / "latency.csv").exists():
        with (output / "latency.csv").open("w", newline="") as file:
            csv.writer(file).writerow(LATENCY_FIELDS)
    print(f"Saved {output / 'throughput.csv'} and {output / 'latency.csv'}", flush=True)


if __name__ == "__main__":
    main()
