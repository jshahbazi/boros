#!/usr/bin/env python3
"""Offline pilot orchestration contracts using synthetic public records only."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import evaluate_orientation_zoom as pilot
import orientation_zoom as memory


def records():
    return [{"event_id": f"public-{i}", "original_session_id": "public-session", "role": "user" if i % 2 == 0 else "assistant",
        "status": "complete", "session_index": 0, "turn_index": i,
        "content": "needle " + str(i), "source_time": None} for i in range(6)]


class CountAPI:
    def count(self, messages, name):
        return len(json.loads(messages[0]["content"]))


class FakeAPI:
    def __init__(self, output):
        self.output, self.operations, self.calls = output, {}, []

    def count(self, messages, name):
        return 100

    def call(self, messages, name, summary=False):
        self.calls.append(name)
        self.operations[name] = {"elapsed_seconds": .01}
        if summary:
            return '{"regions":[{"region_id":"r0000","summary":"Public needle exchange.","source_ids":["public-0"]}]}', {}
        if "-plan-" in name:
            return '{"action":"finish","query":"","region_id":""}', {}
        if name.endswith("-sufficiency"):
            return '{"sufficient":"yes"}', {}
        if name.endswith("-support"):
            return '{"all_claims_supported":"yes","citations_supported":"yes"}', {}
        if name.endswith("-qa"):
            return "yes", {}
        return "Public needle answer [public-0].", {"input_tokens": 100, "output_tokens": 10}


class PilotChecks(unittest.TestCase):
    def test_priority_survives_token_reduction(self):
        history = memory.History(records())
        self.addCleanup(history.close)
        priority = list(reversed(history.blocks))
        packed = history.pack_blocks(priority)
        retained, count = pilot.counted_pack(CountAPI(), history, packed, 2, "public")
        self.assertEqual([r["event_id"] for r in retained], ["public-4", "public-5"])
        self.assertEqual(count, 2)

    def test_recall_uses_original_full_turn_ids(self):
        scorer = {"positive_ids": ["public-1", "public-5"], "gold_sessions": ["public-session", "missing"]}
        result = pilot.recall(records()[:2], scorer)
        self.assertEqual(result, {"positive_turns": 2, "full_positive_turns_delivered": 1, "gold_sessions": 2, "gold_sessions_delivered": 1})

    def test_declared_denominator_and_allocation(self):
        self.assertEqual(len(pilot.CASE_IDS), 30)
        self.assertEqual(len(set(pilot.CASE_IDS)), 30)
        self.assertEqual(len(pilot.SLOTS), 30)
        self.assertEqual(pilot.SLOTS.count("abstention"), 5)
        self.assertEqual(pilot.SLOTS.count("multi-session"), 5)
        self.assertEqual(len(pilot.ARMS), 3)

    def test_reserve_fits_declared_context(self):
        self.assertEqual(pilot.CONFIG["foreground_input_tokens"] + pilot.CONFIG["foreground_output_reserve"], 32768)

    def test_response_model_mismatch(self):
        with self.assertRaises(pilot.Error):
            pilot.parse_response(pilot.canonical({"model": "wrong", "status": "completed"}), 1024)

    def test_unknown_usage_is_not_completed_output(self):
        with self.assertRaises(pilot.Error):
            pilot.parse_response(pilot.canonical({"model": pilot.client.OPENAI_MODEL, "status": "completed", "error": None}), 1024)

    def test_json_private_files_no_clobber(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "private.json"
            pilot.private_json(path, {"public": 1})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                pilot.private_json(path, {"public": 2})

    def test_p95_empty_and_single(self):
        self.assertIsNone(pilot.p95([]))
        self.assertEqual(pilot.p95([1]), 1)

    def test_three_arm_orchestration_and_source_only_reuse(self):
        with tempfile.TemporaryDirectory() as root:
            api = FakeAPI(Path(root))
            case = {"question_id": "public", "question": "Needle?", "question_date": "public-date", "sources": records()}
            scorer = {"reference": "Public needle", "question_type": "single-session-user", "abstention": False,
                      "positive_ids": ["public-0"], "gold_sessions": ["public-session"]}
            with patch.object(pilot.judging, "official_qa_messages", return_value=[{"role": "user", "content": "Public synthetic QA fixture"}]):
                result = pilot.execute_case(api, case, scorer, pilot.judging.DEFAULT_PROTOCOL)
            self.assertEqual(len(result), 3)
            self.assertTrue(all(row["operational_complete"] and row["qa"] == "yes" for row in result))
            sufficiency = [i for i, call in enumerate(api.calls) if call.endswith("-sufficiency")]
            answers = [i for i, call in enumerate(api.calls) if call.endswith("-answer")]
            self.assertEqual(len(sufficiency), 1)
            self.assertLess(sufficiency[0], min(answers))
            self.assertEqual(len({row["pack_sha256"] for row in result}), 1)

    def test_failed_sufficiency_frozen_unknown_and_answers_still_scored(self):
        class FailedSufficiency(FakeAPI):
            def call(self, messages, name, summary=False):
                if name.endswith("-sufficiency"):
                    self.calls.append(name)
                    raise pilot.Error("synthetic_transport_failed")
                return super().call(messages, name, summary)
        with tempfile.TemporaryDirectory() as root:
            api = FailedSufficiency(Path(root))
            case = {"question_id": "public", "question": "Needle?", "question_date": "public-date", "sources": records()}
            scorer = {"reference": "Public needle", "question_type": "single-session-user", "abstention": False,
                      "positive_ids": ["public-0"], "gold_sessions": ["public-session"]}
            with patch.object(pilot.judging, "official_qa_messages", return_value=[{"role": "user", "content": "Public synthetic QA fixture"}]):
                result = pilot.execute_case(api, case, scorer, pilot.judging.DEFAULT_PROTOCOL)
            self.assertEqual(sum(call.endswith("-sufficiency") for call in api.calls), 1)
            self.assertTrue(all(row["sufficiency"] == "unknown" for row in result))
            self.assertTrue(all(row["operational_complete"] and row["qa"] == "yes" for row in result))

    def test_terminal_report_handles_setup_failures_without_timing(self):
        with tempfile.TemporaryDirectory() as root:
            api = FakeAPI(Path(root))
            pilot.private_json(api.output / "declaration.json", {"public": True})
            api.http_calls = api.generation_calls = api.reserved_input = api.reserved_output = 0
            rows = [{"case": case, "arm": arm, "operational_complete": False, "qa": "unknown", "sufficiency": "unknown",
                     "support": "unknown", "citation_support": "unknown", "tool_actions": 0,
                     "positive_turns": 1, "full_positive_turns_delivered": 0} for case in pilot.CASE_IDS for arm in pilot.ARMS]
            result = pilot.report(api, rows)
            self.assertEqual(len(result["attempts"]), 90)
            for arm in pilot.ARMS:
                self.assertEqual(result["summaries"][arm]["qa_unknown"], 30)
                self.assertEqual(result["summaries"][arm]["positive_turns"], 30)
                self.assertIsNone(result["summaries"][arm]["summary_creation_p95_seconds"])


if __name__ == "__main__":
    unittest.main()
