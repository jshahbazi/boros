#!/usr/bin/env python3
"""Synthetic contracts for record path v2: exchange blocks, their rendering and listing, selection parsing, the
whole-record and selected compositions, the heading per question kind and the answer-body transform. No network,
credentials or BEAM data."""
from __future__ import annotations

import io
import json
import unittest

import beam_record as br
import beam_record_v2 as v2

FRAMING = "Earlier messages ... A missing excerpt is not proof that the archive lacks a fact."


def entry(seq, block, statement, quote, speaker="user", kind="fact", position=0):
    return {"seq": seq, "date": f"2024-0{block + 1}-01", "session": block, "block": block, "speaker": speaker, "kind": kind,
            "subject": "s", "entities": [], "statement": statement, "quote": quote, "quote_match": "exact",
            "id": f"100K-9:{seq}:{position}", "position": position}


def record():
    return [entry(0, 0, "Started marathon training in Boston.", "training for the marathon"),
            entry(0, 0, "Named Dana as the coach.", "coach Dana", position=1),
            entry(1, 0, "The assistant endorsed the schedule.", "schedule looks sound", speaker="assistant", kind="recommendation"),
            entry(2, 1, "The long run reached 18 miles.", "long run is 18 miles", kind="change"),
            entry(4, 2, "The printer was broken.", "printer is broken"),
            entry(6, 3, "The race was on April 21.", "race itself is on April 21", kind="event")]


