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
