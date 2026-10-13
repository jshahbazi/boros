#!/usr/bin/env python3
"""Synthetic contracts for the record path: the extraction request, quote verification, entry parsing, the
record selection and its expansion, the answer-body transform, citation resolution and the decision rule.
No network, credentials or BEAM data."""
from __future__ import annotations

import io
import json
import unittest

import beam_record as br

FRAMING = "Earlier messages ... A missing excerpt is not proof that the archive lacks a fact."


def case():
    messages = []
    for seq, (role, text, date) in enumerate((
            ("user", "I started training for the marathon in Boston with coach Dana.", "2024-01-05"),
            ("assistant", "A marathon plan has long runs. Dana's schedule looks sound.", "2024-01-05"),
            ("user", "The  marathon training moved to Chicago and my long run is 18 miles.", "2024-02-10"),
            ("assistant", "Eighteen miles is good progress.", "2024-02-10"),
            ("user", "Unrelated: my printer is broken.", "2024-03-01"),
            ("assistant", "Try a reset.", "2024-03-01"),
            ("user", "Dana says the race itself is on April 21.", "2024-03-20"),
            ("assistant", "Noted.", "2024-03-20"))):
        messages.append({"seq": seq, "role": role, "text": text, "date": date, "session": seq // 2})
    return {"source": {"scale": "100K", "conversationId": "9"}, "messages": messages}


def entry(seq, block, subject, statement, quote, entities=(), speaker="user", kind="fact"):
    return {"seq": seq, "date": f"2024-0{block + 1}-01", "session": block, "block": block, "speaker": speaker, "kind": kind,
            "subject": subject, "entities": list(entities), "statement": statement, "quote": quote, "quote_match": "exact",
            "id": f"100K-9:{seq}:0"}


class Contracts(unittest.TestCase):
    def test_exchanges_and_the_extraction_request(self):
        exchanges = br.exchanges_of(case())
        self.assertEqual([e["seqs"] for e in exchanges], [[0, 1], [2, 3], [4, 5], [6, 7]])
        self.assertEqual(exchanges[1]["date"], "2024-02-10")
        messages = br.extraction_messages(exchanges[1])
        self.assertEqual([m["role"] for m in messages], ["system", "user"])
        self.assertEqual(messages[0]["content"], br.EXTRACT_SYSTEM)
        body = messages[1]["content"]
        self.assertTrue(body.startswith("Exchange date: 2024-02-10 (session 2, turn 2)"))
        self.assertIn("\n\nUser's message (turn 2):\nThe  marathon", body)
        self.assertIn("\n\nAssistant's reply (turn 3):\nEighteen", body)
        self.assertEqual(br.conversation_name(case()), "100K-9")
        self.assertGreaterEqual(br.bound_tokens(messages), len(body) // br.CHARS_PER_TOKEN_BOUND)

    def test_quote_location_is_exact_recovered_or_rejected(self):
        text = "The  marathon training moved to Chicago and my long run is 18 miles. It’s “fine”."
        self.assertEqual(br.locate_quote("moved to Chicago", text), ("moved to Chicago", "exact"))
        # Re-spaced, re-cased and straight-quoted copies are located and replaced by the exact span.
        self.assertEqual(br.locate_quote("the marathon training moved", text), ("The  marathon training moved", "recovered"))
        self.assertEqual(br.locate_quote("It's \"fine\"", text), ("It’s “fine”", "recovered"))
        self.assertEqual(br.locate_quote("my long run is 18 miles...", text), ("my long run is 18 miles", "exact"))
        self.assertEqual(br.locate_quote("moved to Denver", text), (None, "rejected"))
        self.assertEqual(br.locate_quote("", text), (None, "rejected"))
        self.assertEqual(br.locate_quote("x" * (br.QUOTE_MAXIMUM_CHARS + 1), "x" * 1000), (None, "rejected"))
        span, kind = br.locate_quote("marathon  TRAINING", text)
        self.assertEqual((span, kind), ("marathon training", "recovered"))
        self.assertIn(span, text)

    def test_entry_parser_keeps_verified_entries_only(self):
        exchange = br.exchanges_of(case())[1]
        good = {"speaker": "user", "kind": "change", "subject": "marathon training location", "entities": ["Chicago"],
                "statement": "The user's marathon training moved to Chicago.", "quote": "marathon training moved to Chicago"}
        reply = {"speaker": "assistant", "kind": "recommendation", "subject": "long run", "entities": [],
                 "statement": "The assistant called 18 miles good progress.", "quote": "Eighteen miles is good progress."}
        wrong_speaker = dict(good, speaker="assistant")
        unknown_kind = dict(good, kind="musing", quote="my long run is 18 miles")
        extra_key = dict(good, extra=1)
        text = "\n".join(["```json", json.dumps(good), "not json", json.dumps(reply), json.dumps(wrong_speaker),
                          json.dumps(unknown_kind), json.dumps(extra_key), json.dumps({"speaker": "user"}),
                          json.dumps(dict(good, quote="moved to Denver")), "NO ENTRIES", "```"])
        entries, counts = br.parse_entries(text, exchange)
        self.assertEqual([(e["seq"], e["kind"], e["quote_match"]) for e in entries], [(2, "change", "exact"), (3, "recommendation", "exact"), (2, "fact", "exact")])
        self.assertEqual(entries[0]["date"], "2024-02-10")
        self.assertEqual(entries[0]["block"], 1)
        self.assertEqual(counts, {"lines": 8, "malformed": 1, "invalid": 2, "rejected_quote": 2, "exact": 3, "recovered": 0, "over_limit": 0})
        self.assertEqual(br.parse_entries("NO ENTRIES\n", exchange), ([], {"lines": 0, "malformed": 0, "invalid": 0, "rejected_quote": 0,
                                                                            "exact": 0, "recovered": 0, "over_limit": 0}))
        many = "\n".join(json.dumps(good) for _ in range(br.MAXIMUM_ENTRIES_PER_EXCHANGE + 3))
        capped, counts = br.parse_entries(many, exchange)
        self.assertEqual((len(capped), counts["over_limit"]), (br.MAXIMUM_ENTRIES_PER_EXCHANGE, 3))

    def test_selection_expands_seeds_by_subject_and_entity_in_chronological_order(self):
        entries = [
            entry(0, 0, "marathon training", "The user started marathon training in Boston.", "training for the marathon", ["Boston", "Dana"]),
            entry(2, 1, "marathon training", "The user's long run reached 18 miles.", "long run is 18 miles", ["Chicago"]),
            entry(4, 2, "printer problem", "The user's printer was broken.", "printer is broken"),
            entry(6, 3, "race date", "Dana said the race was on April 21.", "race itself is on April 21", ["Dana"]),
            entry(8, 4, "weekend plans", "The user planned a hike.", "planned a hike"),
        ]
        lexical = br.select(entries, "Summarize my marathon training.", "lexical")
        self.assertEqual([entries[p]["seq"] for p in lexical["positions"]], [0, 2])
        expanded = br.select(entries, "Summarize my marathon training.", "subject")
        # Entity Dana (from the Boston seed) pulls in the race-date entry; the printer and hike stay out.
        self.assertEqual([entries[p]["seq"] for p in expanded["positions"]], [0, 2, 6])
        self.assertEqual(expanded["statistics"]["by_reason"], {"seed": 2, "subject": 0, "entity": 1, "exchange": 0, "rank": 0})
        self.assertEqual(expanded["statistics"]["selected"], 3)
        nothing = br.select(entries, "What about the kitchen?", "subject")
        self.assertEqual(nothing["positions"], [])
        anchored = br.select(entries, 'When was "April 21" mentioned?', "lexical")
        self.assertEqual(entries[anchored["positions"][0]]["seq"], 6)
        budget = br.select(entries, "Summarize my marathon training.", "subject", maximum=1)
        self.assertEqual(len(budget["positions"]), 1)
        with self.assertRaises(br.RecordError):
            br.select(entries, "q", "unknown")

    def test_exchange_method_adds_the_rest_of_a_chosen_exchange(self):
        entries = [entry(0, 0, "marathon training", "Started marathon training.", "training for the marathon"),
                   entry(1, 0, "coach advice", "The assistant endorsed the schedule.", "schedule looks sound", speaker="assistant"),
                   entry(4, 2, "printer problem", "The printer was broken.", "printer is broken")]
        chosen = br.select(entries, "marathon", "subject_exchange")
        self.assertEqual([entries[p]["seq"] for p in chosen["positions"]], [0, 1])
        self.assertEqual(chosen["statistics"]["by_reason"]["exchange"], 1)

    def test_record_body_labels_entries_in_order_and_the_candidate_adds_one_message(self):
        entries = [entry(0, 0, "a", "First.", "q1"), entry(2, 1, "b", "Second.", "q2", speaker="assistant", kind="plan")]
        body = br.record_body(entries, [0, 1])
        self.assertEqual(body.split("\n"), ['[R1] 2024-01-01, turn 0, user, fact: First. Quote: "q1"',
                                            '[R2] 2024-02-01, turn 2, assistant, plan: Second. Quote: "q2"'])
        captured = [{"role": "system", "content": "Base.\n\n" + FRAMING}, {"role": "user", "content": "quoted E1"},
                    {"role": "user", "content": "historical E2"}, {"role": "user", "content": "the question"}]
        messages = br.candidate_messages(captured, body, FRAMING)
        self.assertEqual([m["role"] for m in messages], ["system", "user", "user", "user", "user"])
        self.assertEqual(messages[0]["content"], "Base.\n\n" + FRAMING + " " + br.RECORD_FRAMING_SENTENCE)
        self.assertEqual(messages[1:3], captured[1:3])
        self.assertEqual(messages[3]["content"], br.RECORD_HEADING + body)
        self.assertEqual(messages[4], captured[3])
        with self.assertRaises(br.RecordError):
            br.candidate_messages(captured, "", FRAMING)
        with self.assertRaises(br.RecordError):
            br.candidate_messages([{"role": "system", "content": "other"}] + captured[1:], body, FRAMING)
        self.assertEqual(br.citation_resolution("See [E1], [R2] and [R9] and [E7].", 3, 2),
                         {"citations": 4, "resolved": 2, "record_citations": 2})

    def test_decision_rule_and_declared_constants(self):
        good = {"difference_points": 12.0, "interval_points": [1.0, 20.0]}
        self.assertTrue(br.decide(good, {"a": {"difference_points": -4.9}})["promote"])
        self.assertFalse(br.decide(good, {"a": {"difference_points": -5.1}})["promote"])
        self.assertFalse(br.decide({"difference_points": 12.0, "interval_points": [0.0, 20.0]}, {})["promote"])
        self.assertFalse(br.decide({"difference_points": 9.9, "interval_points": [1.0, 20.0]}, {})["promote"])
        self.assertEqual(br.decide(None, {})["outcome"], "no_default_change")
        self.assertEqual(br.ARMS, ("ordinary_send", "record"))
        self.assertEqual(br.STAGES, ("baseline", "candidate"))
        self.assertIn("NO ENTRIES", br.EXTRACT_SYSTEM)
        self.assertIn("routed", br.DECISION_RULE["promote"])
        self.assertEqual(br.job_name({"stage": "baseline", "label": "ab", "replicate": 0}), "ab--r0")


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
