#!/usr/bin/env python3
"""Synthetic provenance, full-session preservation and oracle-separation checks."""
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import longmemeval_cases as c
import evaluate_answers as e


def fixture():
    return [dict(question_id=qid, question_type=kind, question="Synthetic natural question?",
                 question_date="2023/07/27 (Thu) 18:00", answer=7 if index == 0 else "scorer-only-value",
                 answer_session_ids=["original-evidence-id"],
                 haystack_dates=["2023/07/28 (Fri) 18:00", "2023/07/27 (Thu) 18:00"],
                 haystack_session_ids=["original-evidence-id", "original-filler-id"],
                 haystack_sessions=[[{"role": "user", "content": "café κ\x00\n", "has_answer": False},
                                     {"role": "assistant", "content": "whole assistant evidence", "has_answer": True}],
                                    [{"role": "user", "content": "unlabelled filler"}]])
            for index, (qid, kind) in enumerate(zip(c.CASE_IDS, c.CASE_TYPES))]


class ContractTests(unittest.TestCase):
    def test_original_pointer_literal_and_full_unicode(self):
        rows = list(reversed(fixture()))
        histories = c.prepare_rows(rows)
        self.assertEqual([h["id"] for h in histories], list(c.CASE_IDS))
        for history in histories:
            self.assertEqual(history["events"][0]["text"].encode(), b"caf\xc3\xa9 \xce\xba\x00\n")
            for time in [history["episodes"][0]["question_time"], *(x["source_time"] for x in history["events"])]:
                tokens = time["locator"].split('/')[1:]
                value = rows[int(tokens[0])][tokens[1]]
                if len(tokens) == 3:
                    value = value[int(tokens[2])]
                self.assertEqual(value.encode(), time["original_value"].encode())
                self.assertEqual(time["source_sha256"], c.SOURCE_SHA256)
                self.assertEqual(time["timezone"], "unspecified")

    def test_array_order_future_dates_and_last_session(self):
        history = c.prepare_rows(fixture())[0]
        self.assertGreater(history["events"][0]["source_time"]["value"], history["episodes"][0]["question_time"]["value"])
        self.assertEqual([x["conversation_key"] for x in history["events"]], ["session-0000", "session-0000", "session-0001"])
        self.assertEqual(history["episodes"][0]["conversation_key"], "session-0001")

    def test_original_session_ids_labels_and_numeric_answer(self):
        history = c.prepare_rows(fixture())[0]
        self.assertEqual(history["episodes"][0]["answer"], 7)
        self.assertEqual(history["source_labels"][1], dict(event_id=history["events"][1]["id"], session_id="original-evidence-id", has_answer=True))
        self.assertNotIn("has_answer", history["source_labels"][2])
        last = c.prepare_rows(fixture())[-1]["episodes"][0]
        self.assertTrue(last["abstention"])
        self.assertEqual(last["question_type"], "knowledge-update")

    def test_repeated_original_session_id_preserved_as_occurrences(self):
        rows = fixture(); rows[0]["haystack_session_ids"][1] = "original-evidence-id"
        history = c.prepare_rows(rows)[0]
        self.assertEqual(len(history["events"]), 3)
        self.assertEqual(len(set(x["conversation_key"] for x in history["events"])), 2)
        self.assertEqual({x["session_id"] for x in history["source_labels"]}, {"original-evidence-id"})

    def test_oracle_fields_absent_and_question_time_separate(self):
        history = c.prepare_rows(fixture())[0]
        document = c.runner_input(history, {**e.DEFAULTS, "maximum_output": 512})
        self.assertNotIn(b"scorer-only-value", c.canonical_json(document))
        self.assertEqual(set(document), {"version", "split", "history_id", "events", "attempts", "configuration"})
        self.assertNotIn("source_labels", document)
        self.assertNotIn("answer", document["attempts"][0])
        self.assertEqual(document["attempts"][0]["prompt"], "Synthetic natural question?")
        self.assertNotIn("Question Date:", document["attempts"][0]["prompt"])
        self.assertEqual(document["attempts"][0]["question_time"]["locator"], "/0/question_date")
        changed = copy.deepcopy(document["configuration"]); changed["seed"] += 1
        self.assertEqual(c.projection_sha256(history, changed), c.projection_sha256(history, document["configuration"]))
        self.assertNotEqual(c.native_configuration_sha256(changed), c.native_configuration_sha256(document["configuration"]))

    def test_malformed_selected_inventory_rejected(self):
        for mutate in (lambda row: row["haystack_session_ids"].pop(),
                       lambda row: row["haystack_sessions"].__setitem__(0, []),
                       lambda row: row["haystack_sessions"][0][0].__setitem__("has_answer", 1),
                       lambda row: row.__setitem__("answer", True),
                       lambda row: row["haystack_dates"].__setitem__(0, "2023/07/28 (Fri) 25:00")):
            rows = fixture(); mutate(rows[0])
            with self.assertRaises(c.EvaluationError): c.prepare_rows(rows)
        rows = fixture(); rows.append(rows[0])
        with self.assertRaises(c.EvaluationError): c.prepare_rows(rows)

    def test_pinned_loader_refuses_wrong_bytes_and_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "source.json"; path.write_bytes(b"[]")
            with self.assertRaises(c.EvaluationError): c.prepare(path)
            link = Path(d) / "link.json"; link.symlink_to(path)
            with self.assertRaises(OSError): c.prepare(link)

    def test_duplicate_json_fields_rejected_before_projection(self):
        with tempfile.TemporaryDirectory() as d:
            data = b'[{"question_id":"a","question_id":"b"}]'
            path = Path(d) / "source.json"; path.write_bytes(data)
            with patch.object(c, "SOURCE_BYTES", len(data)), patch.object(c, "SOURCE_SHA256", c.digest(data)):
                with self.assertRaises(c.EvaluationError): c.prepare(path)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(ContractTests))
    print(json.dumps(dict(checks=result.testsRun, failed=[t.id() for t, _ in result.failures],
                         errors=[t.id() for t, _ in result.errors], skipped=len(result.skipped))))
    raise SystemExit(not result.wasSuccessful())
