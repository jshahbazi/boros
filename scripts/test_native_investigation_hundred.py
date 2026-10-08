"""Synthetic checks for selection leakage, fixed denominator and crash replay fencing."""
import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import native_investigation_hundred as runner
import native_investigation_hundred_cases as cases


class IdentityOnly(dict):
    def get(self, key, default=None):
        if key not in ("question_id", "question_type"):
            raise AssertionError("selector accessed non-identity category data")
        return super().get(key, default)

    def __getitem__(self, key):
        if key not in ("question_id", "question_type"):
            raise AssertionError("selector accessed non-identity category data")
        return super().__getitem__(key)


def decision_payload(choice="yes"):
    return {"answer": {"type": "choice", "choice": choice,
        "probabilities": {"yes": 1.0 if choice == "yes" else 0.0, "no": 1.0 if choice == "no" else 0.0},
        "confidence": 1.0, "input_tokens": 12}, "input_tokens": 12,
        "model": runner.jev.MODEL, "latency_ms": 1.0, "engine_ms": 1.0, "cache": {"hit": False}}


class Client:
    calls = []
    fail_after_response = None
    fail_before_response = None

    def __init__(self, output):
        self.output = output
        self.index = 0

    def connect(self):
        return {}

    def close(self):
        pass

    def decide(self, arguments, name):
        self.calls.append(name)
        self.index += 1
        if name == self.fail_before_response:
            raise runner.jev.SavedQAError("mcp_deadline")
        request = {"jsonrpc": "2.0", "id": self.index, "method": "tools/call",
            "params": {"name": "jevk5_decide", "arguments": arguments}}
        result = {"structuredContent": decision_payload()}
        response = {"jsonrpc": "2.0", "id": self.index, "result": result}
        request_raw, response_raw = runner.jev.canonical(request), runner.jev.canonical(response)
        runner.e.private_write(self.output / (name + "-request.json"), request_raw)
        runner.e.private_write(self.output / (name + "-response.json"), response_raw)
        runner.write(self.output / (name + "-operation.json"), {"dispatched": True, "received": True,
            "request_sha256": runner.e.digest(request_raw), "response_sha256": runner.e.digest(response_raw)})
        if name == self.fail_after_response:
            raise runner.jev.SavedQAError("mcp_call_failed")
        return runner.jev.validate_decision(result)


class SelectionContracts(unittest.TestCase):
    def test_selection_accesses_only_identity_and_category_and_exact_quota(self):
        rows = [IdentityOnly(question_id=f"public-{index:04d}", question_type=cases.CATEGORIES[index % 6],
            answer="Never access this", has_answer=True) for index in range(151)]
        selected, manifest = cases.select_rows(rows, excluded=("public-0000",), count=100)
        self.assertEqual(len(selected), 100)
        self.assertEqual(sum(manifest["category_quotas"].values()), 100)
        self.assertNotIn("public-0000", selected)
        changed = list(reversed(rows))
        self.assertEqual(selected, cases.select_rows(changed, excluded=("public-0000",), count=100)[0])

    def test_annotation_changes_cannot_change_selection(self):
        rows = [{"question_id": f"public-{index:04d}", "question_type": cases.CATEGORIES[index % 6],
            "answer": "A", "has_answer": False, "question": "Q"} for index in range(150)]
        first = cases.select_rows(rows, excluded=(), count=100)[0]
        for row in rows:
            row.update(answer="B", has_answer=True, question="changed content")
        self.assertEqual(first, cases.select_rows(rows, excluded=(), count=100)[0])

    def test_opaque_projection_contains_no_original_identity_or_oracle(self):
        qid = "public-example_abs"
        case = {"id": qid, "row": {"answer": "Private reference", "question_type": "single-session-user",
            "answer_session_ids": ["Private session"], "haystack_session_ids": ["Private session"],
            "haystack_sessions": [[{"role": "user", "content": "Original", "has_answer": True}]]},
            "events": [{"id": qid + "-s0000-m0000", "project_id": "longmemeval-" + qid,
                "conversation_key": "session-0000", "role": "user", "status": "complete", "text": "Original", "source_time": None}],
            "attempts": [{"project_id": "longmemeval-" + qid, "conversation_key": "session-0000",
                "prompt": "Public question", "question_time": None}]}
        document = cases.runner_input(cases._history(case, 0))
        raw = runner.jev.canonical(document)
        for forbidden in (qid, "_abs", "Private reference", "Private session", "has_answer", "question_type"):
            self.assertNotIn(forbidden.encode(), raw)
        self.assertEqual(document["events"][0]["text"], "Original")
        self.assertEqual(len(document["attempts"]), 1)
        self.assertEqual(document["attempts"][0]["strategy"], "hybrid")
        for identity in (document["history_id"], document["events"][0]["id"], document["events"][0]["project_id"],
            document["events"][0]["conversation_key"], document["attempts"][0]["probe_id"]):
            self.assertRegex(identity, "^[0-9a-f]{64}$")


