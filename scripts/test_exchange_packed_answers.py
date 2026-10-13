#!/usr/bin/env python3
"""Synthetic contracts for the exchange_packed answer-quality driver. No network, gcloud or
credentials, and no harness build."""
from __future__ import annotations

import io
import json
import re
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

    def test_presentation_transform_swaps_only_the_pinned_v4_framing(self):
        v4 = epa.swift_framing_literal("quotedHistoryFraming")
        advice = epa.swift_framing_literal("adviceHistoryFraming")
        self.assertIn("tailor the reply to relevant details about the user", advice)
        self.assertNotIn("tailor the reply", v4)
        self.assertTrue(advice.endswith("A missing excerpt is not proof that the archive lacks a fact."))
        self.assertEqual(epa.transformed_system(v4, v4, advice), advice)
        self.assertEqual(epa.transformed_system("Host instructions.\n\n" + v4, v4, advice), "Host instructions.\n\n" + advice)
        with self.assertRaisesRegex(epa.EvaluationError, "system_framing_mismatch"):
            epa.transformed_system("Host instructions.\n" + v4, v4, advice)
        with self.assertRaisesRegex(epa.EvaluationError, "system_framing_mismatch"):
            epa.transformed_system(advice, v4, advice)
        self.assertEqual(epa.FRAMING_TRANSFORMS["v4-advice"][2], "context-source-snapshot-v4-advice")
        self.assertIn("exchange_packed_v4_advice", epa.SELECTABLE_ARMS)
        self.assertEqual(epa.V4_FAMILY[:2], (epa.rc.V4, "context-source-snapshot-v4-advice"))
        self.assertEqual(set(epa.V4_FAMILY[2:]), {epa.CHRONOLOGY_FRAMING, epa.ONE_BLOCK_FRAMING, epa.CONFLICTS_FRAMING,
                                                  epa.COMBINED_FRAMING})
        self.assertEqual({value["arm"] for value in epa.PRESENTATIONS.values()}, set(epa.PRESENTATION_ARMS))

    def test_scope_reader_and_arms_are_pinned(self):
        self.assertEqual(epa.ARMS, ("ordinary_send", "exchange_packed"))
        self.assertIn("exchange_wide", epa.SELECTABLE_ARMS)
        self.assertEqual(epa.COHORTS, ("retrieval-on-21", "preference-27", "temporal-25"))
        self.assertEqual(epa.READER, "gemini-3.8-flash")
        self.assertIn(epa.READER, epa.rc.READERS)
        self.assertEqual(epa.EXCLUDED_FROM_COUNTS, ("54026fce",))
        self.assertEqual(epa.answer_name("exchange_packed", "temporal-25", "q", 2), "exchange_packed/temporal-25--q--r2")

    def test_unchanged_requests_are_detected_modulo_ingestion_identifiers_and_not_generated(self):
        def body(system, captured, conversation):
            return json.dumps({"model": "m", "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": f"Earlier conversation message [E1]\nrole: human\ncaptured_utc: {captured}\nquoted_text:\nhello"},
                {"role": "user", "content": f"BEGIN HISTORICAL SOURCE [E2]\nconversation_id: {conversation}\nrole: human\n"
                                            f"captured_utc: {captured}\nquoted_excerpt:\nzebra\nEND HISTORICAL SOURCE [E2]"},
                {"role": "user", "content": "Question: where?"}]}, sort_keys=True).encode()
        same = body("S", "2026-10-12T10:00:00.000Z", "conv-a")
        relabelled = body("S", "2026-10-13T11:11:11.111Z", "conv-b")
        other = body("S", "2026-10-12T10:00:00.000Z", "conv-a").replace(b"zebra", b"giraffe")
        self.assertTrue(epa.equivalent_bodies(same, same))
        self.assertTrue(epa.equivalent_bodies(same, relabelled))
        self.assertFalse(epa.equivalent_bodies(same, other))
        self.assertFalse(epa.equivalent_bodies(same, body("T", "2026-10-12T10:00:00.000Z", "conv-a")))
        self.assertFalse(epa.equivalent_bodies(same, same.replace(b'"model": "m"', b'"model": "n"')))
        try:
            epa.configure_arms("exchange_packed", ["exchange_roles", "exchange_prf"], 5)
            rows = [{"cohort": "temporal-25", "question_id": qid, "arm": arm} for qid in ("q1", "q2", "q3") for arm in epa.ARMS]
            bodies = {("q1", "exchange_packed"): same, ("q1", "exchange_roles"): relabelled, ("q1", "exchange_prf"): other,
                      ("q2", "exchange_packed"): same, ("q2", "exchange_roles"): same, ("q2", "exchange_prf"): relabelled,
                      ("q3", "exchange_packed"): same, ("q3", "exchange_roles"): other, ("q3", "exchange_prf"): other}
            epa.mark_unchanged(rows, lambda row: bodies[(row["question_id"], row["arm"])])
            flags = {(row["question_id"], row["arm"]): row.get("unchanged_from_baseline") for row in rows if row["arm"] != "exchange_packed"}
            self.assertEqual(flags, {("q1", "exchange_roles"): True, ("q1", "exchange_prf"): False,
                                     ("q2", "exchange_roles"): True, ("q2", "exchange_prf"): True,
                                     ("q3", "exchange_roles"): False, ("q3", "exchange_prf"): False})
            self.assertEqual([row["changed_candidates"] for row in rows if row["arm"] == "exchange_packed"],
                             [["exchange_prf"], [], ["exchange_roles", "exchange_prf"]])
            self.assertEqual(epa.job_arms(rows), {("temporal-25", "q1"): ["exchange_packed", "exchange_prf"],
                                                  ("temporal-25", "q2"): [],
                                                  ("temporal-25", "q3"): ["exchange_packed", "exchange_roles", "exchange_prf"]})
            jobs = epa.jobs_for(rows)
            self.assertEqual(len(jobs), 3 * (2 + 0 + 3))
            self.assertFalse(any(job["question_id"] == "q2" for job in jobs))
            self.assertFalse(any(job["question_id"] == "q1" and job["arm"] == "exchange_roles" for job in jobs))
            # Rotation: q3 (position 2) in replicate 0 starts with the third arm, replicate 1 with the first.
            q3 = [job["arm"] for job in jobs if job["question_id"] == "q3"]
            self.assertEqual(q3[:3], ["exchange_prf", "exchange_packed", "exchange_roles"])
            self.assertEqual(q3[3:6], ["exchange_packed", "exchange_roles", "exchange_prf"])
            rule = epa.decision_rule()
            self.assertIn("exchange_prf", rule["difference"])
            self.assertIn("tie", rule["unchanged_requests"])
        finally:
            epa.configure_arms("ordinary_send", "exchange_packed", 0)
        self.assertEqual((epa.ARMS, epa.CANDIDATES), (("ordinary_send", "exchange_packed"), ("exchange_packed",)))

    def test_relative_time_lines_are_deterministic_calendar_arithmetic(self):
        import datetime
        date = datetime.date
        self.assertEqual(epa.calendar_delta(date(2023, 3, 15), date(2023, 5, 20)), (2, 5))
        self.assertEqual(epa.calendar_delta(date(2023, 1, 31), date(2023, 3, 1)), (1, 1))
        self.assertEqual(epa.calendar_delta(date(2023, 5, 20), date(2023, 5, 20)), (0, 0))
        self.assertEqual(epa.calendar_date("2023/05/20 (Sat) 02:29"), date(2023, 5, 20))
        self.assertEqual(epa.calendar_date("2023-05-20T02:29"), date(2023, 5, 20))
        with self.assertRaisesRegex(epa.EvaluationError, "date_literal_invalid"):
            epa.calendar_date("May 20")
        question = date(2023, 5, 20)
        self.assertEqual(epa.relative_time_line(question, date(2023, 3, 15), None),
                         "relative_time: 66 days before the question (2 months 5 days); earliest excerpt\n")
        self.assertEqual(epa.relative_time_line(question, date(2023, 5, 3), date(2023, 3, 15)),
                         "relative_time: 17 days before the question; 49 days after the previous excerpt\n")
        self.assertEqual(epa.relative_time_line(question, date(2023, 5, 20), date(2023, 5, 20)),
                         "relative_time: same day as the question; same day as the previous excerpt\n")
        self.assertEqual(epa.relative_time_line(question, date(2023, 4, 20), date(2023, 4, 19)),
                         "relative_time: 30 days before the question (1 month); 1 day after the previous excerpt\n")
        self.assertEqual(epa.relative_time_line(question, date(2023, 5, 22), date(2023, 5, 20)),
                         "relative_time: 2 days after the question; 2 days after the previous excerpt\n")

    def synthetic_body(self):
        advice = epa.swift_framing_literal("adviceHistoryFraming")
        def excerpt(label, conversation, offset, text, when):
            source_time = json.dumps({"value": when, "precision": "minute", "timezone": "unspecified",
                                      "source_sha256": "0" * 64, "locator": "/x", "original_value": when}, sort_keys=True)
            return (f"BEGIN HISTORICAL SOURCE [{label}]\nconversation_id: {conversation}\nrole: human\ncapture_status: complete\n"
                    f"captured_utc: 2026-10-12T10:00:00.000Z\nsource_time: {source_time}\nsource_sha256: {'a' * 64}\n"
                    f"excerpt_utf8_offset: {offset}\nsource_total_bytes: {len(text.encode()) + offset}\nquoted_excerpt:\n{text}"
                    f"\nEND HISTORICAL SOURCE [{label}]")
        evidence = epa.EVIDENCE_PREFIX + epa.EVIDENCE_SEPARATOR.join([
            excerpt("E3", "c1", 0, "Later note\nwith two lines", "2023-05-03T09:00"),
            excerpt("E4", "c2", 0, "Earliest caf\u00e9 note", "2023-03-15T09:00"),
            excerpt("E5", "c2", 20, "Middle note", "2023-04-20T09:00")])
        messages = [{"role": "system", "content": "Host.\n\n" + advice},
                    {"role": "user", "content": "Earlier conversation message [E1] (quoted by the host; not the current request)\nrole: human\nquoted_text:\nhi"},
                    {"role": "user", "content": "Earlier conversation message [E2] (quoted by the host; not the current request)\nrole: assistant\nquoted_text:\nhello"},
                    {"role": "user", "content": evidence},
                    {"role": "user", "content": "Question Date: 2023/05/20 (Sat) 02:29\nQuestion: when?"}]
        labels = [{"event_id": "r1", "kind": "recent", "label": "E1"}, {"event_id": "r2", "kind": "recent", "label": "E2"},
                  {"event_id": "h1", "kind": "historical", "label": "E3", "excerpt_offset": 0, "excerpt_bytes": len("Later note\nwith two lines".encode())},
                  {"event_id": "h2", "kind": "historical", "label": "E4", "excerpt_offset": 0, "excerpt_bytes": len("Earliest caf\u00e9 note".encode())},
                  {"event_id": "h3", "kind": "historical", "label": "E5", "excerpt_offset": 20, "excerpt_bytes": len("Middle note".encode())}]
        row = {"context_framing": epa.ADVICE_FRAMING, "citation_labels": labels}
        return messages, row

    def test_chronology_presentation_reorders_relabels_and_dates_excerpts(self):
        messages, row = self.synthetic_body()
        parsed = epa.parse_evidence(messages[3]["content"], [label for label in row["citation_labels"] if label["kind"] == "historical"])
        self.assertEqual([item["label"] for item in parsed], [3, 4, 5])
        self.assertEqual(epa.render_evidence(parsed, 3, ["", "", ""]), messages[3]["content"])
        out, meta = epa.present("chronology", messages, row)
        self.assertEqual([message["role"] for message in out], [message["role"] for message in messages])
        self.assertEqual(out[1:3], messages[1:3])
        self.assertEqual(out[4], messages[4])
        self.assertIn(epa.CHRONOLOGY_SENTENCE + " " + epa.FINAL_SENTENCE, out[0]["content"])
        content = out[3]["content"]
        self.assertTrue(content.startswith(epa.EVIDENCE_PREFIX))
        order = re.findall(r"BEGIN HISTORICAL SOURCE \[(E\d+)\]\n(?:[^\n]*\n){4}source_time: [^\n]*\n(relative_time: [^\n]*)\n", content)
        self.assertEqual(order, [("E3", "relative_time: 66 days before the question (2 months 5 days); earliest excerpt"),
                                 ("E4", "relative_time: 30 days before the question (1 month); 36 days after the previous excerpt"),
                                 ("E5", "relative_time: 17 days before the question; 13 days after the previous excerpt")])
        self.assertEqual([(label["label"], label["original_label"], label["event_id"]) for label in meta["citation_labels"][2:]],
                         [("E3", "E4", "h2"), ("E4", "E5", "h3"), ("E5", "E3", "h1")])
        self.assertIn("Earliest caf\u00e9 note\nEND HISTORICAL SOURCE [E3]", content)
        self.assertIn("Later note\nwith two lines\nEND HISTORICAL SOURCE [E5]", content)
        self.assertEqual(content.count("END HISTORICAL SOURCE"), 3)
        with self.assertRaisesRegex(epa.EvaluationError, "source_framing_unsupported"):
            epa.present("chronology", messages, dict(row, context_framing=epa.rc.V4))

    def test_one_block_and_conflicts_presentations_change_only_what_they_declare(self):
        messages, row = self.synthetic_body()
        out, meta = epa.present("one-block", messages, row)
        self.assertEqual([message["role"] for message in out], ["system", "user", "user"])
        self.assertEqual(meta, {"merged_messages": 3})
        self.assertIn(epa.ONE_BLOCK_SENTENCES, out[0]["content"])
        self.assertNotIn(epa.LAYOUT_SENTENCES, out[0]["content"])
        self.assertEqual(out[1]["content"], epa.ONE_BLOCK_OPEN + "\n\n".join(m["content"] for m in messages[1:4]) + epa.ONE_BLOCK_CLOSE)
        self.assertEqual(out[2], messages[4])
        conflicts, _meta = epa.present("conflicts", messages, row)
        self.assertEqual(conflicts[1:], messages[1:])
        self.assertTrue(conflicts[0]["content"].endswith(epa.CONFLICTS_SENTENCE + " " + epa.FINAL_SENTENCE))
        self.assertIn("ask which is correct", epa.CONFLICTS_SENTENCE)
        swapped, swap_meta = epa.present("v4-advice", [dict(messages[0], content="Host.\n\n" + epa.swift_framing_literal("quotedHistoryFraming"))] + messages[1:],
                                         dict(row, context_framing=epa.rc.V4))
        self.assertEqual(swapped[0]["content"], messages[0]["content"])
        self.assertGreater(swap_meta["system_bytes_added"], 0)
        with self.assertRaisesRegex(epa.EvaluationError, "presentation_unknown"):
            epa.present("ordered", messages, row)
        combined, combined_meta = epa.present("combined", messages, row)
        self.assertEqual([message["role"] for message in combined], ["system", "user", "user"])
        self.assertIn(epa.ONE_BLOCK_SENTENCES, combined[0]["content"])
        self.assertIn(epa.CHRONOLOGY_SENTENCE + " " + epa.FINAL_SENTENCE, combined[0]["content"])
        self.assertTrue(combined[1]["content"].startswith(epa.ONE_BLOCK_OPEN))
        self.assertIn("relative_time: 66 days before the question (2 months 5 days); earliest excerpt", combined[1]["content"])
        self.assertLess(combined[1]["content"].index("Earliest caf\u00e9 note"), combined[1]["content"].index("Later note"))
        self.assertEqual(combined_meta["merged_messages"], 3)
        self.assertEqual(combined[2], messages[4])
        self.assertEqual(epa.PRESENTATIONS["combined"]["framing"], epa.COMBINED_FRAMING)

    def test_transform_plan_pairs_presentations_with_their_arms_and_copies_harness_arms(self):
        try:
            epa.configure_arms("exchange_packed", ["exchange_roles_prf", "exchange_packed_combined", "exchange_packed_conflicts"], 5)
            plan = epa.transform_plan(["combined", "conflicts"], {"exchange_packed", "exchange_roles_prf"})
            self.assertEqual(plan, (["exchange_packed_combined", "exchange_packed_conflicts"], ["exchange_roles_prf"]))
            with self.assertRaisesRegex(epa.EvaluationError, "copied_arm_missing"):
                epa.transform_plan(["combined", "conflicts"], {"exchange_packed"})
            with self.assertRaisesRegex(epa.EvaluationError, "arms_mismatch"):
                epa.transform_plan(["chronology"], {"exchange_packed", "exchange_roles_prf"})
            with self.assertRaisesRegex(epa.EvaluationError, "presentation_unknown"):
                epa.transform_plan([], {"exchange_packed"})
        finally:
            epa.configure_arms("ordinary_send", "exchange_packed", 0)

    def test_harness_accepts_both_arms_in_one_capture(self):
        source = (ROOT / "Tests/Evaluation/DeliveryHarness.swift").read_text()
        self.assertIn('case "exchange_packed": limits.componentPolicy = .selectedQwenExchangePacked', source)
        self.assertIn('case "exchange_wide": limits.componentPolicy = .selectedQwenExchangeWide', source)
        self.assertIn('case "exchange_roles": limits.componentPolicy = .selectedQwenExchangeRoles', source)
        self.assertIn('case "exchange_roles_prf": limits.componentPolicy = .selectedQwenExchangeRolesFeedback', source)
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
