#!/usr/bin/env python3
"""Content-free synthetic contracts for separate complete-exchange controls."""
from __future__ import annotations

import contextlib
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import devgpt_evidence_controls as controls
import evaluate_evidence_controls as diagnostic
import evaluate_answers as e
import evaluate_developer_answers as developer
from evaluation_fixtures import canonical_json
from test_developer_answer_evaluation import controlled_source, answer_for, ranges_for, SafeResult


@contextlib.contextmanager
def controlled_packs():
    with controlled_source() as (histories, _data, _read), contextlib.ExitStack() as stack:
        packs = []
        for history in histories:
            for probe in history["episodes"]:
                if not probe["answerable"]:
                    continue
                ids = set(probe["oracle"]["required_source_ids"])
                indices = [i for i, event in enumerate(history["events"]) if event["id"] in ids]
                positions = [position for i in indices for position in (i - 1, i)]
                packs.append({"id": probe["id"] + "-evidence-control", "original_history_id": history["id"],
                    "events": copy.deepcopy([history["events"][i] for i in positions]),
                    "episodes": [copy.deepcopy(probe)], "original_source_positions": positions})
        stack.enter_context(patch.object(controls, "PROJECTION_SHA256", tuple(e.digest(canonical_json(controls.projection(p))) for p in packs)))
        stack.enter_context(patch.object(controls, "ORACLE_SHA256", tuple(e.digest(canonical_json(p["episodes"][0]["oracle"])) for p in packs)))
        yield histories, packs


def native_report(pack, document, directory, *, correct=True):
    directory.mkdir(mode=0o700)
    answer = answer_for(pack["episodes"][0]) if correct else json.dumps({"answer": "synthetic wrong", "citations": [], "abstain": False})
    encoded = answer.encode()
    e.private_write(directory / "answer-0000.txt", encoded)
    request = document["attempts"][0]
    item = {"ordinal": 0, **{key: request[key] for key in ("probe_id", "strategy", "replicate")},
        "answer_file": "answer-0000.txt", "terminalized": True, "answer_bytes": len(encoded),
        "answer_sha256": e.digest(encoded), "episode_state": "completed", "invocation_status": "complete",
        "capture_healthy": True, "accounting_healthy": True, "failure": None,
        "delivered_ranges": [], "delivered_recent_source_ids": [event["id"] for event in pack["events"]],
        "witness_mode": controls.VERSION, "witness_validation": {"version": controls.VALIDATION_VERSION,
            "declared_source_count": len(pack["events"]),
            "declared_source_bytes": sum(len(event["text"].encode()) for event in pack["events"]),
            "delivered_source_count": len(pack["events"]), "complete_pack_delivered": True,
            "source_body_count_revalidated": True, "input_proof_version": 3, "failure_code": None}}
    return {"version": 1, "attempts": [item], "witness_mode": controls.VERSION,
        "input_sha256": e.digest(canonical_json(document)),
        "public_projection_sha256": e.digest(canonical_json(controls.projection(pack)))}


