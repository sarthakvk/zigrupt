"""Sequential, randomized independent processes; no third-party Python packages."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import time
from typing import Any

from build import BIN, ROOT, adapter_hashes, tree_hash

IMPLEMENTATIONS = ("zigrupt", "java", "rust", "ziggy")
TOPOLOGIES = ((1, 1), (4, 1), (1, 3), (3, 3))
JVM_FLAGS = ["-Xms256m", "-Xmx256m", "-XX:+AlwaysPreTouch", "-XX:+UseSerialGC",
             "-XX:-TieredCompilation", "-Xbatch", "-XX:CICompilerCount=2"]


@dataclass(frozen=True)
class Workload:
    producers: int
    consumers: int
    capacity: int
    payload: int

    @property
    def key(self) -> str:
        return f"{self.producers}p{self.consumers}c-{self.capacity}-{self.payload}b"

    @property
    def implementations(self) -> tuple[str, ...]:
        return IMPLEMENTATIONS if self.consumers == 1 else IMPLEMENTATIONS[:-1]


def workloads() -> list[Workload]:
    return [Workload(p, c, capacity, payload) for (p, c), capacity, payload in
            itertools.product(TOPOLOGIES, (2048, 32768), (8, 64))]


def cpu_topology() -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for cpu in sorted(os.sched_getaffinity(0)):
        root = Path(f"/sys/devices/system/cpu/cpu{cpu}")
        def read(relative: str) -> str | None:
            file = root / relative
            return file.read_text().strip() if file.exists() else None
        result.append({"cpu": cpu, "core": read("topology/core_id"),
                       "socket": read("topology/physical_package_id"),
                       "core_type": read("topology/core_type"),
                       "capacity": read("cpu_capacity"),
                       "siblings": read("topology/thread_siblings_list"),
                       "governor": read("cpufreq/scaling_governor"),
                       "min_khz": read("cpufreq/scaling_min_freq"),
                       "max_khz": read("cpufreq/scaling_max_freq")})
    return result


def physical_cpus(topology: list[dict[str, Any]]) -> list[int]:
    groups: dict[tuple[Any, ...], dict[tuple[Any, ...], int]] = {}
    for row in topology:
        if row["core"] is None or row["socket"] is None:
            raise RuntimeError("Physical core topology unavailable; cannot enforce placement")
        group = (row["socket"], row["core_type"], row["capacity"])
        groups.setdefault(group, {}).setdefault((row["socket"], row["core"]), row["cpu"])
    return list(max(groups.values(), key=len).values())


def expected_checksum(total: int, payload: int) -> int:
    words = payload // 8
    return (words * total * (total - 1) // 2 + total * words * (words - 1) // 2) % (1 << 64)


def validate(result: dict[str, Any], w: Workload, warm: int, count: int, rate: int) -> None:
    if not result.get("valid") or result["elapsed_ns"] <= 0:
        raise ValueError("Adapter did not report a valid completed run")
    consumers = result["consumers"]
    if len(consumers) != w.consumers:
        raise ValueError("Wrong number of consumers")
    for consumer in consumers:
        if consumer["count"] != warm + count or consumer["checksum"] != expected_checksum(warm + count, w.payload):
            raise ValueError("Count/checksum mismatch")
        if consumer["order_hash"] != consumers[0]["order_hash"]:
            raise ValueError("Broadcast order mismatch")
        if rate and (consumer["samples"] != count or not 0 <= consumer["p50_ns"] <= consumer["p99_ns"] <= consumer["p999_ns"]):
            raise ValueError("Invalid latency samples")


def command(impl: str, w: Workload, warm: int, count: int, rate: int, check: bool, cpus: list[int]) -> list[str]:
    args = list(map(str, (w.producers, w.consumers, w.capacity, w.payload, warm, count, rate, int(check), *cpus)))
    if impl == "java":
        return ["java", *JVM_FLAGS, f"-XX:ActiveProcessorCount={len(cpus)}",
                f"-Djava.library.path={BIN}", "-cp", f"{BIN / 'java-adapter'}:{BIN / 'java-library'}", "Bench", *args]
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
        with (self.output / "runs.jsonl").open("a") as file:
            file.write(json.dumps(result, separators=(",", ":")) + "\n")
            file.flush()

    def sample(self, impl: str, w: Workload, mode: str, repeat: int, warm: int, count: int,
               rate: int = 0, fraction: float | None = None) -> dict[str, Any]:
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
            "implementation": impl, "workload": w.key, **asdict(w), "mode": mode,
            "repeat": repeat, "warm_events": warm, "events": count, "offered_rate": rate,
            "fraction": fraction, "cpus": placement, "command": cmd,
            "timestamp": datetime.now(timezone.utc).isoformat(), "valid": False,
        }
        print(f"{mode:11} {repeat} {w.key:23} {impl:7} n={count} rate={rate}", flush=True)
        try:
            process = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True,
                                     timeout=self.args.timeout,
                                     preexec_fn=lambda: os.sched_setaffinity(0, placement))
            record["stderr"] = process.stderr
            if process.returncode:
                raise RuntimeError(f"exit {process.returncode}: {process.stderr[-3000:]}")
            result = json.loads(process.stdout)
            validate(result, w, warm, count, rate)
            record.update(result)
            record["events_per_second"] = count * 1e9 / result["elapsed_ns"]
            record["deliveries_per_second"] = w.consumers * record["events_per_second"]
            record["cpu_cores"] = result["cpu_ns"] / result["elapsed_ns"]
            if mode == "check" and result["blocked_publications"] != w.capacity + (impl == "ziggy"):
                raise ValueError("Missing slow-consumer backpressure evidence")
        except (subprocess.TimeoutExpired, RuntimeError, ValueError, KeyError) as error:
            record["valid"] = False
            record["error"] = str(error)
            print("INVALID:", error, flush=True)
        self.save(record)
        time.sleep(self.args.cooldown)
        return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "results/baseline")
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--seconds", type=float, default=2)
    parser.add_argument("--warm-seconds", type=float, default=3)
    parser.add_argument("--seed", type=int, default=20261007)
    parser.add_argument("--cooldown", type=float, default=0.25)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--smoke", action="store_true", help="Tiny unranked end-to-end verification")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if args.repeats < 3 or args.seconds <= 0 or args.warm_seconds <= 0:
        parser.error("Use at least three repeats and positive durations")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    build = json.loads((BIN / "build.json").read_text())
    if build["zigrupt_source_sha256"] != tree_hash(ROOT.parent / "src"):
        raise RuntimeError("Zigrupt changed since build; rebuild before benchmarking")
    if build["adapter_sha256"] != adapter_hashes():
        raise RuntimeError("Adapter changed since build; rebuild before benchmarking")
    for name, expected in build["binaries_sha256"].items():
        if hashlib.sha256((BIN / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Binary changed since build: {name}")
    if build["java_classes_sha256"] != tree_hash(BIN / "java-adapter") or build["java_library_classes_sha256"] != tree_hash(BIN / "java-library"):
        raise RuntimeError("Java classes changed since build")
    topology = cpu_topology()
    cpus = physical_cpus(topology)
    manifest = {"started": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
                "machine": subprocess.check_output(["lscpu"], text=True), "cpu_topology": topology,
                "physical_cpus": cpus, "jvm_flags": JVM_FLAGS, "build": build,
                "settings": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                "harness_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in sorted(ROOT.rglob("*")) if p.is_file()
                                   and not any(part.startswith(".") or part in ("target", "results", "__pycache__") for part in p.relative_to(ROOT).parts)
                                   and p.suffix in (".py", ".zig", ".rs", ".java", ".c", ".json", ".lock")},
                "loadavg_start": os.getloadavg()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    runner = Runner(output, cpus, args)
    rng = random.Random(args.seed)
    jobs = [(w, impl) for w in workloads() for impl in w.implementations]
    rng.shuffle(jobs)
    checks: dict[tuple[str, str], bool] = {}
    for w, impl in jobs:
        warm = rounded(w.capacity * 4, w.producers)
        count = rounded(w.capacity * 8, w.producers)
        r = runner.sample(impl, w, "check", 0, warm, count)
        checks[w.key, impl] = r["valid"]
    if args.check_only:
        return
    eligible: list[tuple[Workload, str]] = []
    for w, impl in jobs:
        if w.producers + w.consumers > len(cpus):
            runner.save({"workload": w.key, "implementation": impl, "mode": "blocked", "valid": False,
                         "reason": f"requires {w.producers + w.consumers} physical cores; only {len(cpus)} available"})
        elif not checks[w.key, impl]:
            runner.save({"workload": w.key, "implementation": impl, "mode": "blocked", "valid": False,
                         "reason": "correctness preflight failed"})
        else:
            eligible.append((w, impl))
    estimates: dict[tuple[str, str], float] = {}
    for w, impl in eligible:
        n = rounded(max(w.capacity * 32, 100_000 if args.smoke else 2_000_000), w.producers)
        pilot = runner.sample(impl, w, "calibration", 0, n, n)
        if pilot["valid"]:
            estimates[w.key, impl] = pilot["events_per_second"]
    eligible = [(w, impl) for w, impl in eligible if (w.key, impl) in estimates]
    for repeat in range(args.repeats):
        rng.shuffle(eligible)
        for w, impl in eligible:
            estimate = estimates[w.key, impl]
            warm = rounded(max(w.capacity * 4, estimate * (0.03 if args.smoke else args.warm_seconds)), w.producers)
            n = rounded(max(w.capacity * 8, estimate * (0.03 if args.smoke else args.seconds)), w.producers)
            runner.sample(impl, w, "throughput", repeat, warm, n)
    rates: dict[str, dict[str, Any]] = {}
    for w in workloads():
        per_impl: dict[str, float] = {}
        for impl in w.implementations:
            runs = [r for r in runner.results if r["workload"] == w.key and r["implementation"] == impl
                    and r["mode"] == "throughput"]
            if len(runs) == args.repeats and all(r["valid"] for r in runs):
                per_impl[impl] = statistics.median(r["events_per_second"] for r in runs)
        if len(per_impl) == len(w.implementations):
            slowest = min(per_impl.values())
            rates[w.key] = {"saturation_medians": per_impl, "slowest": slowest,
                            "rates": {str(f): max(1, int(slowest * f)) for f in (0.5, 0.9)}}
    (output / "rates.json").write_text(json.dumps(rates, indent=2) + "\n")
    latency_jobs = [(w, impl, f) for w, impl in eligible if w.key in rates for f in (0.5, 0.9)]
    for repeat in range(args.repeats):
        rng.shuffle(latency_jobs)
        for w, impl, fraction in latency_jobs:
            rate = rates[w.key]["rates"][str(fraction)]
            warm = rounded(max(w.capacity * 4, rate * (0.03 if args.smoke else args.warm_seconds)), w.producers)
            n = rounded(max(w.capacity * 8, rate * (0.03 if args.smoke else args.seconds)), w.producers)
            runner.sample(impl, w, "latency", repeat, warm, n, rate, fraction)
    manifest["finished"] = datetime.now(timezone.utc).isoformat()
    manifest["loadavg_end"] = os.getloadavg()
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    from report import report
    report(output)


if __name__ == "__main__":
    main()
