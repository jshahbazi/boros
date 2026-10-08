#!/usr/bin/env python3
"""Synthetic contracts for the retrieval recall floor comparison and skip logic.

No dataset, tokenizer, model, private history or harness run is used; harness
reports are built in memory from invented counts.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import retrieval_floor as floor_module  # noqa: E402

HASH = "a" * 64


def floor(**arms):
    return {"cohort": "regression", "manifest_sha256": HASH, "eligible_cases": 12, "eligible_turns": 18,
            "arms": {name: dict(zip(floor_module.MEASURES, values)) for name, values in arms.items()}}


def report(manifest=HASH, cases=12, turns=18, **arms):
    """Arm -> (r1_cases, r2_cases, r1_turns, r2_turns), shaped like a harness report."""
    return {"cohort": {"manifest_sha256": manifest}, "summary": {"arms": {
        name: {"r1_candidate_recall": {"passed": v[0], "cases": cases},
               "r2_delivered_recall": {"passed": v[1], "cases": cases},
               "turn_candidate": {"passed": v[2], "cases": turns},
               "turn_delivered_whole": {"passed": v[3], "cases": turns}} for name, v in arms.items()}}}


FLOOR = floor(hybrid=(8, 8, 14, 14), lexical=(9, 9, 15, 15))


def check(run_report, committed=FLOOR):
    return floor_module.compare(committed, floor_module.measured(run_report))


class Comparison(unittest.TestCase):
    def test_equal_run_passes(self):
        checks, failed, notes = check(report(hybrid=(8, 8, 14, 14), lexical=(9, 9, 15, 15)))
        self.assertEqual((failed, notes), ([], []))
        self.assertEqual(checks, 1 + 2 * (2 + 4))

    def test_improvement_passes(self):
        self.assertEqual(check(report(hybrid=(10, 10, 16, 16), lexical=(9, 9, 15, 15)))[1], [])

    def test_lower_case_recall_fails_by_name(self):
        _, failed, _ = check(report(hybrid=(8, 7, 14, 14), lexical=(9, 9, 15, 15)))
        self.assertEqual(failed, ["hybrid.r2_cases"])

    def test_lower_turn_recall_and_lower_r1_fail(self):
        _, failed, _ = check(report(hybrid=(7, 8, 13, 14), lexical=(9, 9, 15, 15)))
        self.assertEqual(sorted(failed), ["hybrid.r1_cases", "hybrid.r1_turns"])

    def test_arm_in_floor_but_missing_from_run_fails(self):
        _, failed, _ = check(report(hybrid=(8, 8, 14, 14)))
        self.assertEqual(failed, ["lexical.missing_arm"])

    def test_arm_in_run_but_not_in_floor_is_reported_not_failed(self):
        _, failed, notes = check(report(hybrid=(8, 8, 14, 14), lexical=(9, 9, 15, 15), semantic_only=(5, 4, 9, 8)))
        self.assertEqual(failed, [])
        self.assertEqual(len(notes), 1)
        self.assertIn("semantic_only", notes[0])
        self.assertIn("not failed", notes[0])

    def test_manifest_hash_change_fails(self):
        _, failed, _ = check(report(manifest="b" * 64, hybrid=(8, 8, 14, 14), lexical=(9, 9, 15, 15)))
        self.assertEqual(failed, ["manifest_sha256"])

    def test_denominator_change_fails_instead_of_comparing_counts(self):
        _, failed, _ = check(report(cases=11, hybrid=(8, 8, 14, 14), lexical=(9, 9, 15, 15)))
        self.assertEqual(sorted(failed), ["hybrid.eligible_cases", "lexical.eligible_cases"])

    def test_malformed_report_is_an_error_not_a_pass(self):
        with self.assertRaises(floor_module.FloorError):
            floor_module.measured({"summary": {"arms": {"hybrid": {}}}, "cohort": {"manifest_sha256": HASH}})
        with self.assertRaises(floor_module.FloorError):
            floor_module.measured({})


class FloorFile(unittest.TestCase):
    def write(self, value):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        handle.write(value if isinstance(value, str) else json.dumps(value))
        handle.close()
        self.addCleanup(Path(handle.name).unlink)
        return Path(handle.name)

    def test_valid_floor_loads(self):
        self.assertEqual(floor_module.load_floor(self.write(FLOOR)), FLOOR)

    def test_invalid_floors_are_rejected(self):
        broken_arm = floor(hybrid=(8, 8, 14, 14))
        broken_arm["arms"]["hybrid"].pop("r2_turns")
        negative = floor(hybrid=(8, 8, 14, -1))
        for value in ("not json", {}, {**FLOOR, "arms": {}}, broken_arm, negative):
            with self.assertRaises(floor_module.FloorError):
                floor_module.load_floor(self.write(value))
        with self.assertRaises(floor_module.FloorError):
            floor_module.load_floor(Path("/nonexistent/floor.json"))

    def test_committed_floor_is_numbers_and_one_hash_only(self):
        committed = floor_module.load_floor(floor_module.FLOOR_PATH)
        self.assertEqual(set(committed), {"cohort", "manifest_sha256", "eligible_cases", "eligible_turns", "arms"})
        self.assertEqual(len(committed["manifest_sha256"]), 64)

    def test_update_cannot_lower_without_permission(self):
        run = floor_module.measured(report(hybrid=(8, 7, 14, 14), lexical=(9, 9, 15, 15)))
        self.assertEqual(floor_module.lowered(FLOOR, floor_module.floor_from_run(run)), ["hybrid.r2_cases"])
        better = floor_module.measured(report(hybrid=(9, 9, 15, 15), lexical=(9, 9, 15, 15)))
        self.assertEqual(floor_module.lowered(FLOOR, floor_module.floor_from_run(better)), [])


class Availability(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: [p.unlink() for p in self.directory.iterdir()] or self.directory.rmdir())
        self.dataset = self.directory / "data.json"
        self.tokenizer = self.directory / "tokenizer.json"
        self.tokenizer.write_bytes(b"synthetic")
        self.sha = hashlib.sha256(b"synthetic").hexdigest()

    def reason(self, dataset=True, sha=None, importable=True):
        if dataset:
            self.dataset.write_text("{}")
        return floor_module.unavailable_reason(self.dataset, self.tokenizer, sha or self.sha, importable)

    def test_all_inputs_present_runs(self):
        self.assertIsNone(self.reason())

    def test_missing_dataset_skips_with_one_line_reason(self):
        reason = self.reason(dataset=False)
        self.assertIn("dataset", reason)
        self.assertNotIn("\n", reason)

    def test_missing_tokenizer_skips(self):
        self.tokenizer.unlink()
        self.assertIn("tokenizer", self.reason())

    def test_wrong_tokenizer_digest_skips(self):
        self.assertIn("SHA-256", self.reason(sha="0" * 64))

    def test_missing_tokenizers_package_skips(self):
        self.assertIn("tokenizers", self.reason(importable=False))


class Main(unittest.TestCase):
    def run_main(self, argv=(), reason=None, harness_report=None, committed=FLOOR):
        directory = tempfile.mkdtemp()
        floor_path = Path(directory) / "floor.json"
        floor_path.write_text(json.dumps(committed))
        out = io.StringIO()
        runner = patch.object(floor_module, "run_harness", return_value=harness_report) if harness_report else \
            patch.object(floor_module, "run_harness", side_effect=AssertionError("harness must not run"))
        with contextlib.redirect_stdout(out), patch.object(floor_module, "unavailable_reason", return_value=reason), runner:
            code = floor_module.main(["--floor", str(floor_path), *argv])
        floor_path.unlink()
        Path(directory).rmdir()
        return code, json.loads(out.getvalue())

    def test_skip_exits_zero_without_running_harness_and_is_not_a_pass(self):
        code, result = self.run_main(reason="pinned dataset not found")
        self.assertEqual(code, 0)
        self.assertEqual((result["status"], result["checks"], result["skipped"]), ("skipped", 0, 1))
        self.assertEqual(result["skip_reason"], "pinned dataset not found")

    def test_passing_run_reports_checks(self):
        code, result = self.run_main(harness_report=report(hybrid=(8, 8, 14, 14), lexical=(9, 9, 15, 15)))
        self.assertEqual((code, result["status"], result["failed"]), (0, "passed", []))
        self.assertGreater(result["checks"], 0)

    def test_regression_exits_nonzero(self):
        code, result = self.run_main(harness_report=report(hybrid=(8, 8, 14, 13), lexical=(9, 9, 15, 15)))
        self.assertEqual((code, result["status"], result["failed"]), (1, "failed", ["hybrid.r2_turns"]))

    def test_harness_failure_exits_nonzero_instead_of_skipping(self):
        directory = tempfile.mkdtemp()
        floor_path = Path(directory) / "floor.json"
        floor_path.write_text(json.dumps(FLOOR))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), patch.object(floor_module, "unavailable_reason", return_value=None), \
                patch.object(floor_module, "run_harness", side_effect=floor_module.FloorError("harness exited 1")):
            code = floor_module.main(["--floor", str(floor_path)])
        floor_path.unlink()
        Path(directory).rmdir()
        result = json.loads(out.getvalue())
        self.assertEqual((code, result["status"]), (1, "error"))
        self.assertEqual(result["skipped"], 0)


if __name__ == "__main__":
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case)
                               for case in (Comparison, FloorFile, Availability, Main))
    result = unittest.TextTestRunner(stream=io.StringIO()).run(suite)
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
