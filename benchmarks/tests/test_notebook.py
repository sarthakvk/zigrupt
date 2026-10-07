"""Notebook checks; plotting tests use the optional notebook dependencies."""
from __future__ import annotations

from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from typing import Any
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NOTEBOOK = ROOT / "visualize.ipynb"
BASELINE = ROOT / "results/baseline"


def code_cells() -> dict[str, str]:
    notebook = json.loads(NOTEBOOK.read_text())
    return {cell["id"]: "".join(cell["source"]) for cell in notebook["cells"] if cell["cell_type"] == "code"}


class NotebookFormatTests(unittest.TestCase):
    def test_cells_compile_and_outputs_are_clear(self) -> None:
        notebook = json.loads(NOTEBOOK.read_text())
        self.assertEqual(notebook["nbformat"], 4)
        for cell in notebook["cells"]:
            if cell["cell_type"] == "code":
                compile("".join(cell["source"]), f"{NOTEBOOK}:{cell['id']}", "exec")
                self.assertIsNone(cell["execution_count"])
                self.assertEqual(cell["outputs"], [])


@unittest.skipUnless(importlib.util.find_spec("matplotlib"), "install notebook-requirements.txt for plotting tests")
@unittest.skipUnless((BASELINE / "summary.json").exists(), "no recorded baseline")
class NotebookPlotTests(unittest.TestCase):
    def execute_notebook(self, **settings: Any) -> tuple[dict[str, Any], list[Any], str]:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        cells = code_cells()
        namespace: dict[str, Any] = {}
        figures: list[Any] = []
        output = io.StringIO()
        exec(cells["settings"], namespace)
        namespace.update({"BENCH_DIR": BASELINE, **settings})
        with redirect_stdout(output), patch.object(plt, "show", side_effect=lambda: figures.append(plt.gcf())):
            for name, source in cells.items():
                if name != "settings":
                    exec(compile(source, f"{NOTEBOOK}:{name}", "exec"), namespace)
        return namespace, figures, output.getvalue()

    def test_baseline_charts_use_reported_medians_ranges_and_quality(self) -> None:
        namespace, figures, output = self.execute_notebook()
        self.assertEqual(len(figures), 5)
        self.assertIn("blocked", output)
        ax = figures[0].axes[0]
        self.assertEqual(len(ax.containers), len(namespace["throughput"]))
        for row, container in zip(namespace["throughput"], ax.containers):
            line, _, whiskers = container.lines
            stat = row["events_per_second"]
            self.assertAlmostEqual(line.get_xdata()[0], stat["median"] / 1e6)
            segment = whiskers[0].get_segments()[0]
            self.assertAlmostEqual(segment[0][0], stat["min"] / 1e6)
            self.assertAlmostEqual(segment[1][0], stat["max"] / 1e6)
            self.assertEqual(line.get_markerfacecolor() == "white", not row["rankable"])
        # Worst-consumer summaries must not be reconstructed from consumer medians.
        latency_row = namespace["latency"][0]
        self.assertIs(namespace["metric_stats"](latency_row, "p99_ns"), latency_row["worst"]["p99_ns"])
        # Exercise the actual renderer, including layout and logarithmic axes.
        for figure in figures:
            figure.canvas.draw()

    def test_shapes_legends_and_spacing_do_not_depend_on_color(self) -> None:
        namespace, figures, _ = self.execute_notebook(WORKLOADS=["1p1c-2048-64b"])
        markers = namespace["MARKERS"]
        self.assertEqual(len(set(markers.values())), 4)
        self.assertTrue(all(marker != "o" for marker in markers.values()))
        for figure in figures:
            legend = figure.legends[0]
            labels = [text.get_text() for text in legend.get_texts()]
            self.assertIn("Filled: rankable", labels)
            self.assertIn("Hollow: unranked", labels)
            for name, handle in zip(namespace["implementations"], legend.legend_handles):
                self.assertEqual(handle.get_marker(), markers[name])
                self.assertGreaterEqual(handle.get_markersize(), 10)
            for ax in figure.axes:
                self.assertTrue(ax.patches, "workload bands should be visible")
                for container in ax.containers:
                    line = container.lines[0]
                    name = next(name for name, color in namespace["COLORS"].items()
                                if color == line.get_color())
                    self.assertEqual(line.get_marker(), markers[name])
                    self.assertGreaterEqual(line.get_markersize(), 10)
                    self.assertGreaterEqual(line.get_markeredgewidth(), 1.5)
            figure.canvas.draw()
            # Large markers must remain separated even in a one-workload selection.
            ax = figure.axes[0]
            centers = sorted(ax.transData.transform((0, c.lines[0].get_ydata()[0]))[1]
                             for c in ax.containers)
            marker_pixels = namespace["MARKER_SIZE"] * figure.dpi / 72
            self.assertTrue(all(b - a > marker_pixels for a, b in zip(centers, centers[1:])))

    def test_filters_and_individual_consumer(self) -> None:
        namespace, figures, _ = self.execute_notebook(
            WORKLOADS=["1p3c-2048-64b"], IMPLEMENTATIONS=["zigrupt"], LATENCY_CONSUMER=2,
        )
        self.assertEqual(len(namespace["rows"]), 3)
        row = namespace["latency"][0]
        self.assertIs(namespace["metric_stats"](row, "p99_ns"), row["consumers"][2]["p99_ns"])
        self.assertEqual(len(figures[0].axes[0].containers), 1)

    def test_missing_consumer_does_not_become_zero(self) -> None:
        _, figures, _ = self.execute_notebook(WORKLOADS=["1p1c-2048-64b"], LATENCY_CONSUMER=2)
        self.assertTrue(all(not ax.containers for figure in figures[1:3] for ax in figure.axes))

    def test_empty_measurements(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "manifest.json").write_bytes((BASELINE / "manifest.json").read_bytes())
            (directory / "summary.json").write_text('{"measurements": [], "comparisons": []}')
            (directory / "runs.jsonl").write_text("")
            namespace, figures, output = self.execute_notebook(BENCH_DIR=directory)
        self.assertEqual(namespace["rows"], [])
        self.assertIn("No measurements", output)
        self.assertTrue(all(not ax.containers for figure in figures for ax in figure.axes))

    def test_smoke_results_stay_unranked(self) -> None:
        smoke = next(ROOT.glob("results/smoke*/summary.json"), None)
        if smoke is None:
            self.skipTest("no recorded smoke run")
        namespace, figures, output = self.execute_notebook(BENCH_DIR=smoke.parent)
        self.assertIn("SMOKE TEST", output)
        self.assertTrue(all(not row["rankable"] for row in namespace["rows"]))
        self.assertTrue(all(container.lines[0].get_markerfacecolor() == "white"
                            for figure in figures for ax in figure.axes for container in ax.containers))

    def test_missing_summary_and_unknown_filter_are_actionable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(FileNotFoundError, "python report.py"):
                self.execute_notebook(BENCH_DIR=Path(temporary))
        with self.assertRaisesRegex(ValueError, "Unknown workload"):
            self.execute_notebook(WORKLOADS=["typo"])


if __name__ == "__main__":
    unittest.main()
