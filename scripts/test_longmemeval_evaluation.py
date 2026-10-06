#!/usr/bin/env python3
"""Synthetic, content-suppressed LongMemEval runner contracts; no model calls."""
from __future__ import annotations

import base64
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

import evaluate_answers as e
import evaluate_longmemeval as diagnostic
from evaluation_fixtures import canonical_json


def synthetic_histories():
    histories = []
    for index, kind in enumerate(sorted(diagnostic.TYPES) + ["multi-session"]):
        question_id = f"synthetic-{index:02d}" + ("_abs" if index == 6 else "")
        events = [{"id": f"source-{index}-{position}", "project_id": f"project-{index}",
            "conversation_key": "early" if position == 0 else "last", "role": "assistant" if position == 2 else "user",
            "status": "complete", "text": f"private original source sentinel {index}-{position} π full content",
            "source_time": {"original_value": "2023/05/23 (Tue) 11:23", "value": "2023-05-23T11:23",
                "precision": "minute", "timezone": "unspecified", "source_sha256": "a" * 64,
                "locator": f"/{index}/haystack_dates/{int(position != 0)}"}} for position in range(3)]
        labels = [{"event_id": events[0]["id"], "session_id": "answer-early", "has_answer": True},
                  {"event_id": events[1]["id"], "session_id": "answer-last"},
                  {"event_id": events[2]["id"], "session_id": "answer-last", "has_answer": True}]
        probe = {"id": question_id, "question_id": question_id, "prompt": "private original query sentinel",
            "question_time": {**events[0]["source_time"], "locator": f"/{index}/question_date"},
            "project_id": f"project-{index}", "conversation_key": "last", "question_type": kind,
            "abstention": index == 6, "answer": 42 if index == 1 else "private oracle answer sentinel",
            "answer_session_ids": ["answer-early", "answer-last"]}
        histories.append({"id": question_id, "events": events, "source_labels": labels, "episodes": [probe]})
    return histories


def synthetic_input(history, configuration, version=5):
    probe = history["episodes"][0]
    return {"version": version, "split": "development", "history_id": history["id"], "events": history["events"],
        "configuration": configuration, "attempts": [{**{k: probe[k] for k in ("project_id", "conversation_key", "prompt", "question_time")},
             "probe_id": probe["id"], "strategy": strategy, "replicate": 0} for strategy in e.STRATEGIES]}


def full_range(event):
    data = event["text"].encode()
    return {"event_id": event["id"], "offset": 0, "byte_length": len(data), "sha256": e.digest(data)}


