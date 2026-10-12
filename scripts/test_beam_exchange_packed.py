#!/usr/bin/env python3
"""Synthetic contracts for the BEAM exchange_packed driver: the ported OptChat grader request, verdict
parser and calibration controls, and the job order. No network, gcloud, credentials or OptChat data."""
from __future__ import annotations

import io
import json
import unittest

import beam_exchange_packed as beam

QUESTION = {"id": "q-1", "category": "knowledge_update", "question": "Which city now?", "referenceAnswer": "Lyon",
            "rubric": "Names Lyon.", "nativeAuthorReference": {"category": "knowledge_update", "nativeOrder": 3,
                                                               "questionObject": {"question": "Which city now?"}}}


class Contracts(unittest.TestCase):
    def test_verdict_parser_matches_the_optchat_contract(self):
        good = {"correct": True, "grounded": None, "confidence": "high"}
        self.assertEqual(beam.parse_verdict('{"correct":true,"grounded":null,"confidence":"high"}'), good)
        self.assertEqual(beam.parse_verdict('```json\n{"correct":true,"grounded":null,"confidence":"high"}\n```'), good)
        self.assertEqual(beam.parse_verdict('  {"confidence":"low","correct":false,"grounded":null}  ')["correct"], False)
        for text in ('{"correct":true,"grounded":null}', '{"correct":"yes","grounded":null,"confidence":"high"}',
                     '{"correct":true,"grounded":null,"confidence":"medium"}',
                     '{"correct":true,"grounded":null,"confidence":"high","why":"x"}',
                     'Verdict: ```json\n{"correct":true,"grounded":null,"confidence":"high"}\n``` {x}',
                     '```\n{"correct":true,"grounded":null,"confidence":"high"}\n```\n```\n{}\n```', "true", ""):
            with self.subTest(text=text):
                self.assertIsNone(beam.parse_verdict(text))

    def test_grade_request_is_the_optchat_shape_without_evidence(self):
        messages = beam.grade_messages(QUESTION, "It is Lyon.")
        self.assertEqual([message["role"] for message in messages], ["system", "user"])
        self.assertEqual(messages[0]["content"], beam.GRADER_INSTRUCTION)
        self.assertTrue(messages[1]["content"].startswith('{"question":"Which city now?","category":"knowledge_update",'
                                                          '"referenceAnswer":"Lyon","nativeRubric":"Names Lyon.",'))
        data = json.loads(messages[1]["content"])
        self.assertEqual(list(data), ["question", "category", "referenceAnswer", "nativeRubric", "nativeAuthorReference",
                                      "candidate"])
        self.assertNotIn("deliveredEvidence", data)
        self.assertEqual(beam.js_json({"a": "é", "b": [1, None]}), '{"a":"é","b":[1,null]}')
        self.assertIn("Return no rationale, extra fields, or surrounding prose.", beam.GRADER_INSTRUCTION)
        self.assertEqual(beam.GRADER_INSTRUCTION.count("\n"), 11)

    def test_calibration_has_one_positive_and_one_fabricated_negative_per_question(self):
        second = dict(QUESTION, id="q-2", referenceAnswer=" ")
        controls = beam.calibration_controls([QUESTION, second])
        self.assertEqual([control["kind"] for control in controls], ["positive", "negative", "negative"])
        self.assertEqual(controls[0]["candidate"], "Lyon")
        self.assertIn("BEAM_FALSE_", controls[1]["candidate"])
        self.assertIn("Neptune on day 73", controls[1]["candidate"])
        self.assertNotEqual(controls[1]["candidate"], controls[2]["candidate"])

    def test_majority_vote_never_counts_invalid_replicates(self):
        yes, no = {"correct": True}, {"correct": False}
        self.assertTrue(beam.majority([yes, yes, no]))
        self.assertFalse(beam.majority([no, None, no]))
        self.assertIsNone(beam.majority([yes, None, no]))
        self.assertIsNone(beam.majority([None, None, yes]))

    def test_answer_jobs_alternate_arms_and_cover_three_replicates(self):
        rows = [{"label": label, "arm": arm} for label in ("a", "b") for arm in beam.ARMS]
        jobs = beam.answer_jobs(rows)
        self.assertEqual(len(jobs), 2 * len(beam.ARMS) * beam.REPLICATES)
        self.assertEqual([job["arm"] for job in jobs[:4]], ["ordinary_send", "exchange_packed",
                                                           "exchange_packed", "ordinary_send"])
        self.assertEqual(beam.label_of("abc"), "ba7816bf8f01cfea")
        self.assertEqual(beam.event_sequence('["archive-x",0,17]'), 17)

    def test_gold_delivery_scores_resolved_messages(self):
        events = [{"id": '["a",0,1]', "text": "abcd"}, {"id": '["a",0,2]', "text": "efgh"}]
        whole = beam.gold_delivery(events, [1, 2], ['["a",0,1]'], [{"event_id": '["a",0,2]', "offset": 0, "bytes": 4}])
        self.assertEqual(whole["gold_delivery"], "whole")
        partial = beam.gold_delivery(events, [1, 2], [], [{"event_id": '["a",0,2]', "offset": 0, "bytes": 2}])
        self.assertEqual((partial["gold_delivery"], partial["gold_turns_any_bytes"]), ("partial", 1))
        self.assertEqual(beam.gold_delivery(events, [], [], [])["gold_delivery"], "no_gold_turns")


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
