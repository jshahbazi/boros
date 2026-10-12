#!/usr/bin/env python3
"""Synthetic contracts for the reader-choice driver. No network, gcloud, credentials or private data."""
from __future__ import annotations

import io
import json
import unittest

import reader_choice as choice


def overall(d, low, high):
    return {"difference_points": d, "interval_points": [low, high]}


class Contracts(unittest.TestCase):
    def test_decision_rule_requires_both_judges_to_agree_on_direction(self):
        self.assertEqual(choice.decide(overall(6, 1, 11), overall(2, -3, 7)), "sonnet_preferred")
        self.assertEqual(choice.decide(overall(6, 1, 11), overall(-1, -6, 4)), "no_measured_difference")
        self.assertEqual(choice.decide(overall(4, 0.5, 9), overall(4, 1, 8)), "no_measured_difference")
        self.assertEqual(choice.decide(overall(6, -0.5, 12), overall(6, 1, 11)), "no_measured_difference")
        self.assertEqual(choice.decide(overall(-6, -11, -1), overall(-2, -7, 3)), "gemini_preferred")
        self.assertEqual(choice.decide(overall(-6, -11, 0.5), overall(-2, -7, 3)), "no_measured_difference")
        self.assertIn("D > 0 under the second judge", choice.DECISION_RULE["sonnet_preferred"])

    def test_jobs_cover_both_cohorts_three_times(self):
        rows = [{"kind": "step3", "cohort": "c", "question_id": "q1"}, {"kind": "step3", "cohort": "c", "question_id": "q2"},
                {"kind": "beam", "label": "b1"}]
        jobs = choice.sonnet_jobs(rows)
        self.assertEqual(len(jobs), 3 * choice.REPLICATES)
        self.assertEqual(sorted({job["replicate"] for job in jobs}), [0, 1, 2])
        self.assertEqual(choice.sonnet_answer_name(jobs[0]), "step3/c--q1--r0")
        self.assertEqual(choice.sonnet_answer_name(jobs[2]), "beam/b1--r0")

    def test_paired_readers_uses_gemini_as_baseline(self):
        per_question = {"a": {choice.GEMINI: 0.0, choice.SONNET: 1.0}, "b": {choice.GEMINI: 1.0, choice.SONNET: 1.0}}
        result = choice.paired_readers(per_question, ["a", "b"], "seed")
        self.assertEqual((result["gemini_percent"], result["sonnet_percent"], result["difference_points"]), (50.0, 100.0, 50.0))
        self.assertEqual((result["better"], result["worse"]), (1, 0))

    def test_readers_settings_and_prices_are_pinned(self):
        self.assertEqual(choice.READERS, ("gemini-3.8-flash", "claude-sonnet-5-5"))
        self.assertEqual(choice.BETWEEN_TOOLS, {"type": "between_tools"})
        self.assertEqual(choice.PRICES[choice.SONNET].microusd(1_000_000, 0), 2_000_000)
        self.assertEqual(choice.PRICES[choice.GEMINI].microusd(0, 1_000_000), 7_500_000)
        self.assertEqual(choice.ARM, "exchange_packed")


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
