#!/usr/bin/env python3
"""Run only the committed performance benchmarks; never invoke tests."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import random
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
TOPOLOGIES = {"1p1c": ([0], [1]), "1p3c": ([0], [1, 2, 3]), "2p2c": ([0, 1], [2, 3])}
BATCHES = [1, 4, 16, 64, 256, 1024]


def capture(command: list[str]) -> str:
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def main() -> None:
    manifest: dict[str, object] = {
        "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "zig": capture(["zig", "version"]),
        "uname": capture(["uname", "-a"]),
        "cpu": capture(["lscpu"]),
        "topology": capture(["lscpu", "-e=CPU,CORE,SOCKET,ONLINE"]),
        "affinity": sorted(os.sched_getaffinity(0)),
        "initial_git_status": capture(["git", "status", "--short"]),
        "rounds": 2, "repetitions_per_round": 3, "min_duration_ms": 500,
        "batch_limits": BATCHES, "placements": TOPOLOGIES,
        "random_seed": 801026, "builds": {},
    }
    builds: dict[str, object] = {}
    for variant, ref in [("baseline", "HEAD~2"), ("head", "HEAD")]:
        commit = capture(["git", "rev-parse", ref])
        tree = OUT / variant
        tree.mkdir()
        archive = subprocess.check_output(["git", "archive", commit], cwd=ROOT)
        subprocess.run(["tar", "-x", "-C", str(tree)], input=archive, check=True)
        executable = OUT / f"bench-{variant}"
        command = ["zig", "build-exe", "-OReleaseFast", "--dep", "zigrupt",
                   f"-Mroot={tree / 'bench/ring_buffer.zig'}", "-OReleaseFast",
                   f"-Mzigrupt={tree / 'src/root.zig'}", f"-femit-bin={executable}"]
        print(f"Building {variant}: {commit}", flush=True)
        subprocess.run(command, cwd=ROOT, check=True)
        builds[variant] = {"commit": commit, "command": command,
                           "sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
    manifest["builds"] = builds
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    rng = random.Random(801026)
    configs = [(topology, variant, batch) for topology in TOPOLOGIES
               for variant, batches in [("baseline", [None]), ("head", BATCHES)]
               for batch in batches]
    with (OUT / "runs.jsonl").open("w") as results:
        for round_id in range(1, 3):
            order = configs.copy()
            rng.shuffle(order)
            for index, (topology, variant, batch) in enumerate(order):
                publishers, consumers = TOPOLOGIES[topology]
                name = f"r{round_id}-{topology}-{variant}-b{batch or 0}"
                command = [str(OUT / f"bench-{variant}"), f"--publishers={len(publishers)}",
                           f"--consumers={len(consumers)}", "--repetitions=3", "--min_duration_ms=500",
                           "--events_per_publisher=100000",
                           "--publisher_cpus=" + ",".join(map(str, publishers)),
                           "--consumer_cpus=" + ",".join(map(str, consumers))]
                if batch is not None:
                    command.append(f"--max_batch={batch}")
                print(f"[{round_id}/2 {index + 1}/{len(order)}] {name}", flush=True)
                started = time.time()
                run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=240)
                output = run.stdout + run.stderr
                (OUT / f"{name}.log").write_text(output)
                row: dict[str, object] = {
                    "round": round_id, "topology": topology, "variant": variant, "batch": batch,
                    "command": command, "started_unix": started, "wall_seconds": time.time() - started,
                    "returncode": run.returncode, "log": f"{name}.log",
                    "throughput": [{"run": int(rep), "meps": float(rate), "ms": float(ms)}
                                   for rep, rate, ms in re.findall(r"run (\d+): ([\d.]+) million events/s \(([\d.]+) ms\)", output)],
                    "latency": [{"run": int(rep), "p50_ns": int(p50), "p99_ns": int(p99), "ms": float(ms)}
                                for rep, p50, p99, ms in re.findall(r"run (\d+): p50 (\d+) ns, p99 (\d+) ns \(([\d.]+) ms\)", output)],
                    "warnings": [line.strip() for line in output.splitlines() if "WARNING" in line],
                }
                results.write(json.dumps(row) + "\n")
                results.flush()
                if run.returncode or len(row["throughput"]) != 3 or len(row["latency"]) != 3:
                    raise RuntimeError(f"Benchmark failed: {name}; see log")
                time.sleep(1)
    print("All benchmark runs complete.", flush=True)


if __name__ == "__main__":
    main()
