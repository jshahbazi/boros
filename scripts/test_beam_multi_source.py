#!/usr/bin/env python3
"""Synthetic contracts for the multi-source path: the router, the ranking port, snippets, notes parsing, the
answer-body transform and citation resolution. No network, credentials or BEAM data."""
from __future__ import annotations

import io
import json
import unittest

import beam_multi_source as ms

FRAMING = "Earlier messages ... A missing excerpt is not proof that the archive lacks a fact."


def case():
    messages = []
    for seq, (role, text, date) in enumerate((
            ("user", "I started training for the marathon in Boston.", "2024-01-05"),
            ("assistant", "A marathon plan has long runs.", "2024-01-05"),
            ("user", "The marathon training moved to Chicago and my long run is 18 miles.", "2024-02-10"),
            ("assistant", "Eighteen miles is good progress.", "2024-02-10"),
            ("user", "Unrelated: my printer is broken.", "2024-03-01"),
            ("assistant", "Try a reset.", "2024-03-01"),
            ("user", "Marathon update: " + "the long run is now 20 miles. " * 40, "2024-03-20"),
            ("assistant", "Nice.", "2024-03-20"))):
        messages.append({"seq": seq, "role": role, "text": text, "date": date, "session": seq // 2})
    return {"messages": messages}


class Contracts(unittest.TestCase):
    def test_router_rules(self):
        self.assertEqual(ms.route("Give me a summary of my marathon training over time")["reasons"], ["summarize"])
        self.assertEqual(ms.route("How has my marathon training changed over time?")["reasons"], ["change_across"])
        self.assertTrue(ms.route("In what order did I bring up these items?")["routed"])
        self.assertTrue(ms.route("How many races did I mention in total across our sessions?")["routed"])
        self.assertTrue(ms.route("Have I ever attended a workshop?")["routed"])
        self.assertFalse(ms.route("How many days passed between the first run and the race?")["routed"])
        self.assertFalse(ms.route("What is my current long run distance?")["routed"])
        self.assertFalse(ms.route("I'm planning a trip; suggest some options.")["routed"])
        self.assertEqual(ms.route("What is my current long run distance?")["reasons"], [])

    def test_terms_and_query_follow_the_exchange_term_function(self):
        self.assertEqual(ms.terms("The Café's MARATHON plan, 18 miles!"), ["cafe", "marathon", "plan", "18", "miles"])
        query = ms.parse_query('When did I mention "long run" and `Chicago`?')
        self.assertEqual(query["anchors"], [{"long", "run"}, {"chicago"}])
        self.assertTrue({"long", "run", "chicago", "mention"} <= query["terms"])
        self.assertNotIn("when", query["terms"])

    def test_rank_prefers_anchor_matches_then_score_then_later_block(self):
        blocks = ms.blocks_of(case()["messages"])
        self.assertEqual([[m["seq"] for m in block] for block in blocks], [[0, 1], [2, 3], [4, 5], [6, 7]])
        ranked = ms.rank(ms.parse_query("marathon long run"), blocks)
        # Block 3 repeats every term (frequency boost, capped at 1 + 2) and outranks the single mentions.
        self.assertEqual([entry["block"] for entry in ranked], [3, 1, 0])
        self.assertEqual({entry["block"] for entry in ranked}, {0, 1, 3})
        anchored = ms.rank(ms.parse_query('"Boston" marathon'), blocks)
        self.assertEqual(anchored[0]["block"], 0)
        self.assertEqual(anchored[0]["anchor_matches"], 1)
        tie = ms.rank({"terms": {"nice"}, "anchors": []}, blocks)
        self.assertEqual([entry["block"] for entry in tie], [3])

    def test_window_centers_on_query_terms_and_marks_cuts(self):
        text = "aaa " * 100 + "marathon long run " + "bbb " * 100
        piece = ms.window(text, {"marathon"}, 120)
        self.assertIn("marathon", piece)
        self.assertTrue(piece.startswith("… ") and piece.endswith(" …"))
        self.assertLessEqual(len(piece), 126)
        self.assertEqual(ms.window("short  text\n here", {"x"}, 100), "short text here")
        head = ms.window("x " * 200, {"zzz"}, 50)
        self.assertFalse(head.startswith("…"))

    def test_snippets_cover_every_block_chronologically_with_replies_for_ranked_blocks(self):
        items, stats = ms.snippets(case(), "marathon long run progress", rich_blocks=2)
        self.assertEqual([item["seqs"] for item in items], [[0, 1], [2, 3], [4, 5], [6, 7]])
        self.assertEqual([item["label"] for item in items], ["S1", "S2", "S3", "S4"])
        self.assertTrue(items[0]["text"].startswith("[S1] 2024-01-05, turn 0\nuser: "))
        # The two best-ranked blocks (3 and 1) carry a reply window; the unmatched printer block does not.
        self.assertIn("assistant: ", items[3]["text"])
        self.assertIn("assistant: ", items[1]["text"])
        self.assertNotIn("assistant: ", items[2]["text"])
        self.assertIsNone(items[2]["rank"])
        self.assertEqual((stats["snippets"], stats["blocks"], stats["rich_snippets"], stats["dropped_blocks"]), (4, 4, 2, 0))
        self.assertLessEqual(len(items[3]["text"]), len("[S4] 2024-03-20, turn 6\nuser: ") + ms.HUMAN_WINDOW + 4
                             + len("\nassistant: ") + ms.ASSISTANT_WINDOW + 4)
        # Over the budget, the unmatched block goes first, then the lowest ranked.
        budgeted, limited = ms.snippets(case(), "marathon long run progress", char_budget=400)
        self.assertNotIn([4, 5], [item["seqs"] for item in budgeted])
        self.assertLessEqual(sum(len(item["text"]) + 8 for item in budgeted), 400)
        self.assertGreater(limited["dropped_blocks"], 0)
        chunks = ms.map_chunks("Q?", items, chunk_chars=300)
        self.assertGreater(len(chunks), 1)
        self.assertEqual([label for chunk in chunks for label in chunk["labels"]], ["S1", "S2", "S3", "S4"])
        self.assertEqual([m["role"] for m in chunks[0]["messages"]], ["system", "user"])
        self.assertTrue(chunks[0]["messages"][1]["content"].startswith(f"Snippets (part 1 of {len(chunks)}, chronological):"))
        self.assertTrue(chunks[-1]["messages"][1]["content"].endswith("\n\nQuestion:\nQ?"))
        self.assertEqual(len(ms.map_chunks("Q?", items)), 1)

    def test_notes_parser_keeps_only_resolvable_dated_lines(self):
        text = ("Here are the notes:\n- **2024-01-05 [S1]:** started training in Boston\n"
                "2024-02-10 [S2, S3]: moved to Chicago\n2024-02-10 [S9]: invented\nunknown date [S2]: no date given\n"
                "Boston is nice.\nNO RELEVANT NOTES\n")
        notes, dropped = ms.parse_notes(text, {"S1", "S2", "S3"})
        self.assertEqual(notes, ["2024-01-05 [S1]: started training in Boston", "2024-02-10 [S2, S3]: moved to Chicago",
                                 "unknown date [S2]: no date given"])
        self.assertEqual(dropped, 3)
        self.assertEqual(ms.parse_notes("NO RELEVANT NOTES", {"S1"}), ([], 0))
        many = "\n".join(f"2024-01-01 [S1]: note {i}" for i in range(100))
        self.assertEqual(len(ms.parse_notes(many, {"S1"})[0]), ms.NOTES_PER_CHUNK)
        self.assertEqual(len(ms.parse_notes(many, {"S1"}, maximum=7)[0]), 7)

    def test_candidate_body_adds_the_notes_message_and_framing_sentence_only(self):
        captured = [{"role": "system", "content": "Base.\n\n" + FRAMING}, {"role": "user", "content": "quoted E1"},
                    {"role": "user", "content": "historical E2"}, {"role": "user", "content": "the question"}]
        messages = ms.candidate_messages(captured, ["2024-01-05 [S1]: a fact"], FRAMING)
        self.assertEqual([m["role"] for m in messages], ["system", "user", "user", "user", "user"])
        self.assertEqual(messages[0]["content"], "Base.\n\n" + FRAMING + " " + ms.NOTES_FRAMING_SENTENCE)
        self.assertEqual(messages[1:3], captured[1:3])
        self.assertTrue(messages[3]["content"].startswith(ms.NOTES_HEADING))
        self.assertTrue(messages[3]["content"].endswith("2024-01-05 [S1]: a fact"))
        self.assertEqual(messages[4], captured[3])
        self.assertEqual(captured[0]["content"], "Base.\n\n" + FRAMING)
        with self.assertRaises(ms.MultiSourceError):
            ms.candidate_messages(captured, [], FRAMING)
        with self.assertRaises(ms.MultiSourceError):
            ms.candidate_messages([{"role": "system", "content": "other"}] + captured[1:], ["n"], FRAMING)

    def test_citation_resolution_counts_delivered_and_snippet_labels(self):
        value = ms.citation_resolution("See [E1] and [E40], also [S2] and [S9].", 10, {"S1", "S2"})
        self.assertEqual(value, {"citations": 4, "resolved": 2, "snippet_citations": 2})

    def test_calibration_controls_add_the_ideal_summary_positive(self):
        summary = {"id": "s-1", "category": "summarization", "question": "Summarize it.", "referenceAnswer": None,
                   "rubric": "[]", "nativeAuthorReference": {"category": "summarization", "nativeOrder": 0,
                                                             "questionObject": {"ideal_summary": "The ideal summary."}}}
        factual = {"id": "f-1", "category": "knowledge_update", "question": "Which?", "referenceAnswer": "Lyon",
                   "rubric": "x", "nativeAuthorReference": {"category": "knowledge_update", "nativeOrder": 1,
                                                            "questionObject": {"answer": "Lyon"}}}
        preference = dict(factual, id="p-1", category="preference_following", referenceAnswer=None,
                          nativeAuthorReference={"questionObject": {}})
        controls = ms.calibration_controls([summary, factual, preference])
        self.assertEqual([(c["kind"], c["question_id"]) for c in controls],
                         [("positive", "s-1"), ("negative", "s-1"), ("positive", "f-1"), ("negative", "f-1"), ("negative", "p-1")])
        self.assertEqual(controls[0]["candidate"], "The ideal summary.")
        self.assertEqual(controls[2]["candidate"], "Lyon")
        # The questions themselves are unchanged: the grader request still carries the original supplement shape.
        self.assertEqual(set(summary["nativeAuthorReference"]), {"category", "nativeOrder", "questionObject"})

    def test_declared_constants(self):
        self.assertEqual(ms.ARMS, ("ordinary_send", "multi_source"))
        self.assertEqual(ms.STAGES, ("baseline", "map", "candidate"))
        self.assertIn("promote", ms.DECISION_RULE)
        self.assertIn("NO RELEVANT NOTES", ms.MAP_SYSTEM)
        self.assertEqual(ms.job_name({"stage": "map", "label": "ab", "replicate": 2, "chunk": 1}), "ab--r2--c1")
        self.assertEqual(ms.job_name({"stage": "baseline", "label": "ab", "replicate": 0}), "ab--r0")


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
