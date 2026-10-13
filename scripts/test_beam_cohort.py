#!/usr/bin/env python3
"""Synthetic contracts for the BEAM cohort builder: date conversion, source-time shape, normalization of a
parquet-shaped row, reference fields, gold resolution and harness events. No parquet, network or OptChat data."""
from __future__ import annotations

import io
import json
import unittest

import beam_cohort as cohort

PARQUET_SHA = "0" * 64


def row(conversation_id="7"):
    chat = [[{"id": 0, "role": "user", "content": "I started the garden project.", "time_anchor": "March-15-2024",
              "index": "1,1", "question_type": "main_question"},
             {"id": 1, "role": "assistant", "content": "Great, tell me more.", "time_anchor": None, "index": None,
              "question_type": None}],
            [{"id": 2, "role": "user", "content": "The garden now has tomatoes.", "time_anchor": "April-05-2024",
              "index": "2,2", "question_type": "main_question"},
             {"id": 3, "role": "assistant", "content": "Tomatoes like sun.", "time_anchor": None, "index": None,
              "question_type": None}]]
    probes = {category: [] for category in cohort.CATEGORIES}
    probes["summarization"] = [{"question": "Give me a summary of the garden.", "rubric": ["mentions tomatoes"],
                                "ideal_summary": "A garden with tomatoes.", "source_chat_ids": [0, 2, 99]}]
    probes["knowledge_update"] = [{"question": "What is in the garden now?", "rubric": "Says tomatoes.", "answer": "Tomatoes",
                                   "source_chat_ids": {"original_info": [0], "updated_info": [2]}}]
    probes["abstention"] = [{"question": "What did I say about roses?", "rubric": "Abstains.", "ideal_response": "Nothing was said.",
                             "plan_reference": "Batch 1"}]
    return {"conversation_id": conversation_id, "chat": chat, "probing_questions": repr(probes)}


class Contracts(unittest.TestCase):
    def test_iso_date_accepts_only_beam_anchors(self):
        self.assertEqual(cohort.iso_date("January-05-2024"), "2024-01-05")
        self.assertEqual(cohort.iso_date("December-31-2025"), "2025-12-31")
        for bad in ("2024-01-05", "Jan-05-2024", "January-5-2024", "", None, "Smarch-01-2024"):
            with self.subTest(bad=bad):
                with self.assertRaises(cohort.CohortError):
                    cohort.iso_date(bad)

    def test_source_time_is_the_schema_ten_object(self):
        value = cohort.source_time("2024-03-15", 2, PARQUET_SHA)
        self.assertEqual(set(value), {"value", "precision", "timezone", "source_sha256", "locator", "original_value"})
        self.assertEqual((value["value"], value["precision"], value["timezone"], value["original_value"]),
                         ("2024-03-15", "day", "unspecified", "2024-03-15"))
        self.assertEqual(value["locator"], "/chat/2/0/time_anchor")

    def test_normalize_carries_session_dates_references_and_gold(self):
        case = cohort.normalize("100K", row(), PARQUET_SHA)
        self.assertEqual([m["seq"] for m in case["messages"]], [0, 1, 2, 3])
        self.assertEqual([m["date"] for m in case["messages"]], ["2024-03-15", "2024-03-15", "2024-04-05", "2024-04-05"])
        self.assertEqual([m["session"] for m in case["messages"]], [0, 0, 1, 1])
        self.assertEqual(len(case["sessions"]), 2)
        questions = {q["category"]: q for q in case["questions"]}
        self.assertEqual(len(case["questions"]), 3)
        self.assertEqual(questions["summarization"]["referenceAnswer"], None)
        self.assertEqual(questions["summarization"]["rubric"], '["mentions tomatoes"]')
        self.assertEqual(questions["summarization"]["resolvedMessageSeqs"], [0, 2])
        self.assertEqual(questions["knowledge_update"]["referenceAnswer"], "Tomatoes")
        self.assertEqual(questions["knowledge_update"]["resolvedMessageSeqs"], [0, 2])
        self.assertEqual(questions["abstention"]["referenceAnswer"], "Nothing was said.")
        self.assertEqual(questions["abstention"]["resolvedMessageSeqs"], [])
        self.assertEqual(questions["summarization"]["nativeAuthorReference"]["questionObject"]["ideal_summary"], "A garden with tomatoes.")
        self.assertEqual(len(questions["summarization"]["id"]), 24)
        reused = cohort.normalize("100K", row(), PARQUET_SHA, reuse={("summarization", 0): "x" * 24})
        self.assertEqual({q["category"]: q["id"] for q in reused["questions"]}["summarization"], "x" * 24)
        self.assertEqual(case["source"], {"scale": "100K", "conversationId": "7", "parquetSHA256": PARQUET_SHA,
                                          "license": "CC BY-SA 4.0", "normalization": cohort.VERSION})

    def test_normalize_refuses_broken_rows(self):
        broken = row()
        broken["chat"][1][0]["id"] = 5
        with self.assertRaises(cohort.CohortError):
            cohort.normalize("100K", broken, PARQUET_SHA)
        missing = row()
        missing["chat"][0][0]["time_anchor"] = None
        with self.assertRaises(cohort.CohortError):
            cohort.normalize("100K", missing, PARQUET_SHA)

    def test_events_are_complete_dated_harness_events(self):
        case = cohort.normalize("500K", row("3"), PARQUET_SHA)
        events = cohort.events_of(case)
        self.assertEqual(len(events), 4)
        self.assertEqual(events[2]["id"], '["beam-500K-3",0,2]')
        self.assertEqual(events[2]["conversation_key"], "beam-500K-3")
        self.assertEqual(events[2]["project_id"], cohort.PROJECT)
        self.assertEqual((events[2]["role"], events[2]["status"]), ("user", "complete"))
        self.assertEqual(events[2]["source_time"]["value"], "2024-04-05")
        self.assertEqual(json.loads(events[3]["id"])[2], 3)
        self.assertEqual(cohort.flatten_references({"a": [1, "x"], "b": 2}), [1, 2])
        self.assertEqual(cohort.flatten_references(None), [])

    def test_public_question_carries_no_text(self):
        case = cohort.normalize("100K", row(), PARQUET_SHA)
        public = cohort.public_question(case, case["questions"][0])
        self.assertEqual(set(public), {"label", "id", "category", "native_order", "scale", "conversation_id", "gold_turns",
                                       "has_reference_answer", "question_sha256"})
        self.assertEqual(len(public["label"]), 16)
        self.assertNotIn("question", public)
        configuration = cohort.configuration("http://127.0.0.1:1/v1/", "m")
        self.assertEqual(configuration["maximum_output"], 2048)
        self.assertIn("host citation labels", configuration["system"])
        self.assertNotIn("sourceId", configuration["system"])


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
