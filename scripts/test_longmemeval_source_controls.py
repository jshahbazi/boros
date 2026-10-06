#!/usr/bin/env python3
"""Portable source-control provenance, refusal and denominator contracts."""
from __future__ import annotations

import copy
import base64
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

import evaluate_answers as e
import evaluate_longmemeval as baseline
import evaluate_longmemeval_source_controls as runner
import longmemeval_source_controls as controls
from test_longmemeval_evaluation import native_report, synthetic_histories


def histories():
    rows = synthetic_histories()[:6]
    for history, case_id in zip(rows, controls.CASE_IDS):
        history["id"] = case_id
        history["episodes"][0].update(id=case_id, question_id=case_id)
    return rows


def source_ids(history):
    return [source["id"] for source in history["events"]]


def document(history):
    return controls.runner_input(history, runner.CONFIGURATION, source_ids(history))


def report(history, directory, doc=None):
    doc = doc or document(history)
    value = native_report(history, doc, directory)
    value["declared_attempts"] = value["completed_attempts"] = 1
    inventory = controls.source_inventory(history, doc["attempts"][0]["evidence_source_ids"])
    audit = value["attempts"][0]["preparation"]["context_audit"]
    audit["retrieval"] = {"mode": "declared_original_sources", "version": runner.OUTCOME_VERSION,
        "declared_source_count": len(inventory), "declared_source_bytes": sum(row["byte_length"] for row in inventory),
        "declared_source_ids_sha256": e.digest(e.canonical_json(doc["attempts"][0]["evidence_source_ids"])),
        "semantic_available": False}
    value["attempts"][0]["preparation"]["admission_audit"]["context"] = base64.b64encode(e.canonical_json(audit)).decode()
    value["attempts"][0]["source_control_validation"] = {
        "version": runner.OUTCOME_VERSION, "declared_source_count": len(inventory),
        "declared_source_bytes": sum(row["byte_length"] for row in inventory),
        "delivered_source_count": len(inventory), "complete_declared_sources_delivered": True,
        "source_body_count_revalidated": True, "input_proof_version": 3,
        "failure_code": None, "validation_milliseconds": 1.0}
    return value


