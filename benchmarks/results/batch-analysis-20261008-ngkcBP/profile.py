#!/usr/bin/env python3
"""Supplementary sampled profiles, excluded from the benchmark summary."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import time

OUT = Path(__file__).resolve().parent


def main() -> None:
    while "All benchmark runs complete." not in (OUT / "progress.log").read_text():
        time.sleep(2)
    commands: list[list[str]] = []
    for variant, batch in [("baseline", None), ("head", 1), ("head", 64)]:
        name = f"profile-1p1c-{variant}-b{batch or 0}"
        command = ["perf", "record", "-e", "cycles:u", "-F", "499", "-o", str(OUT / f"{name}.data"), "--",
                   str(OUT / f"bench-{variant}"), "--publishers=1", "--consumers=1", "--publisher_cpus=0", "--consumer_cpus=1",
                   "--repetitions=3", "--min_duration_ms=500", "--events_per_publisher=100000"]
        if batch is not None:
            command.append(f"--max_batch={batch}")
        commands.append(command)
        print(name, flush=True)
        with (OUT / f"{name}.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
        with (OUT / f"{name}-symbols.txt").open("w") as report:
            subprocess.run(["perf", "report", "--stdio", "--no-children", "--sort", "symbol", "--percent-limit", "1",
                            "-i", str(OUT / f"{name}.data")], stdout=report, check=True)
        with (OUT / f"{name}-source.txt").open("w") as report:
            subprocess.run(["perf", "report", "--stdio", "--no-children", "--sort", "symbol,srcline", "--percent-limit", "1",
                            "-i", str(OUT / f"{name}.data")], stdout=report, check=True)
    (OUT / "profile-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    print("Profiles complete.", flush=True)


if __name__ == "__main__":
    main()
