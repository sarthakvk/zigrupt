from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from build import BIN, ROOT
from report import compare, quality, stats
from run import Runner, Workload, command, expected_checksum, physical_cpus, rounded, validate, workloads


class SpecificationTests(unittest.TestCase):
    def test_locked_matrix(self) -> None:
        matrix = workloads()
        self.assertEqual(len(matrix), 16)
        self.assertEqual(sum(len(w.implementations) for w in matrix), 56)
        for w in matrix:
            self.assertEqual("ziggy" in w.implementations, w.consumers == 1)

    def test_physical_core_selection(self) -> None:
        topology = [{"cpu": i, "core": str(i % 4), "socket": "0", "core_type": "1", "capacity": None}
                    for i in range(8)]
        self.assertEqual(physical_cpus(topology), [0, 1, 2, 3])
        topology[3]["core_type"] = topology[7]["core_type"] = "2"
        self.assertEqual(physical_cpus(topology), [0, 1, 2])

    def test_counts_and_checksum(self) -> None:
        for p in (1, 3, 4):
            for value in (0, 1, 2048, 32768, 111111.2):
                self.assertEqual(rounded(value, p) % p, 0)
                self.assertGreaterEqual(rounded(value, p), int(value))
        for payload in (8, 64):
            self.assertEqual(expected_checksum(19, payload), sum(i + j for i in range(19) for j in range(payload // 8)))

    def test_validation_rejects_corrupt_or_partial_results(self) -> None:
        w = Workload(1, 1, 2048, 8)
        good = {"valid": True, "elapsed_ns": 100, "consumers": [
            {"count": 10, "checksum": 45, "order_hash": 7, "samples": 6,
             "p50_ns": 10, "p99_ns": 20, "p999_ns": 30}]}
        validate(good, w, 4, 6, 100)
        for field, value in (("count", 9), ("checksum", 44), ("samples", 5), ("p99_ns", 1)):
            bad = copy.deepcopy(good)
            bad["consumers"][0][field] = value
            with self.assertRaises(ValueError):
                validate(bad, w, 4, 6, 100)
        bad = copy.deepcopy(good)
        bad["consumers"].append(bad["consumers"][0])
        with self.assertRaises(ValueError):
            validate(bad, w, 4, 6, 100)

    def test_conservative_comparison(self) -> None:
        self.assertEqual(compare([4, 5, 6], [1, 2, 3], True)["verdict"], "win")
        self.assertEqual(compare([4, 5, 6], [1, 2, 3], False)["verdict"], "loss")
        self.assertEqual(compare([1, 5, 8], [2, 3, 4], True)["verdict"], "inconclusive")
        self.assertEqual(compare([4], [1], True)["verdict"], "inconclusive")
        self.assertEqual(stats([1, 2, 3])["median"], 2)
        good = {"valid": True, "elapsed_ns": 1_000_000_000, "warm_elapsed_ns": 2_000_000_000}
        self.assertTrue(quality([good] * 3, 3, False))
        for update in ({"valid": False}, {"elapsed_ns": 100}, {"jit_ms": 1}):
            self.assertFalse(quality([dict(good, **update)] * 3, 3, False))
        self.assertFalse(quality([good] * 3, 3, True))


class RunnerTests(unittest.TestCase):
    def test_zigrupt_batching_contract_is_required_before_recording_valid_samples(self) -> None:
        w = Workload(1, 1, 2048, 8)
        warm, count = 8192, 16384
        good = {"valid": True, "elapsed_ns": 100, "cpu_ns": 100,
                "max_batch_size": w.capacity, "blocked_publications": w.capacity,
                "consumers": [{"count": warm + count,
                               "checksum": expected_checksum(warm + count, w.payload),
                               "order_hash": 7, "max_observed_batch": w.capacity}]}
        cases = [("native batch", "check", good, True)]
        for mode in ("check", "throughput"):
            for limit in (None, 1, w.capacity // 2):
                bad = copy.deepcopy(good)
                bad["max_batch_size"] = limit
                cases.append((f"limit {limit}", mode, bad, False))
        for observed in (None, 0, 1, w.capacity + 1):
            bad = copy.deepcopy(good)
            if observed is None:
                del bad["consumers"][0]["max_observed_batch"]
            else:
                bad["consumers"][0]["max_observed_batch"] = observed
            cases.append((f"observed {observed}", "check", bad, False))
        measured = copy.deepcopy(good)
        del measured["consumers"][0]["max_observed_batch"]
        cases.append(("no measured batch counter", "throughput", measured, True))
        for label, mode, result, valid in cases:
            with self.subTest(case=label, mode=mode), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                runner = Runner(output, [0, 1], argparse.Namespace(timeout=1, cooldown=0))
                process = subprocess.CompletedProcess([], 0, json.dumps(result), "")
                with patch("run.subprocess.run", return_value=process), patch("run.time.sleep"):
                    record = runner.sample("zigrupt", w, mode, 0, warm, count)
                self.assertEqual(record["valid"], valid)
                saved = json.loads((output / "runs.jsonl").read_text())
                self.assertEqual(saved["valid"], valid)
                if not valid:
                    self.assertIn("error", saved)


class RssTests(unittest.TestCase):
    def test_peak_rss_excludes_launcher_memory_before_exec(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            probe = str(Path(temporary) / "rss-probe")
            subprocess.run(["gcc", "-O2", str(ROOT / "platform.c"),
                            str(ROOT / "tests/rss_probe.c"), "-o", probe], check=True,
                           capture_output=True)
            # Force fork, inflate the launcher, then exec a tiny C program.
            # getrusage's lifetime high-water mark incorrectly includes this memory.
            held = bytearray(64 * 1024 * 1024)
            result = subprocess.check_output([probe], text=True, preexec_fn=lambda: None)
            self.assertLess(int(result), len(held) // 2)


@unittest.skipUnless((BIN / "build.json").exists(), "build adapters first")
class AdapterTests(unittest.TestCase):
    def test_zigrupt_batches_across_wraps_and_partial_phase_boundaries(self) -> None:
        allowed = sorted(os.sched_getaffinity(0))
        for w in workloads():
            with self.subTest(workload=w.key):
                cpus = [allowed[i % len(allowed)] for i in range(w.producers + w.consumers)]
                # Non-ring-aligned phase boundaries exercise short final batches.
                # The held consumer leaves a backlog, proving actual batch delivery
                # without relying on performance or scheduler-speed assertions.
                warm = rounded(w.capacity * 4 + 5, w.producers)
                count = rounded(w.capacity * 8 + 7, w.producers)
                process = subprocess.run(command("zigrupt", w, warm, count, 0, True, cpus),
                                         check=True, text=True, capture_output=True, timeout=45)
                result = json.loads(process.stdout)
                validate(result, w, warm, count, 0)
                self.assertEqual(result["max_batch_size"], w.capacity)
                self.assertEqual(result["blocked_publications"], w.capacity)
                for consumer in result["consumers"]:
                    self.assertGreaterEqual(consumer["max_observed_batch"], 1)
                    self.assertLessEqual(consumer["max_observed_batch"], w.capacity)
                self.assertGreater(result["consumers"][-1]["max_observed_batch"], 1)

    def test_backpressure_is_in_latency_and_all_consumers_complete(self) -> None:
        # A held consumer must create a visible latency tail. A schedule reset
        # after the stall would hide most of this backlog (coordinated omission).
        allowed = sorted(os.sched_getaffinity(0))
        for consumers in (1, 3):
            w = Workload(1, consumers, 2048, 64)
            cpus = [allowed[i % len(allowed)] for i in range(1 + consumers)]
            for impl in w.implementations:
                with self.subTest(implementation=impl, consumers=consumers):
                    warm, count, rate = 8192, 16384, 1_000_000
                    process = subprocess.run(command(impl, w, warm, count, rate, True, cpus),
                                             check=True, text=True, capture_output=True, timeout=45)
                    result = json.loads(process.stdout)
                    validate(result, w, warm, count, rate)
                    self.assertEqual(result["blocked_publications"], w.capacity + (impl == "ziggy"))
                    if impl == "zigrupt":
                        self.assertEqual(result["max_batch_size"], w.capacity)
                        self.assertGreater(result["consumers"][-1]["max_observed_batch"], 1)
                    self.assertGreater(result["consumers"][-1]["p99_ns"], 20_000_000)
                    self.assertEqual(result["consumers"][-1]["samples"], count)


if __name__ == "__main__":
    unittest.main()