def native_report(history, document, directory):
    directory.mkdir(mode=0o700)
    raw = []
    for ordinal, request in enumerate(document["attempts"]):
        answer = "private generated natural answer sentinel".encode()
        e.private_write(directory / f"answer-{ordinal:04d}.txt", answer)
        identifiers = {key: str(uuid.uuid4()) for key in ("turnID", "humanEventID", "assistantEventID", "invocationID", "episodeID")}
        selection_id, answer_id = str(uuid.uuid4()), str(uuid.uuid4())
        recent = [event["id"] for event in history["events"] if event["conversation_key"] == request["conversation_key"]]
        historical = [event for event in history["events"] if event["id"] not in recent]
        ranges = [full_range(event) for event in historical] + [full_range(event) for event in history["events"] if event["id"] in recent]
        audit = {"source_snapshot_sha256": "b" * 64, "selection_work_id": selection_id,
            "recent_source_count": len(recent), "ordered_recent_source_ids_sha256": e.digest(canonical_json(recent)),
            "historical_sources": [{"event_id": row["event_id"], "excerpt_offset": row["offset"],
                "excerpt_bytes": row["byte_length"], "excerpt_sha256": row["sha256"]} for row in ranges[:len(historical)]]}
        receipt = {"bodyDigest": "c" * 64, "episodeID": identifiers["episodeID"],
            "outputReserve": diagnostic.CONFIGURATION["maximum_output"], "endpoint": diagnostic.chat_endpoint(diagnostic.CONFIGURATION["endpoint"]),
            "componentProof": {"bodyDigest": "c" * 64, "sourceSnapshotDigest": "b" * 64,
                "episodeID": identifiers["episodeID"], "projectID": "answer-evaluation-public:" + request["project_id"],
                "outputReserve": diagnostic.CONFIGURATION["maximum_output"],
                "endpoint": diagnostic.chat_endpoint(diagnostic.CONFIGURATION["endpoint"])}}
        raw.append({"ordinal": ordinal, **{k: request[k] for k in ("probe_id", "strategy", "replicate")},
            "answer_file": f"answer-{ordinal:04d}.txt", "terminalized": True,
            "answer_bytes": len(answer), "answer_sha256": e.digest(answer), "episode_state": "completed",
            "invocation_status": "complete", "capture_healthy": True, "accounting_healthy": True,
            "invocation_started": True, "failure": None, "delivered_ranges": ranges,
            "delivered_recent_source_ids": recent, "identifiers": identifiers,
            "preparation": {"request_sha256": "c" * 64, "selection_sha256": "b" * 64,
                "selection_work_id": selection_id, "answer_work_id": answer_id,
                "context_audit": audit, "admission": copy.deepcopy(receipt),
                "admission_audit": {"version": 3, "receipt": receipt,
                    "inputProofWorkID": str(uuid.uuid4()), "inputProofSHA256": "d" * 64,
                    "context": base64.b64encode(canonical_json(audit)).decode()}}})
    return {"version": 1, "history_id": history["id"], "split": "development", "declared_attempts": 2,
        "completed_attempts": 2, "attempts": raw, "input_sha256": e.digest(canonical_json(document)),
        "public_projection_sha256": e.digest(canonical_json({k: v for k, v in document.items() if k != "configuration"})),
        "native_configuration_sha256": diagnostic.native_configuration_sha256(diagnostic.CONFIGURATION)}