class ExecutionContracts(unittest.TestCase):
    def setUp(self):
        Client.calls = []
        Client.fail_after_response = Client.fail_before_response = None

    def fixture(self, output):
        metadata = [{"question_id": f"public-{i}", "question_type": "single-session-user", "abstention": False}
                    for i in range(100)]
        runner.write(output / "declaration.json", {"binary": "public-synthetic", "cases": metadata,
            "artifacts": {f"input-{i}.json": "public-pin" for i in range(100)}})
        runner.write(output / "controls.json", [{"name": str(i), "expected": "yes", "arguments": {}} for i in range(6)])
        for i in range(100):
            runner.write(output / f"input-{i}.json", {})
            runner.write(output / f"scorer-{i}.json", {"episodes": [{"question_type": "single-session-user",
                "question_id": f"public-{i}", "prompt": "Public synthetic question", "answer": "Public synthetic answer",
                "abstention": False}]})

    def capture(self, output, declaration, ordinal):
        return {"ordinal": ordinal, "question_id": f"public-{ordinal}", "status": "completed", "operational_complete": True,
            "answer_sha256": runner.e.digest(b"Public synthetic answer"), "answer_bytes": 23,
            "delivery": {}, "metadata": {"full_host_milliseconds": 1000}, "failure_code": None,
            "native_report_sha256": "public-native-pin"}

    def run_process(self, calls):
        def run(command, **kwargs):
            calls.append(command)
            self.assertEqual(kwargs["timeout"], 400)
            directory = Path(command[4]); directory.mkdir()
            runner.write(directory / "report.json", {})
            runner.e.private_write(directory / "answer-0000.txt", b"Public synthetic answer")
            return SimpleNamespace(stdout=b"", stderr=b"", returncode=0)
        return run

    def patches(self):
        return patch.object(runner, "verify"), patch.object(runner, "capture_case", side_effect=self.capture), \
            patch.object(runner.judging, "official_qa_messages", return_value=[{"content": "Public synthetic grading prompt"}])

    def test_exactly_hundred_attempts_106_decisions_and_completed_resume_no_replay(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary); self.fixture(output); calls = []
            a, b, c = self.patches()
            with a, b, c:
                first = runner.execute(output, Client, self.run_process(calls), progress=False)
                second = runner.execute(output, Client, self.run_process(calls), progress=False)
            self.assertIsNone(first["halt"])
            self.assertIsNone(second["halt"])
            self.assertEqual(len(calls), 100)
            self.assertEqual(len(Client.calls), 106)
            self.assertEqual(second["summary"]["accepted"], 100)
            self.assertTrue(all(command[-1] == "--investigate-memory" for command in calls))

    def test_ambiguous_judgment_never_replays_and_preserves_denominator(self):
        Client.fail_before_response = "answer-0000"
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary); self.fixture(output); calls = []
            a, b, c = self.patches()
            with a, b, c:
                first = runner.execute(output, Client, self.run_process(calls), progress=False)
                Client.fail_before_response = None
                second = runner.execute(output, Client, self.run_process(calls), progress=False)
            self.assertEqual(len(calls), 1)
            self.assertEqual(len(Client.calls), 7)
            self.assertEqual(second["halt"], "hundred_ambiguous_judge_dispatch")
            self.assertEqual(len(second["attempts"]), 100)
            self.assertEqual(second["summary"]["not_run"], 99)

    def test_completed_judge_receipt_recovers_after_host_failure_without_new_grade(self):
        Client.fail_after_response = "answer-0000"
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary); self.fixture(output); calls = []
            a, b, c = self.patches()
            with a, b, c:
                first = runner.execute(output, Client, self.run_process(calls), progress=False)
                Client.fail_after_response = None
                second = runner.execute(output, Client, self.run_process(calls), progress=False)
            self.assertEqual(first["summary"]["scored"], 0)
            self.assertIsNone(second["halt"])
            self.assertEqual(len(calls), 100)
            self.assertEqual(len(Client.calls), 106)
            self.assertEqual(second["summary"]["scored"], 100)

    def test_ambiguous_answer_intent_cannot_rerun(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary); self.fixture(output); calls = []
            runner.write(output / "question-0-dispatch.json", {"public": "ambiguous"})
            a, b, c = self.patches()
            with a, b, c:
                report = runner.execute(output, Client, self.run_process(calls), progress=False)
            self.assertEqual(calls, [])
            self.assertEqual(report["halt"], "hundred_ambiguous_answer_dispatch")
            self.assertEqual(len(report["attempts"]), 100)

    def test_case_failure_continues_infrastructure_failure_stops(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary); self.fixture(output); calls = []
            def capture(output, declaration, ordinal):
                result = self.capture(output, declaration, ordinal)
                if ordinal == 0:
                    result.update(status="case_failure", operational_complete=False, failure_code="native_investigation_format_failed")
                if ordinal == 2:
                    raise runner.e.EvaluationError("hundred_unknown_or_unhealthy_accounting")
                return result
            with patch.object(runner, "verify"), patch.object(runner, "capture_case", side_effect=capture), \
                 patch.object(runner.judging, "official_qa_messages", return_value=[{"content": "Public synthetic grading prompt"}]):
                report = runner.execute(output, Client, self.run_process(calls), progress=False)
            self.assertEqual(len(calls), 3)
            self.assertEqual(report["summary"]["case_failures"], 1)
            self.assertEqual(report["summary"]["scored"], 1)
            self.assertEqual(report["halt"], "hundred_unknown_or_unhealthy_accounting")

    def test_native_mode_accounting_and_failure_classifier(self):
        native = {"mode": runner.VERSION, "preparation_mode": runner.PREPARATION_MODE, "declared_attempts": 1,
            "attempts": [{"memory_investigation": True, "terminalized": True, "capture_healthy": True,
                "accounting_healthy": True, "episode": {"unknownInputOperations": 0, "held": {"modelCalls": 0}},
                "unknown_output_operations": 0, "unresolved_work_count": 0,
                "failure": "native_investigation_format_failed"}]}
        self.assertEqual(runner.assert_native(native, {"operational_complete": False}), "case_failure")
        for mutation in ({"memory_investigation": False}, {"accounting_healthy": False}, {"failure": "provider_count_mismatch"},
            {"unknown_output_operations": 1}, {"unresolved_work_count": 1}):
            changed = copy.deepcopy(native); changed["attempts"][0].update(mutation)
            with self.assertRaises(runner.e.EvaluationError):
                runner.assert_native(changed, {"operational_complete": False})
        changed = copy.deepcopy(native); changed["attempts"][0]["episode"]["held"]["modelCalls"] = 1
        with self.assertRaises(runner.e.EvaluationError):
            runner.assert_native(changed, {"operational_complete": False})

    def test_scorer_v8_single_arm_and_provenance(self):
        history = {"id": "opaque-history", "events": [{"id": "opaque-event", "project_id": "opaque-project",
            "conversation_key": "opaque-conversation", "role": "user", "status": "complete", "text": "Public source", "source_time": None}],
            "source_labels": [{"event_id": "opaque-event", "session_id": "private-session"}],
            "episodes": [{"id": "opaque-probe", "question_id": "public-case", "project_id": "opaque-project",
                "conversation_key": "opaque-conversation", "prompt": "Public question", "question_time": None,
                "answer": "Public answer", "question_type": "single-session-user", "abstention": False,
                "answer_session_ids": ["private-session"]}]}
        document = cases.runner_input(history)
        with tempfile.TemporaryDirectory() as temporary:
            result, _ = runner.evaluation.score_native({"version": 1, "attempts": []}, Path(temporary), history,
                document, configuration=cases.CONFIGURATION, runner_document_version=8)
            self.assertEqual(len(result), 1)
            self.assertFalse(result[0]["operational_complete"])
            for mutate in (lambda d: d["attempts"].append(copy.deepcopy(d["attempts"][0])),
                lambda d: d["attempts"][0].update(strategy="recent_only"),
                lambda d: d.update(history_id="changed")):
                altered = copy.deepcopy(document); mutate(altered)
                with self.assertRaises(runner.e.EvaluationError):
                    runner.evaluation.score_native({"version": 1, "attempts": []}, Path(temporary), history,
                        altered, configuration=cases.CONFIGURATION, runner_document_version=8)

    def test_denominator_cannot_shrink(self):
        with self.assertRaises(runner.e.EvaluationError):
            runner.summary([{ "ordinal": i} for i in range(99)])


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    result = unittest.TextTestRunner(stream=__import__("sys").stderr).run(suite)
    print(json.dumps({"checks": result.testsRun, "failed": len(result.failures), "errors": len(result.errors)}))
    raise SystemExit(not result.wasSuccessful())