class Contracts(unittest.TestCase):
    def test_blocks_render_and_list_with_the_user_first(self):
        entries = record()
        blocks = v2.blocks_of_record(entries)
        self.assertEqual([(b["label"], b["block"], b["turns"], b["positions"]) for b in blocks],
                         [("X1", 0, (0, 1), [0, 1, 2]), ("X2", 1, (2, 2), [3]), ("X3", 2, (4, 4), [4]), ("X4", 3, (6, 6), [5])])
        rendered = v2.render_block(entries, blocks[0])
        self.assertTrue(rendered.startswith("[X1] 2024-01-01, turns 0-1\nuser (turn 0), fact: Started marathon training in Boston. Quote: \"training for the marathon\"\n"))
        self.assertIn("\nassistant (turn 1), recommendation: The assistant endorsed the schedule. Quote: \"schedule looks sound\"", rendered)
        self.assertEqual(v2.render_block(entries, blocks[1]).split("\n")[0], "[X2] 2024-02-01, turn 2")
        listed = v2.listing_block(entries, blocks[0])
        self.assertEqual(listed.split("\n")[0], "[X1] 2024-01-01 t0-1")
        self.assertIn("\n  user fact: Started marathon training in Boston.", listed)
        self.assertNotIn("Quote", listed)
        chunks = v2.listing_chunks(entries, blocks, "In what order?", ["ordering"], chunk_chars=200)
        self.assertGreater(len(chunks), 1)
        self.assertEqual([label for chunk in chunks for label in chunk["labels"]], ["X1", "X2", "X3", "X4"])
        self.assertTrue(chunks[0]["messages"][1]["content"].startswith(f"Record (part 1 of {len(chunks)}, chronological, grouped by exchange):"))
        self.assertTrue(chunks[-1]["messages"][1]["content"].endswith("\n\nQuestion (it needs the order in which things were brought up):\nIn what order?"))
        self.assertEqual(chunks[0]["messages"][0]["content"], v2.SELECT_SYSTEM)
        self.assertEqual(v2.parse_selection("- **[X2]**\n[X9]\n[R1]\nNONE\nX4.\n[X2]\n", {"X1", "X2", "X4"}), (["X2", "X4"], 2))

    def test_whole_record_goes_when_it_fits_else_selected_then_ranked_exchanges(self):
        entries = record()
        blocks = v2.blocks_of_record(entries)
        whole = v2.compose(entries, blocks, [], {}, whole_chars=10_000)
        self.assertTrue(whole["whole"])
        self.assertEqual(whole["labels"], ["X1", "X2", "X3", "X4"])
        self.assertEqual(whole["statistics"]["by_reason"], {"whole": 4, "selected": 0, "rank": 0})
        # Too big for the whole record: the selected exchange, then the application's exchange ranks, within the limits.
        chosen = v2.compose(entries, blocks, ["X4"], {1: 0, 0: 1, 2: 2}, whole_chars=10, maximum=5, maximum_chars=10_000)
        self.assertFalse(chosen["whole"])
        self.assertEqual(chosen["labels"], ["X1", "X2", "X4"])
        self.assertEqual(chosen["statistics"]["by_reason"], {"whole": 0, "selected": 1, "rank": 2})
        # A selected exchange that does not fit is skipped; the fill stops at the first ranked exchange that does not fit.
        limited = v2.compose(entries, blocks, ["X1", "X4"], {1: 0}, whole_chars=10, maximum=2, maximum_chars=10_000)
        self.assertEqual(limited["labels"], ["X2", "X4"])
        self.assertEqual(v2.compose(entries, blocks, [], {}, whole_chars=10)["labels"], [])
        body = v2.record_body(entries, blocks, ["X2", "X4"])
        self.assertTrue(body.startswith("[X2] 2024-02-01, turn 2\n") and "\n\n[X4] 2024-04-01, turn 6\n" in body)
        ranks = v2.exchange_ranks({"messages": [{"seq": 0, "role": "user", "text": "marathon plan"}, {"seq": 1, "role": "assistant", "text": "ok"},
                                                {"seq": 2, "role": "user", "text": "printer"}, {"seq": 3, "role": "assistant", "text": "reset"}]}, "marathon")
        self.assertEqual(ranks, {0: 0})

    def test_heading_names_the_scope_and_the_question_kind_and_the_candidate_adds_one_message(self):
        self.assertIn(v2.SCOPE_WHOLE, v2.heading(True, ["summarize"]))
        self.assertIn(v2.SCOPE_SELECTED, v2.heading(False, ["summarize"]))
        self.assertNotIn("order in which", v2.heading(True, ["summarize"]))
        self.assertIn(v2.KIND_ORDERING, v2.heading(True, ["ordering"]))
        self.assertIn(v2.KIND_COUNT, v2.heading(False, ["count_across"]))
        self.assertIn(v2.KIND_ORDERING + v2.KIND_COUNT, v2.heading(False, ["ordering", "count_across"]))
        captured = [{"role": "system", "content": "Base.\n\n" + FRAMING}, {"role": "user", "content": "quoted E1"}, {"role": "user", "content": "the question"}]
        messages = v2.candidate_messages(captured, "[X1] body", FRAMING, False, ["ordering"])
        self.assertEqual([m["role"] for m in messages], ["system", "user", "user", "user"])
        self.assertEqual(messages[0]["content"], "Base.\n\n" + FRAMING + " " + v2.FRAMING_SENTENCE)
        self.assertEqual(messages[2]["content"], v2.heading(False, ["ordering"]) + "[X1] body")
        self.assertEqual(messages[3], captured[2])
        with self.assertRaises(br.RecordError):
            v2.candidate_messages(captured, "", FRAMING, True, [])
        self.assertEqual(br.citation_resolution("See [E1], [X2], [X9] and [R1].", 2, {"X2"}), {"citations": 4, "resolved": 2, "record_citations": 3})
        self.assertEqual(br.citation_resolution("[R2] [R3]", 0, 2), {"citations": 2, "resolved": 1, "record_citations": 2})
        self.assertEqual(v2.question_kind(["summarize", "ordering"]), "a summary of everything on the topic; the order in which things were brought up")
        self.assertEqual(v2.METHOD, "exchanges-v3")
        self.assertIn("ordering", v2.DECISION_RULE)
        self.assertIn("NONE", v2.SELECT_SYSTEM)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
