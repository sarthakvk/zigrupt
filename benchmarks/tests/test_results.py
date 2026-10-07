from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import shutil
import statistics
import tempfile
import unittest

from build import ROOT
from report import report
from run import validate, workloads

BASELINE = ROOT / "results/baseline"


@unittest.skipUnless((BASELINE / "summary.json").exists(), "no recorded baseline")
class ResultTests(unittest.TestCase):
    def test_complete_matrix_validity_placement_and_common_rates(self) -> None:
        manifest = json.loads((BASELINE / "manifest.json").read_text())
        records = [json.loads(line) for line in (BASELINE / "runs.jsonl").read_text().splitlines()]
        rates = json.loads((BASELINE / "rates.json").read_text())
        physical = manifest["physical_cpus"]
        repeats = manifest["settings"]["repeats"]
        matrix = {w.key: w for w in workloads()}
        counts = Counter((r["workload"], r["implementation"], r["mode"], r.get("fraction")) for r in records)
        for w in matrix.values():
            eligible = w.producers + w.consumers <= len(physical)
            for impl in w.implementations:
                self.assertEqual(counts[w.key, impl, "check", None], 1)
                self.assertEqual(counts[w.key, impl, "throughput", None], repeats if eligible else 0)
                self.assertEqual(counts[w.key, impl, "blocked", None], 0 if eligible else 1)
                for fraction in (0.5, 0.9):
                    self.assertEqual(counts[w.key, impl, "latency", fraction], repeats if eligible else 0)
            if eligible:
                medians = {impl: statistics.median(r["events_per_second"] for r in records
                           if r["workload"] == w.key and r["implementation"] == impl and r["mode"] == "throughput")
                           for impl in w.implementations}
                self.assertEqual(rates[w.key]["saturation_medians"], medians)
                for fraction in (0.5, 0.9):
                    self.assertEqual(rates[w.key]["rates"][str(fraction)], int(min(medians.values()) * fraction))
        for row in records:
            if row["mode"] == "blocked":
                continue
            w = matrix[row["workload"]]
            validate(row, w, row["warm_events"], row["events"], row["offered_rate"])
            self.assertGreater(row["peak_rss_bytes"], 0)
            if row["mode"] == "check":
                self.assertEqual(row["blocked_publications"], w.capacity + (row["implementation"] == "ziggy"))
            else:
                self.assertEqual(row["cpus"], physical[:w.producers + w.consumers])
            if row["mode"] == "latency":
                self.assertEqual(row["offered_rate"], rates[w.key]["rates"][str(row["fraction"])])

    def test_report_is_reproducible_from_raw_data(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            for name in ("manifest.json", "runs.jsonl"):
                shutil.copy2(BASELINE / name, output / name)
            report(output)
            for name in ("REPORT.md", "summary.json", "summary.csv", "throughput.svg"):
                self.assertEqual((BASELINE / name).read_bytes(), (output / name).read_bytes(), name)


if __name__ == "__main__":
    unittest.main()
