"""Tests for the benchmark runner's startup runtime estimate."""

from __future__ import annotations

import argparse
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run as benchmark_run


def arguments(**overrides: object) -> argparse.Namespace:
    values = {
        "check_only": False,
        "smoke": False,
        "repeats": 5,
        "seconds": 2.0,
        "warm_seconds": 3.0,
        "cooldown": 0.25,
    }
    return argparse.Namespace(**(values | overrides))


def jobs(cases: list[str], standalone: bool = False) -> list[tuple[benchmark_run.Workload, str]]:
    implementations = (
        benchmark_run.IMPLEMENTATIONS[:1]
        if standalone
        else benchmark_run.IMPLEMENTATIONS
    )
    return [(w, impl) for w in benchmark_run.workloads(cases) for impl in implementations]


class RuntimeEstimateTests(unittest.TestCase):
    def test_default_includes_all_implementations_and_latency_fractions(self) -> None:
        selected = jobs(list(benchmark_run.CASES))
        self.assertEqual(len(selected), 72)
        self.assertEqual(
            benchmark_run.estimated_runtime(arguments(), selected, 6),
            72 * (2 * 1.25 + 5 * 7 * 5.25),
        )

    def test_standalone_is_one_third_of_full_suite(self) -> None:
        cases = list(benchmark_run.CASES)
        full = benchmark_run.estimated_runtime(arguments(), jobs(cases), 6)
        standalone = benchmark_run.estimated_runtime(arguments(), jobs(cases, True), 6)
        self.assertEqual(standalone * 3, full)

    def test_core_blocked_jobs_still_have_correctness_checks(self) -> None:
        selected = jobs(["1p1c", "3p3c"], True)
        self.assertEqual(
            benchmark_run.estimated_runtime(arguments(), selected, 2),
            8 * 1.25 + 4 * (1.25 + 5 * 7 * 5.25),
        )

    def test_check_only_ignores_measurement_settings_and_core_limit(self) -> None:
        self.assertEqual(
            benchmark_run.estimated_runtime(
                arguments(check_only=True), jobs(["3p3c"], True), 2
            ),
            4 * 1.25,
        )

    def test_custom_targets_repeats_and_cooldown(self) -> None:
        self.assertEqual(
            benchmark_run.estimated_runtime(
                arguments(repeats=3, seconds=4, warm_seconds=1, cooldown=0),
                jobs(["1p1c"], True),
                2,
            ),
            4 * (2 + 3 * 7 * 5),
        )

    def test_smoke_uses_short_targets(self) -> None:
        self.assertAlmostEqual(
            benchmark_run.estimated_runtime(
                arguments(smoke=True), jobs(["1p1c"], True), 2
            ),
            4 * (2 * 1.25 + 5 * 7 * 0.31),
        )

    def test_repeated_cases_are_not_counted_twice(self) -> None:
        self.assertEqual(jobs(["1p1c", "1p1c"]), jobs(["1p1c"]))

    def test_duration_formatting_rounds_up(self) -> None:
        for seconds, expected in (
            (0, "0s"),
            (0.1, "1s"),
            (59.1, "1m 0s"),
            (61, "1m 1s"),
            (3601, "1h 0m 1s"),
        ):
            with self.subTest(seconds=seconds):
                self.assertEqual(benchmark_run.format_duration(seconds), expected)

    def test_estimate_printed_before_build_and_samples(self) -> None:
        def build(*, standalone: bool) -> None:
            self.assertTrue(standalone)
            print("BUILD STARTED")

        def sample(*args: object, **kwargs: object) -> dict[str, bool]:
            print("SAMPLE STARTED")
            return {"valid": True}

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "results"
            captured = io.StringIO()
            with (
                patch("sys.argv", [
                    "run.py", "--standalone", "--check-only", "--case", "1p1c",
                    "--output", str(output),
                ]),
                patch.object(benchmark_run, "cpu_topology", return_value=[]),
                patch.object(benchmark_run, "physical_cpus", return_value=[0, 1]),
                patch.object(benchmark_run, "build_issue", side_effect=["missing", None]),
                patch.object(benchmark_run.benchmark_build, "main", side_effect=build),
                patch.object(benchmark_run.Runner, "sample", side_effect=sample) as samples,
                contextlib.redirect_stdout(captured),
            ):
                benchmark_run.main()
            text = captured.getvalue()
            self.assertEqual(text.splitlines()[0], "Approximate benchmark runtime: 5s")
            self.assertTrue(text.splitlines()[1].startswith("Building benchmarks"))
            self.assertLess(text.index("Approximate benchmark runtime"), text.index("BUILD STARTED"))
            self.assertLess(text.index("Approximate benchmark runtime"), text.index("SAMPLE STARTED"))
            self.assertEqual(samples.call_count, 4)


if __name__ == "__main__":
    unittest.main()
