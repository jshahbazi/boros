#!/usr/bin/env python3
"""Synthetic contracts for the exchange_packed answer-quality driver. No network, gcloud or
credentials, and no harness build."""
from __future__ import annotations

import io
import json
import unittest
from pathlib import Path

import exchange_packed_answers as epa

ROOT = Path(__file__).resolve().parents[1]


def rows_for(questions):
    return [{"cohort": cohort, "question_id": qid, "arm": arm} for cohort, qid in questions for arm in epa.ARMS]


class Contracts(unittest.TestCase):
    def test_jobs_answer_every_question_and_arm_three_times_in_alternating_order(self):
        questions = [("retrieval-on-21", "q1"), ("preference-27", "q2"), ("temporal-25", "q3")]
        jobs = epa.jobs_for(rows_for(questions))
        self.assertEqual(len(jobs), len(questions) * len(epa.ARMS) * epa.REPLICATES)
        for cohort, qid in questions:
            for arm in epa.ARMS:
                replicates = sorted(job["replicate"] for job in jobs if (job["cohort"], job["question_id"], job["arm"])
                                    == (cohort, qid, arm))
                self.assertEqual(replicates, [0, 1, 2])
        firsts = [jobs[index]["arm"] for index in range(0, len(jobs), 2)]
        self.assertEqual(firsts[:3], ["ordinary_send", "exchange_packed", "ordinary_send"])
        self.assertEqual(firsts[3:6], ["exchange_packed", "ordinary_send", "exchange_packed"])
        self.assertEqual(sum(1 for arm in firsts if arm == "ordinary_send"), 5)

    def test_sign_test_and_bootstrap_are_exact_and_deterministic(self):
        self.assertEqual(epa.sign_test(4, 0), 0.125)
        self.assertEqual(epa.sign_test(0, 0), 1.0)
        self.assertAlmostEqual(epa.sign_test(11, 2), 0.0225, places=4)
        values = [0, 0, 33.3, 66.7, -33.3, 0, 100, 0]
        first = epa.bootstrap_interval(values, "seed", resamples=2000)
        self.assertEqual(first, epa.bootstrap_interval(values, "seed", resamples=2000))
        self.assertLessEqual(first[0], sum(values) / len(values))
        self.assertGreaterEqual(first[1], sum(values) / len(values))
        self.assertEqual(epa.bootstrap_interval([5.0] * 10, "seed", resamples=100), (5.0, 5.0))
        with self.assertRaisesRegex(epa.EvaluationError, "no_differences"):
            epa.bootstrap_interval([], "seed")

    def test_paired_reports_points_on_the_question_unit(self):
        per_question = {"a": {"ordinary_send": 0.0, "exchange_packed": 1.0},
                        "b": {"ordinary_send": 1 / 3, "exchange_packed": 1 / 3},
                        "c": {"ordinary_send": 1.0, "exchange_packed": 2 / 3}}
        result = epa.paired(per_question, ["a", "b", "c"], "seed")
        self.assertEqual((result["better"], result["worse"], result["tie"]), (1, 1, 1))
        self.assertEqual(result["baseline_percent"], 44.4)
        self.assertEqual(result["candidate_percent"], 66.7)
        self.assertEqual(result["difference_points"], 22.2)

    def test_decision_rule_is_the_declared_one(self):
        cohorts = {name: {"difference_points": 1.0} for name in epa.COHORTS}
        self.assertEqual(epa.decide({"difference_points": 6.0, "interval_points": [0.5, 11.0]}, cohorts),
                         {"promote": True, "retrieval_lever": True, "outcome": "promote", "promote_minimum_points": 0.0})
        self.assertEqual(epa.decide({"difference_points": 2.0, "interval_points": [-1.5, 5.0]}, cohorts),
                         {"promote": True, "retrieval_lever": False, "outcome": "promote", "promote_minimum_points": 0.0})
        self.assertEqual(epa.decide({"difference_points": 2.0, "interval_points": [-2.5, 5.0]}, cohorts)["outcome"],
                         "no_default_change")
        self.assertEqual(epa.decide({"difference_points": -0.5, "interval_points": [-1.0, 1.0]}, cohorts)["outcome"],
                         "no_default_change")
        falling = dict(cohorts, **{"temporal-25": {"difference_points": -6.0}})
        self.assertEqual(epa.decide({"difference_points": 6.0, "interval_points": [0.5, 11.0]}, falling),
                         {"promote": False, "retrieval_lever": True, "outcome": "no_default_change", "promote_minimum_points": 0.0})
        rule = epa.decision_rule()
        self.assertIn("-2 points", rule["promote"])
        self.assertIn("D >= 0,", rule["promote"])
        self.assertIn("+5 points", rule["retrieval_lever"])
        self.assertEqual(rule["promote_minimum_points"], 0.0)
        # A declared threshold raises the promotion bar only; the lever rule is unchanged.
        self.assertEqual(epa.decide({"difference_points": 4.0, "interval_points": [0.5, 8.0]}, cohorts, 5.0)["outcome"],
                         "no_default_change")
        self.assertEqual(epa.decide({"difference_points": 5.0, "interval_points": [-1.0, 11.0]}, cohorts, 5.0),
                         {"promote": True, "retrieval_lever": False, "outcome": "promote", "promote_minimum_points": 5.0})

    def test_configured_arms_drive_the_rule_and_are_restored(self):
        try:
            self.assertEqual(epa.configure_arms("exchange_packed", "exchange_wide", 5), ("exchange_packed", "exchange_wide"))
            self.assertEqual((epa.BASELINE, epa.CANDIDATE, epa.PROMOTE_MINIMUM_POINTS), ("exchange_packed", "exchange_wide", 5.0))
            rule = epa.decision_rule()
            self.assertIn("exchange_wide minus exchange_packed", rule["difference"])
            self.assertIn("recommend exchange_wide", rule["promote"])
            self.assertIn("D >= 5,", rule["promote"])
            self.assertEqual(rule["promote_minimum_points"], 5.0)
            jobs = epa.jobs_for(rows_for([("temporal-25", "q1")]))
            self.assertEqual(sorted({job["arm"] for job in jobs}), ["exchange_packed", "exchange_wide"])
            with self.assertRaisesRegex(epa.EvaluationError, "arms_invalid"):
                epa.configure_arms("exchange_wide", "exchange_wide")
            with self.assertRaisesRegex(epa.EvaluationError, "arms_invalid"):
                epa.configure_arms("ordinary_send", "recent_only")
            with self.assertRaisesRegex(epa.EvaluationError, "promotion_threshold_invalid"):
                epa.configure_arms("ordinary_send", "exchange_packed", -1)
        finally:
            epa.configure_arms("ordinary_send", "exchange_packed", 0)
        self.assertEqual(epa.ARMS, ("ordinary_send", "exchange_packed"))
        self.assertEqual(epa.PROMOTE_MINIMUM_POINTS, 0.0)

    def test_scope_reader_and_arms_are_pinned(self):
        self.assertEqual(epa.ARMS, ("ordinary_send", "exchange_packed"))
        self.assertIn("exchange_wide", epa.SELECTABLE_ARMS)
        self.assertEqual(epa.COHORTS, ("retrieval-on-21", "preference-27", "temporal-25"))
        self.assertEqual(epa.READER, "gemini-3.8-flash")
        self.assertIn(epa.READER, epa.rc.READERS)
        self.assertEqual(epa.EXCLUDED_FROM_COUNTS, ("54026fce",))
        self.assertEqual(epa.answer_name("exchange_packed", "temporal-25", "q", 2), "exchange_packed/temporal-25--q--r2")

    def test_harness_accepts_both_arms_in_one_capture(self):
        source = (ROOT / "Tests/Evaluation/DeliveryHarness.swift").read_text()
        self.assertIn('case "exchange_packed": limits.componentPolicy = .selectedQwenExchangePacked', source)
        self.assertIn('case "exchange_wide": limits.componentPolicy = .selectedQwenExchangeWide', source)
        self.assertIn('"ordinary_send"].contains($0) || exchangeLimits($0) != nil', source)
        self.assertIn("Set(input.arms).count == input.arms.count", source)
        driver = (ROOT / "scripts/exchange_packed_answers.py").read_text()
        self.assertIn('"arms": list(ARMS)', driver)
        self.assertIn('"baseline_does_not_match_reference"', driver)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