class Contracts(unittest.TestCase):
    def setUp(self):
        self.histories = synthetic_histories()
        self.history = self.histories[0]
        self.document = synthetic_input(self.history, diagnostic.CONFIGURATION)
        self.input_patch = patch.object(diagnostic.cases, "runner_input", side_effect=synthetic_input)
        self.input_patch.start(); self.addCleanup(self.input_patch.stop)

    def test_scoring_requires_version_five_document(self):
        with tempfile.TemporaryDirectory() as temporary:
            document = synthetic_input(self.history, diagnostic.CONFIGURATION, version=4)
            with self.assertRaises(e.EvaluationError):
                diagnostic.score_native({"version": 1, "attempts": []}, Path(temporary), self.history, document)
            for version in (True, 5.0, "5", 6):
                document["version"] = version
                with self.assertRaises(e.EvaluationError):
                    diagnostic.score_native({"version": 1, "attempts": []}, Path(temporary), self.history, document)

    def test_union_full_turns_and_both_roles(self):
        ranges = []
        for event in self.history["events"]:
            data = event["text"].encode(); cut = 8
            ranges.extend({"event_id": event["id"], "offset": offset, "byte_length": len(chunk), "sha256": e.digest(chunk)}
                          for offset, chunk in ((0, data[:cut]), (cut, data[cut:])))
        coverage = diagnostic.delivery_diagnostic(self.history, self.document["attempts"][0], ranges, [])
        self.assertTrue(coverage["all_evidence_turns_delivered"] is True)
        self.assertTrue(coverage["gold_evidence_turn_count"] == 2 and coverage["fully_delivered_evidence_turn_count"] == 2)

    def test_partial_range_hits_session_without_whole_turn(self):
        event = self.history["events"][0]; data = event["text"].encode()[:8]
        coverage = diagnostic.delivery_diagnostic(self.history, self.document["attempts"][0],
            [{"event_id": event["id"], "offset": 0, "byte_length": len(data), "sha256": e.digest(data)}], [])
        self.assertTrue(coverage["session_hit_fraction"] == .5 and coverage["full_evidence_turn_delivery_fraction"] == 0)
        self.assertTrue(coverage["official_retrieval_score"] is None)

    def test_disjoint_ranges_cannot_hide_gap(self):
        event = self.history["events"][0]; data = event["text"].encode()
        ranges = [{"event_id": event["id"], "offset": offset, "byte_length": len(chunk), "sha256": e.digest(chunk)}
                  for offset, chunk in ((0, data[:8]), (9, data[9:]))]
        coverage = diagnostic.delivery_diagnostic(self.history, self.document["attempts"][0], ranges, [])
        self.assertTrue(coverage["fully_delivered_evidence_turn_count"] == 0)

    def test_wrong_digest_source_and_boolean_offset_refused(self):
        row = full_range(self.history["events"][0])
        for key, value in (("sha256", "0" * 64), ("event_id", "unknown"), ("offset", True), ("byte_length", True)):
            with self.assertRaises(e.EvaluationError):
                diagnostic.validated_intervals(self.history, self.document["attempts"][0], [{**row, key: value}], [])

    def test_utf8_midpoint_refused_even_matching_digest(self):
        event = self.history["events"][0]; data = event["text"].encode(); start = data.index("π".encode()) + 1
        row = {"event_id": event["id"], "offset": start, "byte_length": len(data) - start, "sha256": e.digest(data[start:])}
        with self.assertRaises(e.EvaluationError):
            diagnostic.validated_intervals(self.history, self.document["attempts"][0], [row], [])

    def test_project_and_recent_conversation_scope_refused(self):
        request = {**self.document["attempts"][0], "project_id": "outside-scope"}
        with self.assertRaises(e.EvaluationError):
            diagnostic.validated_intervals(self.history, request, [full_range(self.history["events"][0])], [])
        with self.assertRaises(e.EvaluationError):
            diagnostic.validated_intervals(self.history, self.document["attempts"][0],
                                           [full_range(self.history["events"][0])], [self.history["events"][0]["id"]])

    def test_recent_ids_require_full_digest_backed_range(self):
        source = self.history["events"][1]["id"]
        with self.assertRaises(e.EvaluationError):
            diagnostic.validated_intervals(self.history, self.document["attempts"][0], [], [source])

    def test_empty_and_missing_gold_are_unavailable(self):
        history = copy.deepcopy(self.history)
        history["episodes"][0]["answer_session_ids"] = []
        for label in history["source_labels"]: label.pop("has_answer", None)
        coverage = diagnostic.delivery_diagnostic(history, self.document["attempts"][0], [], [])
        self.assertTrue(coverage["session_hit_fraction"] is None and coverage["all_gold_sessions_hit"] is None)
        self.assertTrue(coverage["full_evidence_turn_delivery_fraction"] is None and coverage["all_evidence_turns_delivered"] is None)
        history["source_labels"][0]["has_answer"] = True; history["events"][0]["text"] = ""
        coverage = diagnostic.delivery_diagnostic(history, self.document["attempts"][0], [full_range(history["events"][0])], [])
        self.assertTrue(coverage["empty_gold_evidence_turn_count"] == 1 and coverage["all_evidence_turns_delivered"] is None)

    def test_abstention_id_controls_denominator_not_positive_labels(self):
        history = self.histories[-1]; doc = synthetic_input(history, diagnostic.CONFIGURATION)
        coverage = diagnostic.delivery_diagnostic(history, doc["attempts"][0], [full_range(event) for event in history["events"]], [])
        self.assertTrue(coverage["fully_delivered_evidence_turn_count"] == 2)
        self.assertTrue(coverage["session_hit_fraction"] is None and coverage["full_evidence_turn_delivery_fraction"] is None)

    def test_gold_session_annotation_independent_of_turn_labels(self):
        history = copy.deepcopy(self.history)
        history["source_labels"][0]["has_answer"] = False
        coverage = diagnostic.delivery_diagnostic(history, self.document["attempts"][0], [full_range(history["events"][0])], [])
        self.assertTrue(coverage["session_hit_fraction"] == .5 and coverage["fully_delivered_evidence_turn_count"] == 0)

    def test_numeric_answers_and_optional_labels_retained(self):
        self.assertTrue(type(diagnostic.validate_history(self.histories[1])["answer"]) is int)
        self.assertTrue(diagnostic.oracle_sha256(self.history) != diagnostic.oracle_sha256(self.histories[1]))
        changed = copy.deepcopy(self.history); changed["source_labels"][0]["has_answer"] = 1
        with self.assertRaises(e.EvaluationError): diagnostic.validate_history(changed)

    def test_complete_native_report_export_separation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            attempts, predictions = diagnostic.score_native(native, directory, self.history, self.document)
            self.assertTrue(len(attempts) == 2 and all(row["operational_complete"] for row in attempts))
            self.assertTrue(all(row["official_qa_score"] is None for row in attempts))
            self.assertTrue(all(row["hypothesis"] == "private generated natural answer sentinel" for row in predictions))
            self.assertTrue("private generated natural answer sentinel" not in canonical_json(attempts).decode())

    def test_provider_receipt_and_persisted_audit_are_separate(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            preparation = native["attempts"][0]["preparation"]
            self.assertTrue("componentProof" in preparation["admission"] and "receipt" not in preparation["admission"])
            self.assertEqual(preparation["admission_audit"]["receipt"], preparation["admission"])
            changed = copy.deepcopy(native)
            changed["attempts"][0]["preparation"]["admission"] = preparation["admission_audit"]
            with self.assertRaises(e.EvaluationError): diagnostic.score_native(changed, directory, self.history, self.document)
            changed = copy.deepcopy(native)
            changed["attempts"][0]["preparation"].pop("admission_audit")
            with self.assertRaises(e.EvaluationError): diagnostic.score_native(changed, directory, self.history, self.document)

    def test_document_provenance_fields_required_and_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            for field in ("input_sha256", "public_projection_sha256", "native_configuration_sha256"):
                for missing in (False, True):
                    changed = copy.deepcopy(native)
                    if missing: changed.pop(field)
                    else: changed[field] = "0" * 64
                    with self.assertRaises(e.EvaluationError): diagnostic.score_native(changed, directory, self.history, self.document)

    def test_ordinal_request_file_and_inventory_linkage_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            for field, value in (("ordinal", True), ("ordinal", 1), ("probe_id", "other"), ("strategy", "hybrid"),
                                 ("replicate", True), ("answer_file", "../answer-0000.txt"), ("terminalized", 1)):
                changed = copy.deepcopy(native); changed["attempts"][0][field] = value
                with self.assertRaises(e.EvaluationError): diagnostic.score_native(changed, directory, self.history, self.document)

    def test_answer_ipc_digest_and_symlink_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            native["attempts"][0]["answer_sha256"] = "0" * 64
            with self.assertRaises(e.EvaluationError): diagnostic.score_native(native, directory, self.history, self.document)
            native["attempts"][0]["answer_sha256"] = e.digest((directory / "answer-0000.txt").read_bytes())
            (directory / "answer-0000.txt").unlink(); (directory / "answer-0000.txt").symlink_to(directory / "answer-0001.txt")
            with self.assertRaises(OSError): diagnostic.score_native(native, directory, self.history, self.document)

    def test_admission_request_selection_scope_and_context_corruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            mutations = [lambda p: p.update(request_sha256="0" * 64),
                lambda p: p["admission"]["componentProof"].update(sourceSnapshotDigest="0" * 64),
                lambda p: p["admission"]["componentProof"].update(projectID="outside-scope"),
                lambda p: p["admission"].update(episodeID=str(uuid.uuid4())),
                lambda p: p["admission"].update(endpoint=diagnostic.CONFIGURATION["endpoint"]),
                lambda p: p["admission"]["componentProof"].update(endpoint="http://localhost:11234/v1/"),
                lambda p: p["admission_audit"].pop("inputProofSHA256"),
                lambda p: p["admission_audit"].update(context=base64.b64encode(b"{}").decode()),
                lambda p: p.pop("admission_audit"),
                lambda p: p["context_audit"].update(ordered_recent_source_ids_sha256="0" * 64)]
            for mutate in mutations:
                changed = copy.deepcopy(native); mutate(changed["attempts"][0]["preparation"])
                with self.assertRaises(e.EvaluationError): diagnostic.score_native(changed, directory, self.history, self.document)

    def test_unlinked_ranges_and_unknown_terminal_states_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            changed = copy.deepcopy(native); changed["attempts"][0].pop("preparation")
            with self.assertRaises(e.EvaluationError): diagnostic.score_native(changed, directory, self.history, self.document)
            changed = copy.deepcopy(native); changed["attempts"][0]["episode_state"] = "arbitrary-state"
            with self.assertRaises(e.EvaluationError): diagnostic.score_native(changed, directory, self.history, self.document)

    def test_missing_partial_interrupted_attempts_keep_empty_exports(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            native["attempts"][0]["invocation_status"] = "partial"
            native["attempts"][1]["terminalized"] = False; native["attempts"][1].pop("answer_file"); native["completed_attempts"] = 1
            attempts, predictions = diagnostic.score_native(native, directory, self.history, self.document)
            self.assertTrue(len(attempts) == 2 and all(not row["operational_complete"] for row in attempts))
            self.assertTrue(all(row["hypothesis"] == "" for row in predictions))

    def test_cancelled_and_interrupted_states_are_retained_unscored(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            native["attempts"][0].update(episode_state="cancelled", invocation_status="cancelled")
            native["attempts"][1].update(episode_state="interrupted", invocation_status="partial")
            attempts, predictions = diagnostic.score_native(native, directory, self.history, self.document)
            self.assertTrue(len(attempts) == 2 and all(not row["operational_complete"] for row in attempts))
            self.assertTrue(all(row["hypothesis"] == "" for row in predictions))
            missing, predictions = diagnostic.score_native({"version": 1, "attempts": []}, directory, self.history, self.document)
            self.assertTrue(len(missing) == 2 and diagnostic.summarize(missing)["hybrid"]["official_qa_unscored_attempts"] == 1)
            self.assertTrue(all(row["hypothesis"] == "" for row in predictions))

    def test_provider_text_unknown_keys_dates_and_oracle_absent_from_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "native"; native = native_report(self.history, self.document, directory)
            secret = "private provider source sentinel"
            native["attempts"][0][secret] = {"failure": secret, "source_time": self.history["events"][0]["source_time"]}
            attempts, _ = diagnostic.score_native(native, directory, self.history, self.document)
            encoded = canonical_json(attempts).decode()
            for value in (secret, self.history["episodes"][0]["prompt"], self.history["episodes"][0]["answer"],
                          self.history["events"][0]["source_time"]["original_value"], diagnostic.CONFIGURATION["system"]):
                self.assertTrue(value not in encoded)

    def test_private_hypothesis_export_two_fields_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            predictions = [{"strategy": strategy, "question_id": history["id"], "hypothesis": "private answer sentinel"}
                for history in self.histories for strategy in e.STRATEGIES]
            ids = [h["id"] for h in self.histories]
            exports = diagnostic.export_hypotheses(directory, predictions, ids)
            for strategy in e.STRATEGIES:
                path = directory / (strategy + ".jsonl")
                rows = [json.loads(line) for line in path.read_bytes().splitlines()]
                self.assertTrue(len(rows) == 7 and all(set(row) == {"question_id", "hypothesis"} for row in rows))
                self.assertTrue(exports[strategy]["sha256"] == e.digest(path.read_bytes()) and path.stat().st_mode & 0o777 == 0o600)
            with self.assertRaises(OSError): diagnostic.export_hypotheses(directory, predictions, ids)

    def test_export_duplicate_missing_cases_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(e.EvaluationError):
                diagnostic.export_hypotheses(Path(temporary), [{"strategy": "recent_only", "question_id": "other", "hypothesis": ""}], [self.history["id"]])

    def test_binary_requires_terminal_record_and_all_source_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary); binary = scratch / "binary"; e.private_write(binary, b"synthetic binary")
            inventory = {"Sources/test.swift": "1" * 64, "scripts/runner.py": "2" * 64}
            record_path = scratch / "verification.json"
            record = {"terminal_passed": True, "app_binary_sha256": e.digest(binary.read_bytes()), "source_hashes": inventory}
            e.private_write(record_path, canonical_json(record))
            with patch.object(diagnostic, "code_inventory", return_value=inventory):
                built, identity = diagnostic.verified_driver(scratch, inventory, binary, record_path)
                self.assertTrue(built == binary and identity["binary_sha256"] == record["app_binary_sha256"])
                for mutate in (lambda r: r.update(terminal_passed=False), lambda r: r.update(app_binary_sha256="0" * 64),
                               lambda r: r["source_hashes"].pop("Sources/test.swift")):
                    changed = copy.deepcopy(record); mutate(changed); record_path.write_bytes(canonical_json(changed))
                    with self.assertRaises(e.EvaluationError): diagnostic.verified_driver(scratch, inventory, binary, record_path)
                with self.assertRaises(e.EvaluationError): diagnostic.verified_driver(scratch, inventory, binary, None)

    def test_compile_inventory_and_binary_mismatch_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary); binary = scratch / "binary"; e.private_write(binary, b"synthetic binary")
            inventory = {"Sources/test.swift": "1" * 64}
            for record in ({"source_sha256": inventory, "binary_sha256": "0" * 64},
                           {"source_sha256": {}, "binary_sha256": e.digest(binary.read_bytes())}):
                with patch.object(diagnostic, "code_inventory", return_value=inventory), patch.object(e, "compile_driver", return_value=(binary, record)):
                    with self.assertRaises(e.EvaluationError): diagnostic.verified_driver(scratch, inventory)

    def test_run_declares_before_compile_retains_all_missing_denominators(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); output = root / "report.json"; private = root / "hypotheses"
            def driver(scratch, inventory, _binary, _verification):
                declaration = e.strict_json((private / "declaration.json").read_bytes())
                self.assertTrue(declaration["declared_attempts"] == 14 and len(declaration["case_ids"]) == 7)
                self.assertTrue(declaration["source_hashes"] == inventory)
                self.assertEqual(declaration["runner_document_version"], 5)
                self.assertTrue((scratch / "frozen-code/scripts/evaluate_longmemeval.py").is_file())
                self.assertTrue((scratch / "frozen-code/scripts/longmemeval_cases.py").is_file())
                self.assertTrue((scratch / "frozen-code/scripts/import_chat.py").is_file())
                binary = scratch / "binary"; e.private_write(binary, b"synthetic binary")
                return binary, {"binary_sha256": e.digest(binary.read_bytes()), "source_sha256": inventory}
            def execute_missing(_binary, input_path, _directory, _timeout):
                self.assertEqual(e.strict_json(e.read_file(input_path))["version"], 5)
                return {"version": 1, "fatal_failure": "runner_process_timeout", "attempts": []}
            with patch.object(diagnostic.cases, "prepare", return_value=self.histories), patch.object(diagnostic, "verified_driver", side_effect=driver), \
                 patch.object(e, "execute", side_effect=execute_missing) as execute:
                report = diagnostic.run(root / "unused", output, private, timeout=60)
            self.assertEqual(report["runner_document_version"], 5)
            self.assertTrue(execute.call_count == 7 and sum(r["declared_attempts"] for r in report["summary"].values()) == 14)
            self.assertTrue(all(r["operational_failures"] == 7 and r["official_qa_unscored_attempts"] == 7 for r in report["summary"].values()))
            self.assertTrue(all(r["session_hit_diagnostic_denominator"] == 0
                and r["mean_session_hit_fraction"] is None for r in report["summary"].values()))
            self.assertTrue(private.stat().st_mode & 0o777 == 0o700 and output.stat().st_mode & 0o777 == 0o600)
            for strategy in e.STRATEGIES:
                self.assertTrue(all(json.loads(line)["hypothesis"] == "" for line in (private / (strategy + ".jsonl")).read_bytes().splitlines()))
            encoded = output.read_text()
            forbidden = [self.history["episodes"][0]["prompt"], self.history["episodes"][0]["answer"],
                self.history["events"][0]["source_time"]["original_value"], diagnostic.CONFIGURATION["system"],
                *[event["text"] for history in self.histories for event in history["events"]]]
            self.assertTrue(not any(value in encoded for value in forbidden))
            with self.assertRaises(e.EvaluationError): diagnostic.run(root / "unused", output, root / "new-export")
            with self.assertRaises(e.EvaluationError): diagnostic.run(root / "unused", root / "new-report", private)

    def test_invalid_native_report_keeps_all_fourteen_empty_exports(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def driver(scratch, inventory, _binary, _verification):
                binary = scratch / "binary"; e.private_write(binary, b"synthetic binary")
                return binary, {"binary_sha256": e.digest(binary.read_bytes()), "source_sha256": inventory}
            with patch.object(diagnostic.cases, "prepare", return_value=self.histories), patch.object(diagnostic, "verified_driver", side_effect=driver), \
                 patch.object(e, "execute", return_value={"version": 1, "attempts": [None]}):
                report = diagnostic.run(root / "unused", root / "report.json", root / "hypotheses", timeout=60)
            self.assertTrue(sum(row["operational_failures"] for row in report["summary"].values()) == 14)

    def test_output_and_explicit_export_path_constraints_precede_provider(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for directory in (Path("relative-export"), e.ROOT / "tracked-hypothesis-export"):
                with patch.object(e, "execute") as execute:
                    with self.assertRaises(e.EvaluationError): diagnostic.run(root / "unused", root / "report", directory)
                    self.assertTrue(not execute.called)
            with self.assertRaises(e.EvaluationError): diagnostic.run(root / "unused", root / "report", root / "private", binary=root / "binary")

    def test_other_repository_export_requires_ignored_build_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repository = root / "other-repository"; repository.mkdir(); (repository / ".git").write_text("synthetic git marker")
            with self.assertRaises(e.EvaluationError): diagnostic._paths(root / "report", repository / "hypotheses")
            _output, private = diagnostic._paths(root / "report", repository / ".build/hypotheses")
            self.assertTrue(private == (repository / ".build/hypotheses").resolve())

    def test_cli_failure_message_contains_no_source_argument(self):
        stderr = io.StringIO()
        with patch.object(sys, "argv", ["evaluate_longmemeval.py", "--source", "private path sentinel", "--output", "unused", "--hypotheses-directory", "relative"]), \
             contextlib.redirect_stderr(stderr):
            self.assertTrue(diagnostic.main() == 1)
        self.assertTrue(stderr.getvalue() == "LongMemEval evaluation failed; content diagnostics suppressed.\n")


class SafeResult(unittest.TestResult):
    def __init__(self):
        super().__init__(); self.failed_names = []; self.error_names = []
    def addFailure(self, test, err):
        super().addFailure(test, err); self.failed_names.append(test.id().rsplit(".", 1)[-1])
    def addError(self, test, err):
        super().addError(test, err); self.error_names.append(test.id().rsplit(".", 1)[-1])


if __name__ == "__main__":
    result = SafeResult(); unittest.defaultTestLoader.loadTestsFromTestCase(Contracts).run(result)
    print(json.dumps({"checks": result.testsRun, "failed": result.failed_names,
                      "errors": result.error_names, "skipped": len(result.skipped)}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