class Contracts(unittest.TestCase):
    def test_nine_packs_complete_original_pairs(self):
        with controlled_packs() as (histories, _packs):
            packs = controls.prepare(Path("controlled-public-source"))
            self.assertTrue(len(packs) == 9)
            for pack in packs:
                original = next(h for h in histories if h["id"] == pack["original_history_id"])
                self.assertTrue(len(pack["events"]) in (2, 4))
                self.assertTrue(pack["events"] == [original["events"][i] for i in pack["original_source_positions"]])
                self.assertTrue(pack["original_source_positions"] == sorted(pack["original_source_positions"]))
                self.assertTrue(all(b == a + 1 for a, b in zip(pack["original_source_positions"][::2], pack["original_source_positions"][1::2])))

    def test_original_inputs_unchanged(self):
        with controlled_packs() as (histories, _packs):
            before = canonical_json(histories)
            controls.prepare(Path("controlled-public-source"))
            self.assertTrue(before == canonical_json(histories))

    def test_single_original_question_recent_only_zero_no_oracle(self):
        with controlled_packs() as (_histories, packs):
            for pack in packs:
                doc = controls.runner_input(pack, developer.CONFIGURATION)
                self.assertTrue(set(doc) == {"version", "split", "history_id", "events", "attempts", "configuration"})
                self.assertTrue(doc["version"] == 2 and len(doc["attempts"]) == 1)
                row = doc["attempts"][0]
                self.assertTrue(row["prompt"] == pack["episodes"][0]["prompt"] and row["strategy"] == "recent_only" and row["replicate"] == 0)
                self.assertTrue(not any(key in canonical_json(doc).decode() for key in ('"oracle"', '"expected_answers"', '"goldSpans"')))

    def test_configuration_exact_and_canonical_representations(self):
        self.assertTrue(e.digest(canonical_json(developer.CONFIGURATION)) == controls.CONFIGURATION_SHA256)
        native = {**developer.CONFIGURATION, "temperature": 0}
        self.assertTrue(e.digest(canonical_json(native)) == controls.NATIVE_CONFIGURATION_SHA256)
        self.assertTrue(native == developer.CONFIGURATION)
        for field, value in (("maximum_output", 2049), ("seed", 1), ("temperature", 0), ("thinking", True)):
            with self.assertRaises(e.EvaluationError): controls.validate_configuration({**developer.CONFIGURATION, field: value})

    def test_projection_source_order_scope_role_question_tampering(self):
        with controlled_packs() as (_histories, packs):
            for mutate in (lambda p: p["events"][0].update(text="synthetic tampered"),
                           lambda p: p["events"].reverse(), lambda p: p["events"][0].update(projectID="changed"),
                           lambda p: p["events"][0].update(role="assistant"),
                           lambda p: p["episodes"][0].update(prompt="synthetic changed question")):
                pack = copy.deepcopy(packs[0]); mutate(pack)
                with self.assertRaises(e.EvaluationError): controls.runner_input(pack, developer.CONFIGURATION)

    def test_oracle_and_gold_tampering(self):
        with controlled_packs() as (_histories, packs):
            for mutate in (lambda p: p["episodes"][0]["oracle"].update(expected_answers=["synthetic changed"]),
                           lambda p: p["episodes"][0]["goldSpans"][0].update(sha256="0" * 64)):
                pack = copy.deepcopy(packs[0]); mutate(pack)
                with self.assertRaises(e.EvaluationError): controls.validate_pack(pack)

    def test_isolated_gold_reconstruction_refused(self):
        with controlled_packs() as (_histories, packs):
            pack = copy.deepcopy(packs[0]); event = pack["events"][1]
            event["text"] = pack["episodes"][0]["oracle"]["expected_answers"][0]
            with self.assertRaises(e.EvaluationError): controls.validate_pack(pack)

    def test_pack_annotation_content_free_exact_sources(self):
        with controlled_packs() as (_histories, packs):
            metadata = controls.metadata(packs[1]); encoded = canonical_json(metadata)
            self.assertTrue(metadata["source_count"] == 4 and len(metadata["exchanges"]) == 2)
            self.assertTrue(all(event["text"].encode() not in encoded for event in packs[1]["events"]))
            self.assertTrue(packs[1]["episodes"][0]["prompt"].encode() not in encoded)

    def test_complete_pack_delivery_and_split_ranges(self):
        with controlled_packs() as (_histories, packs):
            pack = packs[0]; ranges = []
            for event in pack["events"]:
                data = event["text"].encode(); cut = 10
                ranges.extend({"event_id": event["id"], "offset": offset, "byte_length": len(part), "sha256": e.digest(part)}
                              for offset, part in ((0, data[:cut]), (cut, data[cut:])))
            self.assertTrue(diagnostic.full_pack_coverage(pack, ranges, [])["all_required_spans_delivered"])

    def test_gold_delivery_does_not_establish_complete_pack(self):
        with controlled_packs() as (_histories, packs):
            pack = packs[0]
            self.assertTrue(e.delivered_coverage(pack, pack["episodes"][0], ranges_for(pack["episodes"][0]), [])["all_required_spans_delivered"])
            self.assertTrue(not diagnostic.full_pack_coverage(pack, ranges_for(pack["episodes"][0]), [])["all_required_spans_delivered"])

    def test_wrong_source_and_range_digest_refused(self):
        with controlled_packs() as (_histories, packs):
            pack = packs[0]; rows = ranges_for(pack["episodes"][0])
            rows[0]["sha256"] = "0" * 64
            with self.assertRaises(e.EvaluationError): diagnostic.full_pack_coverage(pack, rows, [])
            with self.assertRaises(e.EvaluationError): diagnostic.full_pack_coverage(pack, [], ["synthetic-unknown-source"])

    def test_conditional_requires_actual_v3_proof_and_original_pack(self):
        with controlled_packs() as (_histories, packs), tempfile.TemporaryDirectory() as temporary:
            pack = packs[0]; doc = controls.runner_input(pack, developer.CONFIGURATION)
            native = native_report(pack, doc, Path(temporary) / "output")
            self.assertTrue(diagnostic.score_native(native, Path(temporary) / "output", pack, doc)[0]["conditional_task_score"] == 1)
            for field, value in (("source_body_count_revalidated", False), ("complete_pack_delivered", False),
                                 ("input_proof_version", 2), ("input_proof_version", True),
                                 ("declared_source_count", 1), ("declared_source_bytes", 1),
                                 ("delivered_source_count", 1), ("failure_code", "witness_source_body_count_invalid")):
                changed = copy.deepcopy(native); changed["attempts"][0]["witness_validation"][field] = value
                self.assertTrue(diagnostic.score_native(changed, Path(temporary) / "output", pack, doc)[0]["conditional_task_score"] is None)

    def test_report_mode_projection_and_input_linkage(self):
        with controlled_packs() as (_histories, packs), tempfile.TemporaryDirectory() as temporary:
            pack = packs[0]; doc = controls.runner_input(pack, developer.CONFIGURATION)
            directory = Path(temporary) / "output"; native = native_report(pack, doc, directory)
            for field, value in (("witness_mode", "changed"), ("public_projection_sha256", "0" * 64)):
                changed = {**native, field: value}
                self.assertTrue(diagnostic.score_native(changed, directory, pack, doc)[0]["conditional_task_score"] is None)
            with self.assertRaises(e.EvaluationError): diagnostic.score_native({**native, "input_sha256": "0" * 64}, directory, pack, doc)

    def test_positive_witness_cannot_replace_actual_pack_delivery(self):
        with controlled_packs() as (_histories, packs), tempfile.TemporaryDirectory() as temporary:
            pack = packs[0]; doc = controls.runner_input(pack, developer.CONFIGURATION)
            directory = Path(temporary) / "output"; native = native_report(pack, doc, directory)
            native["attempts"][0]["delivered_recent_source_ids"] = []
            native["attempts"][0]["delivered_ranges"] = ranges_for(pack["episodes"][0])
            result = diagnostic.score_native(native, directory, pack, doc)[0]
            self.assertTrue(result["task_score"]["score"] == 1 and result["conditional_task_score"] is None)
            summary = diagnostic.summarize([result])
            self.assertTrue(summary["overall_task_success_rate"] == 1 and summary["overall_control_success_rate"] == 0)

    def test_incomplete_and_missing_attempts_remain_denominator(self):
        with controlled_packs() as (_histories, packs), tempfile.TemporaryDirectory() as temporary:
            pack = packs[0]; doc = controls.runner_input(pack, developer.CONFIGURATION)
            directory = Path(temporary) / "output"; native = native_report(pack, doc, directory)
            native["attempts"][0]["invocation_status"] = "partial"
            failed = diagnostic.score_native(native, directory, pack, doc)
            missing = diagnostic.score_native({"version": 1, "attempts": []}, directory, pack, doc)
            summary = diagnostic.summarize(failed + missing)
            self.assertTrue(summary["declared_attempts"] == 2 and summary["operational_failures"] == 2)
            self.assertTrue(summary["overall_task_success_rate"] == 0 and summary["overall_control_success_rate"] == 0
                            and summary["conditional_success_rate"] is None)

    def test_conditional_denominator_includes_wrong_complete_answers(self):
        with controlled_packs() as (_histories, packs), tempfile.TemporaryDirectory() as temporary:
            pack = packs[0]; doc = controls.runner_input(pack, developer.CONFIGURATION)
            directory = Path(temporary) / "output"; native = native_report(pack, doc, directory, correct=False)
            attempts = diagnostic.score_native(native, directory, pack, doc)
            summary = diagnostic.summarize(attempts)
            self.assertTrue(summary["conditional_eligible_attempts"] == 1 and summary["conditional_success_rate"] == 0)

    def test_scored_report_suppresses_answer_and_prompt(self):
        with controlled_packs() as (_histories, packs), tempfile.TemporaryDirectory() as temporary:
            pack = packs[0]; doc = controls.runner_input(pack, developer.CONFIGURATION)
            directory = Path(temporary) / "output"; native = native_report(pack, doc, directory)
            encoded = canonical_json(diagnostic.score_native(native, directory, pack, doc))
            self.assertTrue(all(event["text"].encode() not in encoded for event in pack["events"]))
            self.assertTrue(answer_for(pack["episodes"][0]).encode() not in encoded)

    def test_run_preserves_nine_failed_attempts_and_private_report(self):
        with controlled_packs() as (_histories, _packs), tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "report.json"
            with (patch.object(e, "compile_driver", return_value=(Path("unused-driver"), {})) as compile_call,
                  patch.object(e, "execute", return_value={"version": 1, "attempts": []}) as execute_call):
                report = diagnostic.run(Path("controlled-public-source"), output)
            self.assertTrue(compile_call.call_count == 1 and execute_call.call_count == 9)
            self.assertTrue(report["summary"]["declared_attempts"] == 9 and report["summary"]["operational_failures"] == 9)
            self.assertTrue(output.stat().st_mode & 0o777 == 0o600)
            with self.assertRaises(e.EvaluationError): diagnostic.run(Path("controlled-public-source"), output)

    def test_pin_failure_precedes_compile_or_provider_work(self):
        with controlled_packs() as (_histories, _packs), tempfile.TemporaryDirectory() as temporary:
            with patch.object(controls, "CONFIGURATION_SHA256", "0" * 64), patch.object(e, "compile_driver") as compile_call:
                with self.assertRaises(e.EvaluationError): diagnostic.run(Path("controlled-public-source"), Path(temporary) / "report.json")
                self.assertTrue(not compile_call.called)


if __name__ == "__main__":
    result = SafeResult(); unittest.defaultTestLoader.loadTestsFromTestCase(Contracts).run(result)
    print(json.dumps({"checks": result.testsRun, "failed": result.failed_names, "errors": result.error_names,
                      "skipped": len(result.skipped)}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
