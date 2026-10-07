#!/usr/bin/env python3
"""Synthetic contracts for separate source sufficiency and answer assessment."""
import inspect
import json
from pathlib import Path
import tempfile
import unittest

import orientation_zoom_judging as judge


def records():
    return [{"event_id": "public-s0000-m0000", "original_session_id": "public-session",
             "role": "user", "status": "complete", "session_index": 0, "turn_index": 0,
             "content": "The public sample object is cedar.", "source_time": None}]


class JudgingContracts(unittest.TestCase):
    def test_source_only_request_has_no_candidate_parameter_or_field(self):
        self.assertNotIn("candidate", inspect.signature(judge.sufficiency_messages).parameters)
        message = judge.sufficiency_messages("What material?", "public-question-date",
                                              "The object is cedar.", records())
        value = json.loads(message[1]["content"])
        self.assertEqual(set(value), {"question", "question_date", "scorer_reference", "original_records"})
        self.assertIn("There is no candidate answer", message[0]["content"])
        with self.assertRaises(TypeError):
            judge.sufficiency_messages("What material?", "public-question-date", "Cedar", records(),
                                       candidate="Glass")

    def test_reference_is_not_original_evidence(self):
        message = judge.sufficiency_messages("What material?", "public-question-date",
                                              "SCORER-ONLY-EXPECTED-FACT", records())
        value = json.loads(message[1]["content"])
        self.assertNotIn("SCORER-ONLY", json.dumps(value["original_records"]))
        self.assertIn("never source evidence", message[0]["content"])
        self.assertIn("partial retrieved pack cannot", message[0]["content"])

    def test_support_request_has_no_reference_or_sufficiency_field(self):
        self.assertNotIn("reference", inspect.signature(judge.support_messages).parameters)
        message = judge.support_messages("What material?", "public-question-date", "Cedar", records())
        value = json.loads(message[1]["content"])
        self.assertEqual(set(value), {"question", "question_date", "candidate_answer", "original_records"})
        self.assertNotIn("sufficient", judge.SUPPORT_FIELDS)
        self.assertIn("Source-ID existence alone does not establish support", message[0]["content"])

    def test_original_allowlist_rejects_scorer_fields(self):
        for field, value in (("has_answer", True), ("answer", "Cedar"),
                             ("answer_session_ids", ["public-session"]), ("candidate", "Cedar")):
            values = records()
            values[0][field] = value
            with self.assertRaisesRegex(judge.JudgingError, "judge_record_fields_invalid"):
                judge.original_records(values)

    def test_source_copy_preserves_unicode_order_and_metadata(self):
        values = records()
        values[0]["content"] = "Café: \"cedar\"\nA second line."
        values[0]["source_time"] = {"value": "public-time", "precision": "minute",
            "timezone": "unspecified", "source_sha256": "a" * 64,
            "locator": "/public/time", "original_value": "public-original-time"}
        copied = judge.original_records(values)
        self.assertEqual(copied, values)
        copied[0]["source_time"]["original_value"] = "changed"
        self.assertEqual(values[0]["source_time"]["original_value"], "public-original-time")

    def test_source_types_states_and_duplicate_identity(self):
        for field, value in (("session_index", True), ("turn_index", -1),
                             ("role", "system"), ("status", "partial"),
                             ("content", 12), ("event_id", "")):
            values = records()
            values[0][field] = value
            with self.assertRaises(judge.JudgingError):
                judge.original_records(values)
        with self.assertRaisesRegex(judge.JudgingError, "judge_duplicate_record"):
            judge.original_records(records() + records())

    def test_unknown_source_time_is_preserved(self):
        self.assertIsNone(judge.original_records(records())[0]["source_time"])
        invalid = records()
        invalid[0]["source_time"] = {"value": "public-time", "has_answer": True}
        with self.assertRaisesRegex(judge.JudgingError, "judge_source_time_invalid"):
            judge.original_records(invalid)

    def test_sufficiency_and_support_accept_unknown_independently(self):
        self.assertEqual(judge.parse_sufficiency('{"sufficient":"unknown"}'), {"sufficient": "unknown"})
        self.assertEqual(judge.parse_support('{"all_claims_supported":"yes","citations_supported":"unknown"}'),
                         {"all_claims_supported": "yes", "citations_supported": "unknown"})

    def test_sufficiency_strict_shape_and_labels(self):
        invalid = ['{"sufficient":"yes","sufficient":"no"}', '{"sufficient":true}',
                   '{"sufficient":"YES"}', '{"sufficient":"yes","candidate":"cedar"}',
                   '{"sufficient":NaN}', '```json\n{"sufficient":"yes"}\n```',
                   '{"sufficient":"yes"} trailing', '[{"sufficient":"yes"}]']
        for text in invalid:
            with self.subTest(text=text), self.assertRaises(judge.JudgingError):
                judge.parse_sufficiency(text)

    def test_support_strict_shape_and_labels(self):
        invalid = ['{"all_claims_supported":"yes"}',
                   '{"all_claims_supported":"yes","citations_supported":false}',
                   '{"all_claims_supported":"yes","citations_supported":"yes","sufficient":"yes"}',
                   '{"all_claims_supported":"yes","citations_supported":"yes","citations_supported":"no"}']
        for text in invalid:
            with self.subTest(text=text), self.assertRaises(judge.JudgingError):
                judge.parse_support(text)

    def test_official_qa_strict_terminal_label(self):
        self.assertEqual(judge.parse_official_qa(" YES\n"), {"correct": "yes"})
        for text in ("yes because cedar", "yes/no", "unknown", '"yes"', "no, yes"):
            with self.assertRaises(judge.JudgingError):
                judge.parse_official_qa(text)

    def test_pack_hash_cannot_depend_on_candidate(self):
        before = judge.pack_identity("What material?", "public-question-date", records())
        judge.support_messages("What material?", "public-question-date", "Cedar", records())
        after = judge.pack_identity("What material?", "public-question-date", records())
        self.assertEqual(before, after)
        changed = records()
        changed[0]["content"] += " A changed fact."
        self.assertNotEqual(before, judge.pack_identity("What material?", "public-question-date", changed))
        self.assertNotEqual(before, judge.pack_identity("Which material?", "public-question-date", records()))

    def test_completed_answers_always_eligible(self):
        self.assertTrue(judge.score_eligibility("completed"))
        self.assertEqual(list(inspect.signature(judge.score_eligibility).parameters), ["answer_status"])
        for status in ("failed", "partial", "unknown", "not_dispatched"):
            self.assertFalse(judge.score_eligibility(status))

    def test_official_protocol_rejects_unpinned_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "protocol.py"
            path.write_text("def get_anscheck_prompt(*args, **kwargs):\n    return 'yes'\n")
            with self.assertRaisesRegex(judge.JudgingError, "judge_protocol_invalid"):
                judge.official_qa_messages("single-session-user", "What material?", "Cedar", "Cedar", False, path)

    def test_official_protocol_matches_exact_upstream_prompt(self):
        if not judge.DEFAULT_PROTOCOL.is_file():
            self.skipTest("pinned upstream private runtime source unavailable")
        function, raw = judge.qa.load_prompt_function(judge.DEFAULT_PROTOCOL)
        self.assertEqual(judge.digest(raw), judge.PROTOCOL_SHA256)
        for category in set(judge.qa.CASE_TYPES):
            for abstention in (False, True):
                expected = function(category, "Public sample question?", "Public sample reference.",
                                    "Public sample candidate.", abstention=abstention)
                actual = judge.official_qa_messages(category, "Public sample question?", "Public sample reference.",
                                                     "Public sample candidate.", abstention)
                self.assertEqual(actual, [{"role": "user", "content": expected}])

    def test_strict_question_reference_and_abstention_types(self):
        with self.assertRaises(judge.JudgingError):
            judge.sufficiency_messages("What material?", "public-date", True, records())
        with self.assertRaises(judge.JudgingError):
            judge.support_messages("What material?", None, "Cedar", records())
        with self.assertRaises(judge.JudgingError):
            judge.official_qa_messages("single-session-user", "What material?", "Cedar", "Cedar", 1)


if __name__ == "__main__":
    unittest.main()
