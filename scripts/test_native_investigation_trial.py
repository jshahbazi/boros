"""Public synthetic dispatch-fence and fixed-denominator contracts."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import native_investigation_trial as trial


class Client:
    decisions = []
    controls_pass = True

    def __init__(self, output):
        self.closed = False
        self.decisions.clear()

    def connect(self):
        return {}

    def decide(self, request, name):
        self.decisions.append(name)
        return {"choice": "yes" if self.controls_pass else "no"}

    def close(self):
        self.closed = True


class Contracts(unittest.TestCase):
    def fixture(self, output):
        trial.write(output / "declaration.json", {"binary": "public-synthetic", "pair_process_timeout_seconds": 660})
        trial.write(output / "controls.json", [{"name": str(n), "expected": "yes", "arguments": {}} for n in range(6)])
        for ordinal in range(3):
            trial.write(output / f"input-{ordinal}.json", {})
            trial.write(output / f"scorer-{ordinal}.json", {"episodes": [{"question_type": "single-session-user",
                "prompt": "Public synthetic question", "answer": "Public synthetic answer", "abstention": False}]})

    def native(self, completed=True):
        return {"mode": trial.VERSION, "preparation_mode": "native-investigation-paired-v1", "attempts": [
            {"memory_investigation": False}, {"memory_investigation": True, "preparation": {"context_audit": {
            "retrieval": {"native_investigation": {"version": "native-investigation-v1", "private_stages": 2,
            "derived_notes_in_final_request": False}}}}}]}

    def scores(self, completed=True):
        return [{"operational_complete": completed, "answer_sha256": trial.e.digest(b"Public synthetic answer"),
                 "answer_bytes": 23, "delivery": {}, "metadata": {}} for _ in range(2)], []

    def run_trial(self, *, completed=True, controls=True, timeout_after_first=False):
        Client.controls_pass = controls
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            self.fixture(output)
            calls = []

            def run(command, **kwargs):
                calls.append(command)
                if timeout_after_first and len(calls) == 2:
                    raise trial.subprocess.TimeoutExpired("public-synthetic", 660, output=b"public-synthetic")
                directory = Path(command[4]); directory.mkdir()
                trial.write(directory / "report.json", self.native())
                for ordinal in range(2):
                    trial.e.private_write(directory / f"answer-{ordinal:04d}.txt", b"Public synthetic answer")
                return SimpleNamespace(stdout=b"", stderr=b"", returncode=0)

            with patch.object(trial, "verify"), patch.object(trial.evaluation, "score_native", return_value=self.scores(completed)), \
                 patch.object(trial.judging, "official_qa_messages", return_value=[{"content": "Public synthetic grade"}]):
                report = trial.execute(output, Client, run)
                with self.assertRaises(FileExistsError):
                    trial.execute(output, Client, run)
            return report, calls, list(Client.decisions)

    def test_six_attempts_twelve_decisions_and_one_shot(self):
        report, calls, decisions = self.run_trial()
        self.assertIsNone(report["halt"])
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(decisions), 12)
        self.assertEqual(report["summary"]["native_investigation"]["accepted"], 3)
        self.assertTrue(all(command[-1] == "--investigate-memory" for command in calls))

    def test_operational_failure_stops_next_histories(self):
        report, calls, decisions = self.run_trial(completed=False)
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(decisions), 6)
        self.assertEqual(len(report["attempts"]), 6)
        self.assertEqual(sum(r["status"] == "not_run" for r in report["attempts"]), 4)
        self.assertEqual(report["halt"], "trial_native_attempt_incomplete")

    def test_failed_controls_prevent_answer_dispatch(self):
        report, calls, decisions = self.run_trial(controls=False)
        self.assertEqual(calls, [])
        self.assertEqual(len(decisions), 6)
        self.assertEqual(report["halt"], "trial_public_controls_failed")
        self.assertEqual(sum(r["status"] == "not_run" for r in report["attempts"]), 6)

    def test_later_timeout_keeps_earlier_completed_answers_scorable(self):
        report, calls, decisions = self.run_trial(timeout_after_first=True)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(decisions), 8)
        self.assertEqual(report["halt"], "trial_native_process_timeout")
        self.assertTrue(all(r["judgment"] is not None for r in report["attempts"][:2]))
        self.assertEqual(sum(r["status"] == "not_run" for r in report["attempts"]), 2)

    def test_explicit_undispatched_skip_is_not_incomplete(self):
        score = {"operational_complete": False, "failure_code": "native_attempt_interrupted"}
        item = {"terminalized": False, "failure": "trial_stopped_after_operational_failure"}
        self.assertEqual(trial.status(score, item), "not_run")
        self.assertEqual(trial.status(score, {"terminalized": False, "failure": "unknown"}), "incomplete")

    def test_mode_cannot_silently_be_ordinary_hybrid(self):
        native = self.native()
        native["attempts"][1]["memory_investigation"] = False
        with self.assertRaises(trial.e.EvaluationError):
            trial.assert_investigation(native, self.scores()[0])
        native = self.native()
        native["attempts"][1]["preparation"]["context_audit"]["retrieval"]["native_investigation"]["private_stages"] = 0
        with self.assertRaises(trial.e.EvaluationError):
            trial.assert_investigation(native, self.scores()[0])

    def test_missing_attempts_cannot_shrink_denominator(self):
        with self.assertRaises(trial.e.EvaluationError):
            trial.summary(trial.empty_rows()[:-1])


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Contracts)
    result = unittest.TextTestRunner(stream=__import__("sys").stderr).run(suite)
    print(json.dumps({"checks": result.testsRun, "failed": len(result.failures), "errors": len(result.errors)}))
    raise SystemExit(not result.wasSuccessful())