class Contracts(unittest.TestCase):
    def setUp(self):
        self.histories = histories(); self.history = self.histories[0]
        self.ids = source_ids(self.history); self.doc = document(self.history)

    def test_input_preserves_full_source_array_original_question_and_separate_dates(self):
        prior = controls.cases.runner_input(self.history, runner.CONFIGURATION, version=5)
        self.assertEqual(self.doc["events"], prior["events"])
        self.assertEqual(self.doc["attempts"][0], {**prior["attempts"][1], "evidence_source_ids": self.ids})
        self.assertEqual(self.doc["version"], 6)
        self.assertEqual(self.doc["attempts"][0]["prompt"], self.history["episodes"][0]["prompt"])
        self.assertNotIn("source_labels", self.doc)
        for forbidden in ("answer", "answer_session_ids", "question_type", "has_answer", "abstention", "expected", "rubric"):
            self.assertNotIn(("\"" + forbidden + "\":").encode(), e.canonical_json(self.doc))

    def test_projection_covers_question_dates_sources_order_roles_and_selected_ids(self):
        frozen = controls.projection_sha256(self.doc)
        for mutate in (lambda d: d["events"].reverse(),
                lambda d: d["events"][0].__setitem__("text", "changed original"),
                lambda d: d["events"][0].__setitem__("role", "user" if d["events"][0]["role"] == "assistant" else "assistant"),
                lambda d: d["events"][0]["source_time"].__setitem__("original_value", "changed literal"),
                lambda d: d["attempts"][0]["question_time"].__setitem__("locator", "/different/question_date"),
                lambda d: d["attempts"][0].__setitem__("prompt", "changed question"),
                lambda d: d["attempts"][0]["evidence_source_ids"].reverse()):
            changed = copy.deepcopy(self.doc); mutate(changed)
            self.assertNotEqual(frozen, controls.projection_sha256(changed))
        changed = copy.deepcopy(self.doc); changed["configuration"]["seed"] += 1
        self.assertEqual(frozen, controls.projection_sha256(changed))
        self.assertNotEqual(baseline.native_configuration_sha256(self.doc["configuration"]), baseline.native_configuration_sha256(changed["configuration"]))

    def test_exact_frozen_native_pins_and_pack_bounds(self):
        self.assertEqual(tuple(controls.PROJECTION_PINS), controls.CASE_IDS)
        self.assertEqual(tuple(controls.PACK_INVENTORY_PINS), controls.CASE_IDS)
        self.assertEqual([len(controls.PACKS[qid]) for qid in controls.CASE_IDS], [16, 4, 6, 16, 12, 4])
        source = (e.ROOT / "Sources/Boros/AnswerEvaluationCommand.swift").read_text()
        match = re.search(r"completeSourceLongMemoryCorpusProjectionSHA256[^=]*=\s*\[(.*?)\]", source, re.S)
        self.assertIsNotNone(match)
        self.assertEqual(set(re.findall(r'"([0-9a-f]{64})"', match.group(1))), set(controls.PROJECTION_PINS.values()))

    def test_original_inventory_is_full_utf8_and_date_hashes_without_text(self):
        inventory = controls.source_inventory(self.history, self.ids)
        self.assertEqual([row["event_id"] for row in inventory], self.ids)
        for source, row in zip(self.history["events"], inventory):
            self.assertEqual(row["byte_length"], len(source["text"].encode()))
            self.assertEqual(row["sha256"], e.digest(source["text"].encode()))
            self.assertEqual(row["source_time_sha256"], e.digest(e.canonical_json(source["source_time"])))
            self.assertNotIn(source["text"], json.dumps(row))
            self.assertNotIn(source["source_time"]["original_value"], json.dumps(row))

    def test_control_source_refusal_duplicates_scope_order_missing_positive_and_size(self):
        for selected in ([], [self.ids[0], self.ids[0]], list(reversed(self.ids)), ["missing"], [self.ids[1]]):
            with self.assertRaises(e.EvaluationError): controls.source_inventory(self.history, selected)
        for mutation in (lambda h: h["events"][0].__setitem__("text", "x" * 4097),
                         lambda h: h["events"][0].__setitem__("text", ""),
                         lambda h: h["events"][0].__setitem__("project_id", "other")):
            changed = copy.deepcopy(self.history); mutation(changed)
            with self.assertRaises(e.EvaluationError): controls.source_inventory(changed, self.ids)
        absence = synthetic_histories()[-1]
        with self.assertRaises(e.EvaluationError): controls.runner_input(absence, runner.CONFIGURATION, source_ids(absence))

    def test_input_refuses_ordinary_paired_v5_unknown_fields_wrong_config_and_control_edits(self):
        for mutation in (lambda d: d.__setitem__("version", 5), lambda d: d.__setitem__("oracle", "forbidden"),
                         lambda d: d["attempts"][0].__setitem__("strategy", "recent_only"),
                         lambda d: d["attempts"][0].__setitem__("replicate", 1),
                         lambda d: d["attempts"].append(copy.deepcopy(d["attempts"][0])),
                         lambda d: d["configuration"].__setitem__("maximum_output", 1024)):
            changed = copy.deepcopy(self.doc); mutation(changed)
            with self.assertRaises(e.EvaluationError): controls.validate_document(self.history, changed, runner.CONFIGURATION, self.ids)

    def test_prepare_enforces_projection_and_inventory_pins(self):
        packs = {history["id"]: source_ids(history) for history in self.histories}
        projections = {history["id"]: controls.projection_sha256(document(history)) for history in self.histories}
        inventories = {history["id"]: e.digest(e.canonical_json(controls.source_inventory(history, source_ids(history)))) for history in self.histories}
        with patch.object(controls.cases, "prepare", return_value=self.histories), patch.object(controls, "PACKS", packs), \
             patch.object(controls, "PROJECTION_PINS", projections), patch.object(controls, "PACK_INVENTORY_PINS", inventories):
            self.assertEqual(controls.prepare(Path("unused")), self.histories)
            projections[self.histories[0]["id"]] = "0" * 64
            with self.assertRaises(e.EvaluationError): controls.prepare(Path("unused"))

    def test_wrong_answer_keeps_operational_and_full_delivery_without_semantic_claim(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; value = report(self.history, directory)
            row, prediction = runner.score_native(value, directory, self.history, self.doc, source_ids=self.ids)
            self.assertTrue(row["operational_complete"])
            self.assertTrue(row["full_pack_delivery_eligible"])
            self.assertIsNone(row["semantic_sufficiency"])
            self.assertIsNone(row["provider_token_feasibility"])
            self.assertIsNone(row["official_qa_score"])
            self.assertTrue(prediction["hypothesis"])
            self.assertNotIn(prediction["hypothesis"], json.dumps(row))

    def test_incomplete_transport_can_still_have_valid_full_delivery_but_empty_hypothesis(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; value = report(self.history, directory)
            value["attempts"][0].update(episode_state="failed", invocation_status="partial", failure="incomplete_result")
            row, prediction = runner.score_native(value, directory, self.history, self.doc, source_ids=self.ids)
            self.assertFalse(row["operational_complete"])
            self.assertTrue(row["full_pack_delivery_eligible"])
            self.assertEqual(prediction["hypothesis"], "")

    def test_token_reduction_retains_attempt_and_invalidates_complete_pack(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; value = report(self.history, directory); item = value["attempts"][0]
            # Remove the entire historical source and keep the ordinary recent
            # suffix. Update both identical context projections consistently.
            item["delivered_ranges"] = item["delivered_ranges"][1:]
            audit = item["preparation"]["context_audit"]; audit["historical_sources"] = []
            item["preparation"]["admission_audit"]["context"] = base64.b64encode(e.canonical_json(audit)).decode()
            item["source_control_validation"].update(delivered_source_count=2, complete_declared_sources_delivered=False,
                                                    failure_code="declared_sources_not_delivered")
            row, _ = runner.score_native(value, directory, self.history, self.doc, source_ids=self.ids)
            self.assertTrue(row["operational_complete"])
            self.assertFalse(row["full_pack_delivery_eligible"])
            self.assertEqual(runner.summarize([row])["declared_attempts"], 1)

    def test_delivery_union_closes_contiguous_ranges_and_rejects_gaps_utf8_and_digest(self):
        self.assertTrue(runner.union_complete({"x": [(3, 8), (0, 3)]}, "x", 8))
        self.assertFalse(runner.union_complete({"x": [(0, 2), (3, 8)]}, "x", 8))
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; value = report(self.history, directory)
            for mutation in (lambda i: i["source_control_validation"].__setitem__("delivered_source_count", True),
                             lambda i: i["source_control_validation"].__setitem__("complete_declared_sources_delivered", False),
                             lambda i: i["delivered_ranges"][0].__setitem__("sha256", "0" * 64),
                             lambda i: i["delivered_ranges"][0].__setitem__("offset", 1)):
                changed = copy.deepcopy(value); mutation(changed["attempts"][0])
                with self.assertRaises(e.EvaluationError): runner.score_native(changed, directory, self.history, self.doc, source_ids=self.ids)

    def test_native_input_configuration_and_count_body_links_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; value = report(self.history, directory)
            for mutation in (lambda d: d.__setitem__("public_projection_sha256", "0" * 64),
                             lambda d: d.__setitem__("native_configuration_sha256", "0" * 64),
                             lambda d: d["attempts"][0]["preparation"]["admission"].__setitem__("bodyDigest", "0" * 64),
                             lambda d: d["attempts"][0]["preparation"]["context_audit"].__setitem__("source_snapshot_sha256", "0" * 64)):
                changed = copy.deepcopy(value); mutation(changed)
                with self.assertRaises(e.EvaluationError): runner.score_native(changed, directory, self.history, self.doc, source_ids=self.ids)

    def test_nonterminal_cannot_claim_verified_delivery_or_expose_answer_ipc(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; value = report(self.history, directory)
            value["completed_attempts"] = 0; item = value["attempts"][0]; item["terminalized"] = False
            with self.assertRaises(e.EvaluationError): runner.score_native(value, directory, self.history, self.doc, source_ids=self.ids)
            item["source_control_validation"] = runner.unavailable_control(self.history, self.doc["attempts"][0])
            with patch.object(e, "read_file", side_effect=AssertionError("nonterminal IPC must not be read")):
                row, prediction = runner.score_native(value, directory, self.history, self.doc, source_ids=self.ids)
            self.assertFalse(row["full_pack_delivery_eligible"])
            self.assertEqual(prediction["hypothesis"], "")

    def test_declared_source_binding_required_even_when_generic_body_audit_still_agrees(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; value = report(self.history, directory)
            for field, invalid in (("mode", "recent_only"), ("version", "changed_control_version"),
                    ("declared_source_count", 2), ("declared_source_count", True),
                    ("declared_source_bytes", 1), ("declared_source_bytes", True),
                    ("declared_source_ids_sha256", "0" * 64), ("semantic_available", True),
                    ("semantic_available", 0)):
                changed = copy.deepcopy(value)
                audit = changed["attempts"][0]["preparation"]["context_audit"]
                audit["retrieval"][field] = invalid
                changed["attempts"][0]["preparation"]["admission_audit"]["context"] = base64.b64encode(e.canonical_json(audit)).decode()
                with self.assertRaises(e.EvaluationError): runner.score_native(changed, directory, self.history, self.doc, source_ids=self.ids)
            changed = copy.deepcopy(value)
            audit = changed["attempts"][0]["preparation"]["context_audit"]; audit.pop("retrieval")
            changed["attempts"][0]["preparation"]["admission_audit"]["context"] = base64.b64encode(e.canonical_json(audit)).decode()
            with self.assertRaises(e.EvaluationError): runner.score_native(changed, directory, self.history, self.doc, source_ids=self.ids)

    def test_all_missing_outcomes_remain_six_with_empty_private_hypotheses(self):
        packs = {history["id"]: source_ids(history) for history in self.histories}
        with patch.object(controls, "PACKS", packs):
            rows, predictions = [], []
            for history in self.histories:
                row, prediction = runner.score_native({"version": 1, "attempts": [], "fatal_failure": "process_failed"},
                    Path("unused"), history, document(history))
                rows.append(row); predictions.append(prediction)
            self.assertEqual(runner.summarize(rows)["declared_attempts"], 6)
            self.assertEqual(runner.summarize(rows)["operational_failures"], 6)
            self.assertEqual(runner.summarize(rows)["control_outcomes_unavailable"], 6)
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary); result = runner.export_hypotheses(directory, predictions)
                self.assertEqual(result["source_control"]["records"], 6)
                self.assertEqual(os.stat(directory / "source_control.jsonl").st_mode & 0o777, 0o600)
                self.assertTrue(all(row["hypothesis"] == "" for row in map(json.loads, (directory / "source_control.jsonl").read_text().splitlines())))

    def test_new_absolute_paths_and_prebuilt_proof_required_before_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for output, private, binary, proof in ((Path("relative"), directory / "private", "binary", "proof"),
                    (directory / "report", directory / "private", None, None),
                    (directory / "report", Path("relative"), "binary", "proof")):
                with self.assertRaises(e.EvaluationError): runner.run(Path("unused"), output, private, binary=binary, binary_verification=proof)
            existing = directory / "report"; existing.write_bytes(b"preserved")
            with self.assertRaises(e.EvaluationError): runner.run(Path("unused"), existing, directory / "private", binary="binary", binary_verification="proof")
            self.assertEqual(existing.read_bytes(), b"preserved")

    def test_declaration_precedes_verified_driver_no_calls_on_failed_proof(self):
        packs = {history["id"]: source_ids(history) for history in self.histories}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); private = root / "private"
            def refuse(*args):
                self.assertTrue((private / "declaration.json").exists())
                self.assertEqual(os.stat(private).st_mode & 0o777, 0o700)
                frozen = e.strict_json((private / "declaration.json").read_bytes())
                self.assertEqual(frozen["declared_attempts"], 6)
                self.assertEqual([case["declared_source_count"] for case in frozen["cases"]], [3] * 6)
                raise e.EvaluationError("synthetic verification refused")
            with patch.object(controls, "prepare", return_value=self.histories), patch.object(controls, "PACKS", packs), \
                 patch.object(baseline, "code_inventory", return_value={}), patch.object(baseline, "freeze_code"), \
                 patch.object(baseline, "verified_driver", side_effect=refuse), patch.object(e, "execute") as execute:
                with self.assertRaises(e.EvaluationError): runner.run(root / "source", root / "report", private, binary="binary", binary_verification="proof")
                execute.assert_not_called()

    def test_mock_runner_preserves_six_failures_and_keeps_every_content_leaf_private(self):
        packs = {history["id"]: source_ids(history) for history in self.histories}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); binary = root / "binary"; e.private_write(binary, b"synthetic compiled identity")
            def execute(_binary, path, output, _timeout):
                doc = e.strict_json(path.read_bytes()); history = next(h for h in self.histories if h["id"] == doc["history_id"])
                if history["id"] == controls.CASE_IDS[1]: raise RuntimeError("private source sentinel")
                return report(history, output, doc)
            with patch.object(controls, "prepare", return_value=self.histories), patch.object(controls, "PACKS", packs), \
                 patch.object(baseline, "code_inventory", return_value={}), patch.object(baseline, "freeze_code"), \
                 patch.object(baseline, "verified_driver", return_value=(binary, {"binary_sha256": e.digest(binary.read_bytes())})), \
                 patch.object(e, "execute", side_effect=execute):
                value = runner.run(root / "source", root / "report", root / "private", binary=binary, binary_verification="proof")
            self.assertEqual(value["summary"]["declared_attempts"], 6)
            self.assertEqual(value["summary"]["operational_completed"], 5)
            encoded = (root / "report").read_text()
            forbidden = [history["episodes"][0]["prompt"] for history in self.histories]
            forbidden += [source["text"] for history in self.histories for source in history["events"]]
            forbidden += [self.history["episodes"][0]["answer"], self.history["episodes"][0]["question_time"]["original_value"], "private generated natural answer sentinel"]
            self.assertFalse(any(value in encoded for value in forbidden))
            exports = list(map(json.loads, (root / "private/source_control.jsonl").read_text().splitlines()))
            self.assertEqual(exports[1]["hypothesis"], "")
            self.assertEqual(len(exports), 6)
            self.assertEqual(os.stat(root / "report").st_mode & 0o777, 0o600)

    def test_implementation_drift_stops_dispatch_but_retains_all_six_outcomes(self):
        packs = {history["id"]: source_ids(history) for history in self.histories}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); binary = root / "binary"; e.private_write(binary, b"synthetic compiled identity")
            calls = 0
            def inventory():
                return {} if calls < 1 else {"changed": "f" * 64}
            def execute(_binary, path, output, _timeout):
                nonlocal calls
                calls += 1
                doc = e.strict_json(path.read_bytes())
                return report(self.histories[0], output, doc)
            with patch.object(controls, "prepare", return_value=self.histories), patch.object(controls, "PACKS", packs), \
                 patch.object(baseline, "code_inventory", side_effect=inventory), patch.object(baseline, "freeze_code"), \
                 patch.object(baseline, "verified_driver", return_value=(binary, {"binary_sha256": e.digest(binary.read_bytes())})), \
                 patch.object(e, "execute", side_effect=execute):
                value = runner.run(root / "source", root / "report", root / "private", binary=binary, binary_verification="proof")
            self.assertEqual(calls, 1)
            self.assertFalse(value["implementation_continuity"])
            self.assertEqual(value["summary"]["declared_attempts"], 6)
            self.assertEqual(value["summary"]["operational_completed"], 1)
            exports = list(map(json.loads, (root / "private/source_control.jsonl").read_text().splitlines()))
            self.assertTrue(all(row["hypothesis"] == "" for row in exports[1:]))


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}, sort_keys=True))
    raise SystemExit(not result.wasSuccessful())
