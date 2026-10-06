#!/usr/bin/env python3
"""Content-suppressed independent-cohort runner contracts; no provider calls."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import evaluate_answers as evidence
import evaluate_longmemeval as baseline
import evaluate_longmemeval_independent as cli
import longmemeval_independent_cases as cohort
from test_longmemeval_evaluation import synthetic_histories, native_report

CONFIGURATION = {**baseline.CONFIGURATION, "maximum_output": 1024}


def histories():
    result = []
    for index, (qid, kind) in enumerate(zip(cohort.CASE_IDS, cohort.CASE_TYPES)):
        history = copy.deepcopy(synthetic_histories()[0])
        history["id"] = qid
        probe = history["episodes"][0]
        probe.update(id=qid, question_id=qid, question_type=kind, abstention=qid.endswith("_abs"))
        result.append(history)
    return result


class Contracts(unittest.TestCase):
    def setUp(self):
        self.histories = histories()
        self.history = self.histories[0]
        self.document = cohort.runner_input(self.history, CONFIGURATION)

    def test_version_seven_uses_own_configuration_and_preserves_pilot_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"
            with patch.object(baseline, "CONFIGURATION", CONFIGURATION):
                native = native_report(self.history, self.document, directory)
            attempts, predictions = baseline.score_native(native, directory, self.history, self.document,
                configuration=CONFIGURATION, runner_document_version=7)
            self.assertEqual(len(attempts), 2)
            self.assertTrue(all(a["operational_complete"] for a in attempts))
            self.assertEqual([p["strategy"] for p in predictions], list(evidence.STRATEGIES))
            with self.assertRaises(evidence.EvaluationError):
                baseline.score_native(native, directory, self.history, self.document)
            with self.assertRaises(evidence.EvaluationError):
                baseline.score_native(native, directory, self.history, self.document,
                    configuration=baseline.CONFIGURATION, runner_document_version=7)

    def test_separate_configuration_receipt_mismatch_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"
            native = native_report(self.history, self.document, directory)
            # The declared native config is correct; the receipts still reserve 512.
            native["native_configuration_sha256"] = baseline.native_configuration_sha256(CONFIGURATION)
            with self.assertRaises(evidence.EvaluationError):
                baseline.score_native(native, directory, self.history, self.document,
                    configuration=CONFIGURATION, runner_document_version=7)

    def test_unavailable_native_rows_retain_both_denominators_and_empty_exports(self):
        attempts, predictions = baseline.score_native({"version": 1, "attempts": []}, Path("unused"),
            self.history, self.document, configuration=CONFIGURATION, runner_document_version=7)
        self.assertEqual(len(attempts), 2)
        self.assertTrue(all(not a["operational_complete"] and a["failure_code"] == "native_attempt_unavailable" for a in attempts))
        self.assertTrue(all(p["hypothesis"] == "" for p in predictions))

    def run_fixture(self, root, *, fail_first=False, mutate_code=False):
        binary = root / "synthetic-binary"
        binary.write_bytes(b"synthetic binary")
        by_id = {h["id"]: h for h in self.histories}
        inventory = {"synthetic.py": "a" * 64}
        started = []
        private = root / "hypotheses"

        def execute(_binary, input_path, directory, timeout):
            declaration = evidence.strict_json((private / "declaration.json").read_bytes())
            self.assertEqual(declaration["declared_attempts"], 28)
            self.assertEqual(declaration["runner_document_version"], 7)
            self.assertEqual(declaration["cohort"], "independent-v1")
            self.assertEqual(declaration["selection_manifest"], {"fixture_manifest": True})
            document = evidence.strict_json(input_path.read_bytes())
            self.assertEqual(document["configuration"]["maximum_output"], 1024)
            self.assertTrue(all("evidence_source_ids" not in row for row in document["attempts"]))
            started.append(document["history_id"])
            if fail_first and len(started) == 1:
                raise ValueError("private failure sentinel")
            with patch.object(baseline, "CONFIGURATION", CONFIGURATION):
                result = native_report(by_id[document["history_id"]], document, directory)
            if mutate_code:
                inventory["synthetic.py"] = "b" * 64
            return result

        patches = [patch.object(cohort, "prepare_with_manifest", return_value=(self.histories, {"fixture_manifest": True})),
            patch.object(baseline, "code_inventory", side_effect=lambda: dict(inventory)),
            patch.object(baseline, "freeze_code"),
            patch.object(baseline, "verified_driver", return_value=(binary, {"binary_sha256": evidence.digest(binary.read_bytes())})),
            patch.object(evidence, "execute", side_effect=execute)]
        with contextlib.ExitStack() as stack:
            for selected in patches:
                stack.enter_context(selected)
            report = baseline.run(root / "private-source", root / "report.json", private,
                binary=binary, binary_verification=root / "proof.json", cohort="independent-v1")
        return report, started, private

    def test_end_to_end_predeclares_twenty_eight_and_preserves_failed_case(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, started, private = self.run_fixture(Path(temporary), fail_first=True)
            self.assertEqual(started, list(cohort.CASE_IDS))
            self.assertEqual(report["longmemeval_evaluation_version"], 2)
            self.assertEqual(report["declaration"]["declared_attempts"], 28)
            attempts = [a for h in report["histories"] for a in h["attempts"]]
            self.assertEqual(len(attempts), 28)
            self.assertEqual(sum(a["operational_complete"] for a in attempts), 26)
            self.assertIsNone(report["official_qa_score"])
            self.assertEqual(report["configuration"]["maximum_output"], 1024)
            for strategy in evidence.STRATEGIES:
                rows = [evidence.strict_json(line) for line in (private / (strategy + ".jsonl")).read_bytes().splitlines()]
                self.assertEqual([r["question_id"] for r in rows], list(cohort.CASE_IDS))
                self.assertEqual(rows[0]["hypothesis"], "")
                self.assertEqual(report["private_hypothesis_exports"][strategy]["records"], 14)
            public = evidence.canonical_json(report)
            for value in ("private original query sentinel", "private oracle answer sentinel", "private failure sentinel",
                          "private generated natural answer sentinel", self.history["events"][0]["text"]):
                self.assertNotIn(value.encode(), public)

    def test_code_drift_stops_before_remaining_cases(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(evidence.EvaluationError):
                self.run_fixture(Path(temporary), mutate_code=True)
            self.assertFalse((Path(temporary) / "report.json").exists())

    def test_independent_run_requires_verified_binary_and_refuses_unknown_cohort(self):
        for selected in ("independent-v1", "unknown"):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with patch.object(evidence, "execute") as transport, self.assertRaises(evidence.EvaluationError):
                    baseline.run(root / "unused", root / "report", root / "hypotheses", cohort=selected)
                self.assertFalse(transport.called)
                self.assertFalse((root / "hypotheses").exists())

    def test_case_order_mismatch_refused_before_declaration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(cohort, "prepare_with_manifest", return_value=(self.histories[::-1], {})), self.assertRaises(evidence.EvaluationError):
                baseline.run(root / "unused", root / "report", root / "hypotheses", binary=root / "binary",
                    binary_verification=root / "proof", cohort="independent-v1")
            self.assertFalse((root / "hypotheses").exists())

    def test_colliding_report_hypothesis_destinations_refused_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for output, private in ((root / "same", root / "same"),
                    (root / "parent", root / "parent" / "private"),
                    (root / "private" / "declaration.json", root / "private")):
                with patch.object(evidence, "execute") as transport, self.assertRaises(evidence.EvaluationError):
                    baseline.run(root / "unused", output, private, binary=root / "binary",
                        binary_verification=root / "proof", cohort="independent-v1")
                self.assertFalse(transport.called)
                self.assertFalse(output.exists())
                self.assertFalse(private.exists())

    def test_runtime_report_refuses_tracked_source_and_symlink_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            (root / "Sources").mkdir()
            (root / ".build").mkdir()
            with self.assertRaises(evidence.EvaluationError):
                baseline._paths(root / "Sources" / "report.json", root / ".build" / "private")
            (root / "link").symlink_to(root / ".build")
            with self.assertRaises(evidence.EvaluationError):
                baseline._paths(root / "link" / "report.json", root / ".build" / "private")

    def test_cli_requires_explicit_execute_and_suppresses_private_values(self):
        args = []
        for name in ("source", "output", "hypotheses-directory", "binary", "binary-verification"):
            args.extend(["--" + name, "/PRIVATE-sentinel"])
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), patch.object(baseline, "run") as run:
            self.assertEqual(cli.main(args), 1)
        self.assertFalse(run.called)
        self.assertNotIn("PRIVATE", out.getvalue() + err.getvalue())


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [t.id() for t, _ in result.failures],
        "errors": [t.id() for t, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
