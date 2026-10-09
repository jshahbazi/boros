#!/usr/bin/env python3
"""Synthetic contracts for the answer presentation defect diagnostics. No private data, network or model calls."""
from __future__ import annotations

from collections import Counter
import io
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import answer_presentation_defects as apd  # noqa: E402


class Contracts(unittest.TestCase):
    def test_current_envelope_literals_match_swift_contract(self):
        literals = apd.framing_literals()
        # The exact v2 prefix asserted by RecentSourceFramingChecks.swift.
        self.assertEqual(literals["recent_heading"] + '{"capture_status":"complete","event_id":"synthetic-id","role":"human"}'
                         + literals["original_label"],
                         'Recent source metadata (host): {"capture_status":"complete","event_id":"synthetic-id",'
                         '"role":"human"}\nOriginal message text:\n')
        self.assertEqual(literals["evidence_header_lines"][0], "BEGIN HISTORICAL SOURCE")
        self.assertEqual(literals["evidence_header_lines"][-1], "quoted_excerpt:")
        self.assertIn("cite their event IDs", literals["history_framing"])

    def test_rendered_envelope_frames_prior_assistant_turns(self):
        messages = apd.render_envelope(apd.framing_literals())
        self.assertEqual([m["role"] for m in messages], ["system", "user", "assistant", "user", "user"])
        self.assertTrue(messages[2]["content"].startswith(apd.RECENT_HEADING))
        self.assertIn(apd.ORIGINAL_LABEL, messages[2]["content"])
        self.assertFalse(messages[-1]["content"].startswith(apd.RECENT_HEADING))

    def test_detector_recognizes_a_copied_envelope_header(self):
        literals = apd.framing_literals()
        prior = apd.render_envelope(literals)[1]["content"]
        header = prior[:prior.index(apd.ORIGINAL_LABEL) + len(apd.ORIGINAL_LABEL) + 1]
        counts = apd.pattern_counts(header + "Synthetic earlier question?", "Synthetic earlier question?")
        for name in ("envelope_recent_heading", "envelope_original_text_label", "envelope_recent_metadata_json",
                     "envelope_header_at_answer_start", "envelope_header_role_human", "question_verbatim",
                     "ends_with_question", "id_sha256_hex"):
            self.assertEqual(counts[name], 1, name)

    def test_latex_math_versus_currency(self):
        math = apd.pattern_counts("The total is $3 + 4 = 7$ days, so $\\frac{1}{2}$ remains.")
        self.assertEqual(math["math_inline_dollar_pair"], 2)
        self.assertEqual(math["math_latex_command"], 1)
        money = apd.pattern_counts("It cost $5 and later $10, or $5-$10 overall.")
        self.assertEqual(money["math_inline_dollar_pair"], 0)
        self.assertEqual(money["dollar_currency"], 4)

    def test_clean_answer_has_no_patterns(self):
        counts = apd.pattern_counts("You adopted the dog in March.", "When did I adopt the dog?")
        self.assertEqual({name: value for name, value in counts.items() if value}, {})

    def test_identifiers_markdown_and_scaffold(self):
        text = ("**Answer:** Yes [abc12345-s0001-m0002].\n- item\n1. step\n| a | b |\n# Head\n"
                "<think>x</think>\nUser: hi\nQuestion: again\nAs an AI, I cannot know.")
        counts = apd.pattern_counts(text)
        expected = {"markdown_bold": 1, "id_event_id_raw": 1, "markdown_list_item": 2, "markdown_table_row": 1,
                    "markdown_heading": 1, "thinking_tag": 2, "role_label_line": 1, "question_label_echo": 1,
                    "ai_disclaimer": 1}
        for name, value in expected.items():
            self.assertEqual(counts[name], value, name)

    def test_echo_provenance_is_content_free(self):
        literals = apd.framing_literals()
        prior = apd.render_envelope(literals)[2]["content"]
        header = prior[:prior.index(apd.ORIGINAL_LABEL) + len(apd.ORIGINAL_LABEL) + 1]
        header = header.replace("synthetic-s0001-m0001", "abc12345-s0001-m0002")
        dataset = {"abc12345": {"haystack_sessions": [[], [{"role": "user", "content": "private text"},
                                                           {"role": "assistant", "content": "private reply"}]],
                                "haystack_dates": ["2023/01/01 (Sun) 10:00", "2023/01/01 (Sun) 10:00"]}}
        stats = Counter()
        candidate = {"answer_text": header + "Body.", "question": "Unrelated synthetic question?"}
        apd.echo_provenance(candidate, ["abc12345-s0001-m0000", "abc12345-s0001-m0001"], dataset, stats)
        self.assertEqual(stats["echo_event_id_is_next_after_last_recent"], 1)
        self.assertEqual(stats["echo_event_id_absent_from_history"], 1)
        self.assertEqual(stats["echo_keys_equal_current_v3_header"], 1)
        self.assertEqual(stats["echo_role_assistant"], 1)
        self.assertNotIn("private", json.dumps(stats))

    def test_v4_envelope_quotes_prior_turns_without_assistant_role(self):
        literals = apd.framing_literals()
        messages = apd.render_envelope(literals, version="v4")
        self.assertEqual([m["role"] for m in messages], ["system", "user", "user", "user", "user"])
        self.assertFalse(any(m["content"].startswith(apd.RECENT_HEADING) or apd.ORIGINAL_LABEL in m["content"]
                             for m in messages))
        self.assertTrue(messages[1]["content"].startswith(apd.QUOTED_HEADING + "E1]"))
        self.assertTrue(messages[2]["content"].startswith(apd.QUOTED_HEADING + "E2]"))
        self.assertIn("BEGIN HISTORICAL SOURCE [E3]\n", messages[3]["content"])
        self.assertTrue(messages[3]["content"].endswith("END HISTORICAL SOURCE [E3]"))
        self.assertNotIn("event_id", messages[3]["content"])
        self.assertEqual(literals["quoted_recent_fields"], ["role", "capture_status", "captured_utc", "source_time"])
        framing = literals["quoted_history_framing"]
        self.assertIn("cite its label in square brackets", framing)
        self.assertNotIn("cite their event IDs", framing)
        self.assertIn("does not show it", framing)
        self.assertIn("do not guess", framing)
        self.assertIn("do not say that you are an AI", framing)

    def test_detector_recognizes_a_copied_v4_header(self):
        prior = apd.render_envelope(apd.framing_literals(), version="v4")[2]["content"]
        header = prior[:prior.index(apd.QUOTED_TEXT_LABEL) + len(apd.QUOTED_TEXT_LABEL) + 1]
        counts = apd.pattern_counts(header + "Synthetic answer.")
        for name in ("quoted_source_heading", "quoted_text_label", "host_header_at_answer_start"):
            self.assertEqual(counts[name], 1, name)
        self.assertEqual(counts["envelope_header_at_answer_start"], 0)
        v3 = apd.render_envelope(apd.framing_literals())[2]["content"]
        self.assertEqual(apd.pattern_counts(v3)["host_header_at_answer_start"], 1)

    def test_citation_labels_resolve_against_recorded_map(self):
        label_map = [{"label": "E1"}, {"label": "E2"}, {"label": "E3"}]
        answer = "It was March [E1]; later it changed [E2, E7] and again [E3 and E2]. Not [Ex] or E4."
        self.assertEqual(apd.cited_labels(answer), ["E1", "E2", "E7", "E3", "E2"])
        self.assertEqual(apd.citation_resolution(answer, label_map),
                         {"cited_labels": 5, "distinct_cited_labels": 4, "resolved_labels": 4, "unresolved_labels": 1})
        self.assertEqual(apd.pattern_counts(answer)["citation_label"], 5)

    def test_event_id_mentions_flag_fabricated_ids(self):
        known = ["abc12345-s0001-m0001"]
        answer = 'See abc12345-s0001-m0001 and abc12345-s0001-m0009. {"event_id":"invented-id"}'
        self.assertEqual(apd.event_id_mentions(answer, known), {"raw_event_ids": 2, "fabricated_event_ids": 2})

    def test_plain_decline_is_separate_from_ai_disclaimer(self):
        decline = apd.pattern_counts("The conversation history provided here does not show it.")
        self.assertEqual((decline["plain_decline"], decline["ai_disclaimer"]), (1, 0))
        disclaimer = apd.pattern_counts("As an AI, I don't have memory of that.")
        self.assertEqual((disclaimer["plain_decline"], disclaimer["ai_disclaimer"]), (0, 2))

    def test_reference_and_addressing_checks(self):
        self.assertTrue(apd.contains_reference("You adopted Max, a beagle, in March.", "a Beagle"))
        self.assertFalse(apd.contains_reference("You adopted a dog.", "beagle"))
        self.assertFalse(apd.contains_reference("anything", ""))
        question = "When did I adopt the dog named Max?"
        clean = "In March."
        self.assertTrue(apd.addresses_question(clean, question, apd.pattern_counts(clean, question)))
        repeated = "When did I adopt the dog named Max?"
        self.assertFalse(apd.addresses_question(repeated, question, apd.pattern_counts(repeated, question)))
        self.assertFalse(apd.addresses_question("  ", question, apd.pattern_counts("  ", question)))

    def test_patterns_are_documented(self):
        counts = apd.pattern_counts("x")
        self.assertEqual(set(counts), set(apd.PATTERNS))
        self.assertTrue(all(category in {"envelope", "identifier", "latex", "markdown", "role", "scaffold",
                                         "question", "prose"} for category, _ in apd.PATTERNS.values()))


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
