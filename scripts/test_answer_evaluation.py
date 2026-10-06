#!/usr/bin/env python3
"""Controlled, content-free contracts for the public paired answering diagnostic."""
from __future__ import annotations

import argparse
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import subprocess
import threading
from http.server import ThreadingHTTPServer
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("boros_answers", ROOT / "scripts/evaluate_answers.py")
e = importlib.util.module_from_spec(spec); spec.loader.exec_module(e)


class Contracts(unittest.TestCase):
    def test_witness_validation_metadata_preserves_outcomes_without_source_text(self):
        validation = {"version": "sufficient-exchange-pack-validation-v1", "declared_source_count": 4,
                      "declared_source_bytes": 4105, "delivered_source_count": 4,
                      "complete_pack_delivered": True, "source_body_count_revalidated": True,
                      "input_proof_version": 3, "failure_code": None}
        metadata = {"witness_mode": "sufficient-exchange-pack-v1", "witness_validation": validation,
                    "unexpected witness content": "synthetic private witness sentinel"}
        sanitized = e.content_free_metadata(metadata)
        self.assertEqual(sanitized["witness_validation"], validation)
        self.assertEqual(sanitized["witness_mode"], "sufficient-exchange-pack-v1")
        encoded = json.dumps(sanitized)
        self.assertNotIn("synthetic private witness sentinel", encoded)
        self.assertNotIn("unexpected witness content", encoded)

    def test_selection_trace_remains_structured_and_content_free(self):
        trace = {"version": "historical-selection-trace-v1", "lexical_query_version": "quoted-anchor-round-robin-v1", "quoted_anchor_count": 1,
                 "lexical_query_sha256": e.digest(b"synthetic query"), "lexical_term_count": 2,
                 "lexical_selected_token_indices": [1, 3], "candidate_count": 1, "trace_truncated": False,
                 "candidates": [{"event_id": "synthetic-public-source", "rank": 0, "offset": 0, "byte_length": 12}],
                 "assembly": [{"event_id": "synthetic-public-source", "rank": 0, "disposition": "included"}]}
        expansion = {"version": "following-assistant-prefix-v2", "source_frontier": 9, "primary_count": 1,
                     "retained_primary_count": 1, "dropped_primary_count": 0, "added_neighbor_count": 1,
                     "prefix_truncated_count": 0, "promoted_primary_count": 1, "decisions": [{"anchor_event_id": "synthetic-public-source",
                         "neighbor_event_id": "synthetic-public-source", "disposition": "included_prefix",
                         "excerpt_bytes": 12, "prefix_truncated": False},
                         {"anchor_event_id": "synthetic-public-source", "disposition": "promoted_primary"}]}
        data = {"retrieval": {"selection_trace": trace, "exchange_expansion": expansion, "query_disposition": "codeLike"},
                "unexpected source text": "synthetic private conversation sentinel"}
        sanitized = e.content_free_metadata(data, frozenset({"synthetic-public-source"}))
        self.assertEqual(sanitized["retrieval"]["selection_trace"], trace)
        self.assertEqual(sanitized["retrieval"]["exchange_expansion"], expansion)
        self.assertEqual(sanitized["retrieval"]["query_disposition"], "codeLike")
        encoded = json.dumps(sanitized)
        self.assertNotIn("synthetic private conversation sentinel", encoded)
        self.assertNotIn("unexpected source text", encoded)

    def test_query_ranges_remain_structured_without_query_content(self):
        trace = {"lexical_input_version": "accepted-prompt-utf8-range-v1",
                 "semantic_input_version": "accepted-prompt-utf8-range-v1",
                 "lexical_input_sha256": "a" * 64, "semantic_input_sha256": "b" * 64,
                 "accepted_prompt_sha256": "c" * 64,
                 "lexical_input_offset": 11, "lexical_input_bytes": 8,
                 "semantic_input_offset": 19, "semantic_input_bytes": 23}
        self.assertEqual(e.content_free_metadata(trace, frozenset()), trace)

    @classmethod
    def setUpClass(cls):
        cls.fixtures = e.generate("development", history_count=1)
        cls.history = cls.fixtures["histories"][0]

    def test_runner_separates_all_oracle_fields_and_keeps_all_pairs(self):
        document = e.runner_input(self.fixtures, e.DEFAULTS)
        self.assertTrue(len(document["attempts"]) == len(self.history["episodes"]) * 2)
        self.assertTrue([row["strategy"] for row in document["attempts"]] == list(e.STRATEGIES) * len(self.history["episodes"]))
        forbidden = {"goldSpans", "lexicalQuery", "literalQuery", "answerable", "category", "prototypeByteFeasible",
                     "providerTokenFeasible", "expected", "score", "rubric"}
        def keys(value):
            if isinstance(value, dict):
                return set(value).union(*(keys(item) for item in value.values()))
            if isinstance(value, list):
                return set().union(*(keys(item) for item in value))
            return set()
        self.assertTrue(not forbidden & keys(document))
        self.assertTrue(len({row["project_id"] for row in document["events"]}) == 2)
        self.assertTrue(set(document["configuration"]) == set(e.DEFAULTS))

    def test_validation_and_heldout_are_rejected(self):
        for split in ("validation", "held-out"):
            with self.assertRaises(e.EvaluationError):
                e.runner_input(e.generate(split, history_count=1), e.DEFAULTS)
        with self.assertRaises(e.EvaluationError):
            e.runner_input(e.generate("development", history_count=2), e.DEFAULTS)

    def test_configuration_rejects_unknown_fields_credentials_remote_and_coercions(self):
        bads = [{**e.DEFAULTS, "store": "unused"}, {**e.DEFAULTS, "seed": True},
                {**e.DEFAULTS, "thinking": 1}, {**e.DEFAULTS, "temperature": float("nan")},
                {**e.DEFAULTS, "endpoint": "https://example.com/v1"},
                {**e.DEFAULTS, "endpoint": "http://key@localhost/v1"},
                {**e.DEFAULTS, "endpoint": "http://localhost/v1?api_key=test"}]
        for bad in bads:
            with self.assertRaises(e.EvaluationError): e.validate_configuration(bad)

    def test_exact_factual_score_terminal_completion_separate(self):
        probe = self.history["episodes"][0]
        value = e.expected_values(self.history, probe)[0]
        self.assertTrue(e.factual_score(self.history, probe, value, True)["score"] == 1)
        self.assertTrue(e.factual_score(self.history, probe, value, False)["score"] == 0)
        self.assertTrue(e.factual_score(self.history, probe, "unrelated", True)["score"] == 0)
        self.assertTrue(e.factual_score(self.history, probe, value + "suffix", True)["score"] == 0)
        self.assertTrue(e.factual_score(self.history, probe, value.lower(), True)["score"] == 0)

    def test_multisource_score_requires_all_expected_values(self):
        probe = next(row for row in self.history["episodes"] if row["id"].endswith("multi-source"))
        expected = e.expected_values(self.history, probe)
        self.assertTrue(e.factual_score(self.history, probe, expected[0], True)["score"] == 0)
        self.assertTrue(e.factual_score(self.history, probe, ", ".join(expected), True)["score"] == 1)

    def test_unfrozen_dimensions_remain_unscored_even_when_noncomplete(self):
        for suffix in ("byte-infeasible", "quoted-data", "absent"):
            probe = next(row for row in self.history["episodes"] if row["id"].endswith(suffix))
            self.assertTrue(e.factual_score(self.history, probe, "", False)["score"] is None)

    def test_gold_hash_and_utf8_boundaries_are_verified(self):
        probe = copy.deepcopy(self.history["episodes"][0])
        probe["goldSpans"][0]["sha256"] = "a" * 64
        with self.assertRaises(e.EvaluationError): e.expected_values(self.history, probe)

    def test_coverage_is_source_range_bound_and_does_not_count_echoes(self):
        probe = self.history["episodes"][0]; gold = probe["goldSpans"][0]
        row = {"event_id": gold["eventID"], "offset": gold["offset"],
               "byte_length": gold["byteLength"], "sha256": gold["sha256"]}
        self.assertTrue(e.delivered_coverage(self.history, probe, [row], [])["all_required_spans_delivered"])
        self.assertTrue(not e.delivered_coverage(self.history, probe, [], [self.history["events"][-1]["id"]])["all_required_spans_delivered"])
        self.assertTrue(not e.delivered_coverage(self.history, probe, [], [])["all_required_spans_delivered"])
        wrong = dict(row, event_id=self.history["events"][1]["id"])
        with self.assertRaises(e.EvaluationError): e.delivered_coverage(self.history, probe, [wrong], [])

    def test_report_preservation_precedes_compile_and_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"; path.write_bytes(b"preserved")
            with patch.object(e, "compile_driver") as compile_driver:
                with self.assertRaises(e.EvaluationError):
                    e.run(SimpleNamespace(output=path, configuration=e.DEFAULTS, timeout=60))
                self.assertTrue(not compile_driver.called)
                self.assertTrue(path.read_bytes() == b"preserved")

    def controlled_report(self, directory, *, count=None):
        document = e.runner_input(self.fixtures, e.DEFAULTS)
        attempts = []
        probes = {probe["id"]: probe for probe in self.history["episodes"]}
        for ordinal, request in enumerate(document["attempts"][:count]):
            probe = probes[request["probe_id"]]
            # Controlled completed answers are deliberately incorrect. The
            # task score must leave their durable operational state untouched.
            answer = b"controlled incorrect result"
            filename = f"answer-{ordinal:04d}.txt"; e.private_write(directory / filename, answer)
            attempts.append({"ordinal": ordinal, **{key: request[key] for key in ("probe_id", "strategy", "replicate")},
                "answer_file": filename, "terminalized": True, "answer_bytes": len(answer),
                "answer_sha256": e.digest(answer), "episode_state": "completed", "invocation_status": "complete",
                "capture_healthy": True, "accounting_healthy": True, "failure": None,
                "delivered_ranges": [], "delivered_recent_source_ids": [],
                "episode": {"charged": {"inputTokens": 24}, "held": {"outputTokens": 0}}})
        return document, {"version": 1, "attempts": attempts}

    def test_completed_wrong_answers_keep_operational_completion(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); document, native = self.controlled_report(directory)
            rows = e.score_driver_report(native, directory, self.history, document["attempts"])
            self.assertTrue(all(row["operational_complete"] for row in rows))
            self.assertTrue(all(row["task_score"]["score"] == 0 for row in rows if row["task_score"]["score"] is not None))
            self.assertTrue(all(row["metadata"]["episode"]["charged"]["inputTokens"] == 24 for row in rows))
            self.assertTrue(all(row["metadata"]["invocation_status"] == "complete" for row in rows))

    def test_missing_runner_attempts_keep_declared_denominators(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); document, native = self.controlled_report(directory, count=1)
            native["fatal_failure"] = "checkpoint_failed"
            rows = e.score_driver_report(native, directory, self.history, document["attempts"])
            summary = e.summarize(rows)
            self.assertTrue(len(rows) == 18 and sum(summary[arm]["attempts"] for arm in e.STRATEGIES) == 18)
            self.assertTrue(sum(summary[arm]["operational_failures"] for arm in e.STRATEGIES) == 17)
            self.assertTrue(sum(summary[arm]["scorable_attempts"] for arm in e.STRATEGIES) == 12)
            self.assertTrue(rows[-1]["metadata"]["resources"] is None)

    def test_no_oracle_before_terminalization_and_ipc_digest_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary); document, native = self.controlled_report(directory)
            native["attempts"][0]["terminalized"] = False
            with patch.object(e, "expected_values", wraps=e.expected_values) as oracle:
                rows = e.score_driver_report(native, directory, self.history, document["attempts"])
                self.assertTrue(rows[0]["task_score"]["score"] == 0)
            # An interrupted attempt does not read its answer IPC or gold values.
            with patch.object(e, "expected_values") as oracle:
                e.factual_score(self.history, self.history["episodes"][0], "", False)
                self.assertTrue(not oracle.called)
            native["attempts"][0]["terminalized"] = True
            native["attempts"][0]["answer_sha256"] = "0" * 64
            with self.assertRaises(e.EvaluationError): e.score_driver_report(native, directory, self.history, document["attempts"])

    def test_arbitrary_provider_text_and_keys_become_only_digests(self):
        secret = "controlled private synthetic sentinel with spaces"
        value = {"failure": secret, secret: {"model": secret}, "episode": {"charged": {"inputTokens": 42}}}
        projected = e.content_free_metadata(value)
        self.assertTrue(secret not in json.dumps(projected))
        self.assertTrue(projected["episode"]["charged"]["inputTokens"] == 42)
        self.assertTrue(projected["failure"]["sha256"] == e.digest(secret.encode()))

    def test_mock_paired_run_content_free_private_and_disposable(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "report.json"
            def execute(_binary, _input, directory, _timeout):
                directory.mkdir(mode=0o700)
                _document, native = self.controlled_report(directory)
                return native
            with patch.object(e, "compile_driver", return_value=(Path("unused"), {"source_sha256": {}})), \
                 patch.object(e, "execute", side_effect=execute), contextlib.redirect_stdout(io.StringIO()) as logs:
                report = e.run(SimpleNamespace(output=output, configuration=e.DEFAULTS, timeout=60))
            encoded = output.read_text()
            forbidden = ["controlled incorrect result", e.DEFAULTS["system"]]
            forbidden += [event["text"] for event in self.history["events"]]
            forbidden += [probe["prompt"] for probe in self.history["episodes"]]
            self.assertTrue(not any(text in encoded or text in logs.getvalue() for text in forbidden))
            self.assertTrue(len(report["attempts"]) == 18)
            self.assertTrue(report["five_category_quality_gate"] == "inconclusive")
            self.assertTrue(os.stat(output).st_mode & 0o777 == 0o600)

    def test_process_timeout_failure_and_invalid_report_keep_all_pairs(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for condition in (subprocess.TimeoutExpired("unused", 60), SimpleNamespace(returncode=1)):
                kwargs = {"side_effect": condition} if isinstance(condition, Exception) else {"return_value": condition}
                with patch.object(e.subprocess, "run", **kwargs):
                    native = e.execute(Path("unused"), directory / "input", directory / "absent", 60)
                document = e.runner_input(self.fixtures, e.DEFAULTS)
                rows = e.score_driver_report(native, directory, self.history, document["attempts"])
                self.assertTrue(len(rows) == 18 and all(not row["operational_complete"] for row in rows))
                self.assertTrue(all(row["task_score"]["score"] == 0 for row in rows if row["task_score"]["score"] is not None))
            output = directory / "report.json"
            with patch.object(e, "compile_driver", return_value=(Path("unused"), {})), \
                 patch.object(e, "execute", return_value={"version": 1, "attempts": [None]}), \
                 contextlib.redirect_stdout(io.StringIO()):
                report = e.run(SimpleNamespace(output=output, configuration=e.DEFAULTS, timeout=60))
            self.assertTrue(len(report["attempts"]) == 18)
            self.assertTrue(report["driver"]["fatal_failure"] == "runner_report_invalid")

    def test_strict_json_duplicate_nonfinite_and_private_output(self):
        for data in (b'{"a":1,"a":2}', b'{"a":NaN}'):
            with self.assertRaises(e.EvaluationError): e.strict_json(data)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "private.json"; e.private_write(path, b"{}")
            self.assertTrue(os.stat(path).st_mode & 0o777 == 0o600)
            with self.assertRaises(FileExistsError): e.private_write(path, b"[]")


NATIVE_BINARY = None


class NativeContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="boros-answer-native-contract-")
        cls.directory = Path(cls.temporary.name).resolve()
        fixture_spec = importlib.util.spec_from_file_location("answer_preparation_fixture", ROOT / "scripts/test_component_preparation.py")
        cls.fixture = importlib.util.module_from_spec(fixture_spec); fixture_spec.loader.exec_module(cls.fixture)
        cls.saved_instructions = "  Synthetic restored café e\u0301\r\nCite exact sources.\n  "
        cls.observed = {"answers": 0, "prior_overlay_leaked": False, "saved_instruction_answers": 0}
        saved_instructions = cls.saved_instructions
        observed, fixture = cls.observed, cls.fixture
        class Handler(fixture.Handler):
            def do_POST(self):
                if self.path == "/v1/chat/completions":
                    data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                    body = json.loads(data)
                    count = fixture.synthetic_count(fixture.FIXTURE.render(body))
                    if body.get("stream") is not True:
                        self.send_json({"model": fixture.MODEL, "choices": [{"message": {"content": "4"}, "finish_reason": "stop"}],
                            "usage": {"prompt_tokens": count, "completion_tokens": 1, "total_tokens": count + 1}})
                        return
                    observed["answers"] += 1
                    messages = body.get("messages", [])
                    if messages and messages[0].get("role") == "system" and messages[0].get("content", "").startswith(saved_instructions + "\n\n"):
                        observed["saved_instruction_answers"] += 1
                    observed["prior_overlay_leaked"] |= any("controlledwronganswersentinel" in message.get("content", "") for message in body.get("messages", []))
                    output = '{"synthetic":true}' if body.get("response_format") == {"type": "json_object"} and body.get("seed") == 43 else "controlledwronganswersentinel"
                    chunks = [{"model": fixture.MODEL, "choices": [{"delta": {"content": output}, "finish_reason": None}]},
                              {"model": fixture.MODEL, "choices": [{"delta": {}, "finish_reason": "stop"}],
                               "usage": {"prompt_tokens": count, "completion_tokens": 1, "total_tokens": count + 1}}]
                    encoded = b"".join(b"data: " + json.dumps(chunk).encode() + b"\n\n" for chunk in chunks) + b"data: [DONE]\n\n"
                    self.send_response(200); self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
                    return
                super().do_POST()
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler); cls.server.daemon_threads = True
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True); cls.thread.start()
        cls.fixtures = e.generate("development", history_count=1)
        cls.history = cls.fixtures["histories"][0]
        cls.document = e.runner_input(cls.fixtures, dict(e.DEFAULTS, endpoint=f"http://127.0.0.1:{cls.server.server_port}/v1"))
        cls.input_path = cls.directory / "input.json"; e.private_write(cls.input_path, e.canonical_json(cls.document))
        cls.output = cls.directory / "output"
        cls.native = e.execute(NATIVE_BINARY, cls.input_path, cls.output, 300)
        cls.rows = e.score_driver_report(cls.native, cls.output, cls.history, cls.document["attempts"])

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=2); cls.temporary.cleanup()

    def test_native_all_pairs_wrong_score_operational_and_content_free(self):
        self.assertTrue(len(self.rows) == 18)
        self.assertTrue(all(row["operational_complete"] for row in self.rows))
        self.assertTrue(all(row["task_score"]["score"] == 0 for row in self.rows if row["task_score"]["score"] is not None))
        self.assertTrue(self.observed["answers"] == 18 and not self.observed["prior_overlay_leaked"])
        encoded = json.dumps(self.rows) + (self.output / "report.json").read_text()
        forbidden = ["controlledwronganswersentinel"] + [event["text"] for event in self.history["events"]]
        forbidden += [probe["prompt"] for probe in self.history["episodes"]]
        self.assertTrue(not any(text in encoded for text in forbidden))

    def test_native_index_is_quiescent_overlay_separate_and_accounted(self):
        self.assertTrue(all(item["overlay_events"] == 2 for item in self.native["attempts"]))
        for item in self.native["attempts"]:
            self.assertTrue(item["background"]["quiescent_during_answer"])
            self.assertTrue(item["background"]["performed"] == (item["strategy"] == "hybrid"))
            self.assertTrue(item["episode"]["charged"]["httpAttempts"] > 0)
            self.assertTrue(item["episode"]["charged"]["modelCalls"] >= 2)

    def test_native_shared_gui_send_stop_and_json_output(self):
        process = subprocess.run([str(NATIVE_BINARY), "--ui-shared-answer-integration-test",
                                  f"http://127.0.0.1:{self.server.server_port}/v1"],
                                 capture_output=True, timeout=100,
                                 env={**os.environ, "BOROS_DATA_DIR": str(self.directory / "gui-runtime")})
        checks = e.strict_json(process.stdout)
        self.assertTrue(process.returncode == 0 and isinstance(checks, dict) and bool(checks))
        self.assertTrue(all(type(value) is bool and value for value in checks.values()))

        self.assertTrue(checks.get("gui_shared_saved_instructions_restored_at_launch") is True)
        for outcome in ("success", "stop", "json_success", "json_invalid"):
            for contract in ("durable_v3_original_input_proof_revalidated", "frozen_output_option_matches_setting",
                             "capture_preserves_provider_bytes", "json_requires_frozen_thinking_off",
                             "original_answer_work_charges_counted_input",
                             "output_preference_saved_without_instruction_changes",
                             "invalid_json_warning_matches_captured_output", "operational_outcome"):
                self.assertTrue(checks.get(f"gui_shared_{outcome}_{contract}") is True)
        for outcome in ("json_success", "json_invalid"):
            self.assertTrue(checks.get(f"gui_shared_{outcome}_captured_object_validity") is True)
            self.assertTrue(checks.get(f"gui_shared_{outcome}_captured_provider_output_unchanged") is True)
        self.assertTrue(self.observed["saved_instruction_answers"] == 4)
        self.assertTrue(self.saved_instructions.encode() not in process.stdout + process.stderr)

    def test_native_sufficient_evidence_control_contracts(self):
        temporary_root = Path(tempfile.gettempdir()).resolve()
        prior_fixtures = set(temporary_root.glob("boros-witness-check-*"))
        process = subprocess.run([str(NATIVE_BINARY), "--evidence-control-integration-test",
                                  f"http://127.0.0.1:{self.server.server_port}/v1"],
                                 capture_output=True, timeout=120,
                                 env={**os.environ, "BOROS_DATA_DIR": str(self.directory / "witness-runtime")})
        checks = e.strict_json(process.stdout)
        self.assertTrue(process.returncode == 0 and isinstance(checks, dict) and bool(checks))
        self.assertTrue(all(type(value) is bool and value for value in checks.values()))
        self.assertTrue(set(temporary_root.glob("boros-witness-check-*")) == prior_fixtures)

        required = ("witness_contract_production_pins_disjoint", "witness_contract_boolean_version_rejected",
                    "witness_contract_witness_projection_rejected_by_version_one",
                    "witness_contract_version_one_configuration_allowance_preserved",
                    "witness_contract_separate_format_configuration_accepted",
                    "witness_contract_format_configuration_requires_separate_pin",
                    "witness_contract_original_configuration_preserved_with_amendment",
                    "witness_contract_format_configuration_other_settings_rejected",
                    "witness_contract_json_object_version_three_accepted",
                    "witness_contract_json_object_field_rejected_in_version_two",
                    "witness_contract_version_three_requires_format",
                    "witness_json_complete_actual_v3_source_body_count_revalidated",
                    "witness_json_complete_actual_frozen_request_mode",
                    "witness_json_complete_captured_receipt_archive_restore_preserved",
                    "witness_complete_actual_v3_source_body_count_revalidated",
                    "witness_reduced_original_pack_outcome_explicit",
                    "witness_reduced_entire_original_union_tamper_rejected",
                    "witness_complete_actual_body_mismatch_rejected",
                    "witness_complete_version_two_cannot_claim_complete_proof",
                    "witness_complete_missing_invocation_cannot_claim_proof",
                    "witness_stopped_actual_v3_source_body_count_revalidated",
                    "witness_stopped_verification_does_not_change_original_debits",
                    "source_control_v6_one_hybrid_attempt_and_exact_ids_decode",
                    "source_control_v6_production_pins_separate_from_all_prior_versions",
                    "source_control_complete_ordinary_v3_counted_source_body_proof_revalidated",
                    "source_control_complete_exact_declared_union_spans_recent_and_cross_conversation_history",
                    "source_control_reduced_explicit_reduction_or_complete_outcome",
                    "source_control_stopped_complete_delivery_is_independent_of_answer_status",
                    "source_control_stopped_terminal_capture_and_original_accounting_preserved")
        self.assertTrue(all(checks.get(name) is True for name in required))

    def test_native_refuses_existing_output_unknown_fields_nondev_and_store(self):
        preserved = e.digest((self.output / "report.json").read_bytes())
        process = subprocess.run([str(NATIVE_BINARY), "--answer-evaluation", str(self.input_path),
                                  "--output-directory", str(self.output)], capture_output=True, timeout=10)
        self.assertTrue(process.returncode != 0)
        self.assertTrue(e.digest((self.output / "report.json").read_bytes()) == preserved)
        for ordinal, document in enumerate(({**self.document, "split": "validation"},
                {**self.document, "split": "held-out"}, {**self.document, "store": "unused"},
                {**self.document, "goldSpans": []},
                {**self.document, "events": [dict(self.document["events"][0], text="controlled changed source"), *self.document["events"][1:]]}, {**self.document, "configuration": {**self.document["configuration"], "unexpected": 1}})):
            path = self.directory / f"rejected-{ordinal}.json"; e.private_write(path, e.canonical_json(document))
            output = self.directory / f"rejected-output-{ordinal}"
            process = subprocess.run([str(NATIVE_BINARY), "--answer-evaluation", str(path),
                                      "--output-directory", str(output)], capture_output=True, timeout=10)
            self.assertTrue(process.returncode != 0 and not output.exists())
            self.assertTrue(not any(probe["prompt"].encode() in process.stdout + process.stderr for probe in self.history["episodes"]))


def load_tests(loader, _suite, _pattern):
    suite = loader.loadTestsFromTestCase(Contracts)
    if NATIVE_BINARY:
        suite.addTests(loader.loadTestsFromTestCase(NativeContracts))
    return suite


class SafeResult(unittest.TestResult):
    def __init__(self):
        super().__init__(); self.failed_names = []; self.error_names = []
    def addFailure(self, test, err):
        super().addFailure(test, err); self.failed_names.append(test.id().rsplit(".", 1)[-1])
    def addError(self, test, err):
        super().addError(test, err); self.error_names.append(test.id().rsplit(".", 1)[-1])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--binary", type=Path)
    arguments = parser.parse_args(); NATIVE_BINARY = arguments.binary.resolve() if arguments.binary else None
    result = SafeResult()
    unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]).run(result)
    print(json.dumps({"checks": result.testsRun, "failed": result.failed_names,
                      "errors": result.error_names, "skipped": len(result.skipped)}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
