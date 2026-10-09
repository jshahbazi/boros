#!/usr/bin/env python3
"""Synthetic contracts for the framing V4 variants: the System-text derivation of V4-advice and
V4-ordered from the pinned V4 bytes, their reachability, the version-10 temporal cohort, the replay
plan and cap, the self-contradiction detector and both pre-declared lexical rules.
No private data, network or model calls."""
from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import answer_presentation_replay as replay  # noqa: E402
import framing_v4_temporal_cases as temporal  # noqa: E402
import framing_v4_variants_replay as plan  # noqa: E402
import native_investigation_hundred_cases as hundred  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "Boros"


def assembler():
    return (SOURCES / "ContextAssembler.swift").read_text()


def literal(name):
    match = re.search(r'private static let ' + name + r' = """\n(.*?)\n\s*"""', assembler(), re.S)
    assert match is not None, name
    return match.group(1).strip()


def tuple_field(name):
    match = re.search(r"\b" + name + r': "((?:[^"\\]|\\.)*)"', assembler())
    assert match is not None, name
    return match.group(1).replace('\\"', '"')


def row(cohort, qid, arm, outcome="answer", abstention=False, kind="multi-session", gold="whole", index=0,
        disclaimer=0, contradiction=False, status="measured"):
    return {"cohort": cohort, "question_id": qid, "arm": arm, "outcome": outcome, "abstention": abstention,
            "question_type": kind, "declared_gold_delivery": gold, "run_index": index, "ai_disclaimer": disclaimer,
            "self_contradiction": contradiction, "status": status}


class Contracts(unittest.TestCase):
    def test_variants_derive_from_pinned_v4_bytes(self):
        v4 = literal("quotedHistoryFraming")
        advice, ordered = literal("adviceHistoryFraming"), literal("orderedConclusionHistoryFraming")
        second, scoped = tuple_field("second"), tuple_field("scoped")
        added_advice, added_ordered = tuple_field("advice"), tuple_field("ordered")
        pinned = re.search(r'v4SystemFramingSHA256 = "([0-9a-f]{64})"',
                           (SOURCES / "RecentSourceFramingChecks.swift").read_text()).group(1)
        self.assertEqual(hashlib.sha256(v4.encode()).hexdigest(), pinned)
        self.assertEqual(v4.count(second), 1)
        self.assertEqual(advice, v4.replace(second, second + " " + added_advice))
        self.assertEqual(ordered, v4.replace(second, second + " " + added_ordered))
        # V4-advice adds exactly V5's advice clause and nothing else of V5.
        self.assertIn(added_advice, scoped)
        self.assertIn("the conversation history provided here does not show it", advice)
        self.assertNotIn("check every quoted source", advice)
        self.assertNotIn("specific fact from the user's past", advice)
        self.assertIn("date or count arithmetic", added_ordered)
        self.assertIn("before you state the conclusion", added_ordered)
        self.assertIn("never revise a conclusion", added_ordered)
        self.assertNotIn(added_advice, ordered)
        self.assertTrue(advice.endswith(added_advice + " A missing excerpt is not proof that the archive lacks a fact."))
        self.assertTrue(ordered.endswith(added_ordered + " A missing excerpt is not proof that the archive lacks a fact."))

    def test_variants_selectable_only_through_context_framing(self):
        framing = (SOURCES / "ContextSourceFraming.swift").read_text()
        self.assertIn('static let adviceSelectionVersion = "context-source-snapshot-v4-advice"', framing)
        self.assertIn('static let orderedConclusionSelectionVersion = "context-source-snapshot-v4-ordered"', framing)
        self.assertIn("static let defaultSelectionVersion = quotedSelectionVersion", framing)
        self.assertIn("evaluationOnlySelectionVersions: Set<String> = [insufficientEvidenceAblationSelectionVersion]", framing)
        checks = {"RecentSourceFramingChecks.swift", "ComponentPreparationChecks.swift"}
        for constant, raw in (("adviceSelectionVersion", plan.ADVICE), ("orderedConclusionSelectionVersion", plan.ORDERED)):
            referencing = {path.name for path in SOURCES.glob("*.swift") if constant in path.read_text()}
            self.assertEqual(referencing - checks, {"ContextSourceFraming.swift", "ContextAssembler.swift",
                                                    "AnswerEvaluationCommand.swift"})
            literal_files = {path.name for path in SOURCES.glob("*.swift") if raw in path.read_text()}
            # AnswerEvaluationCommand.swift carries near-miss spellings in its synthetic CLI checks only.
            self.assertEqual(literal_files - checks - {"AnswerEvaluationCommand.swift"}, {"ContextSourceFraming.swift"})
        gui = (SOURCES / "BonsaiPlayground.swift").read_text()
        self.assertNotIn("contextFraming =", gui)
        self.assertNotIn("v4-advice", gui)
        self.assertNotIn("v4-ordered", gui)
        command = (SOURCES / "AnswerEvaluationCommand.swift").read_text()
        block = command.split("static let pinnableFramings = [", 1)[1].split("]", 1)[0]
        self.assertIn("ContextSourceFraming.adviceSelectionVersion", block)
        self.assertIn("ContextSourceFraming.orderedConclusionSelectionVersion", block)

    def test_temporal_cohort_pins_and_selection(self):
        self.assertEqual(len(temporal.PROJECTION_PINS), 25)
        swift = (SOURCES / "AnswerEvaluationCommand.swift").read_text()
        block = swift.split("temporalLongMemoryCorpusProjectionSHA256: Set<String> = [", 1)[1].split("]", 1)[0]
        self.assertEqual(set(re.findall(r'"([0-9a-f]{64})"', block)), set(temporal.PROJECTION_PINS.values()))
        self.assertFalse(set(temporal.PROJECTION_PINS) & set(replay.PILOT_QUESTIONS + replay.INDEPENDENT_QUESTIONS))
        self.assertFalse(any(qid.endswith("_abs") for qid in temporal.PROJECTION_PINS))
        manifest = {"cohort": hundred.COHORT, "case_ids": [f"q{index}" for index in range(hundred.COUNT)],
                    "case_types": ["multi-session"] * hundred.COUNT}
        manifest["case_ids"][3], manifest["case_types"][3] = "t1", "temporal-reasoning"
        manifest["case_ids"][7], manifest["case_types"][7] = "t2_abs", "temporal-reasoning"
        manifest["case_ids"][9], manifest["case_types"][9] = "t0", "temporal-reasoning"
        chosen, left_out = temporal.select(manifest)
        self.assertEqual(chosen, ("t1", "t0"))
        self.assertEqual(left_out, ("t2_abs",))

    def test_version_ten_document_is_version_eight_with_only_the_version_changed(self):
        events = [{"id": "e1", "project_id": "p", "conversation_key": "c", "role": "user", "status": "complete",
                   "text": "x", "source_time": None, "extra": "scorer-only"}]
        history = {"id": "h", "events": events, "episodes": [{"id": "probe", "project_id": "p", "conversation_key": "c",
                                                              "prompt": "Q", "question_time": None, "answer": "ref"}]}
        old, new = hundred.runner_input(history), temporal.runner_input(history)
        self.assertEqual(old["version"], 8)
        self.assertEqual(new["version"], 10)
        self.assertEqual({**new, "version": 8}, old)
        self.assertNotIn("answer", json.dumps(new["attempts"]))
        self.assertEqual(new["configuration"]["maximum_output"], 1024)

    def test_plan_cohorts_arms_and_cap(self):
        cohorts = plan.cohorts()
        self.assertEqual(list(cohorts), list(plan.COHORT_ORDER))
        self.assertEqual([len(cohorts[name][0]) for name in plan.COHORT_ORDER], [21, 27, 25, 21])
        self.assertEqual([cohorts[name][1] for name in plan.COHORT_ORDER],
                         ["ordinary_send", "ordinary_send", "ordinary_send", None])
        self.assertEqual(plan.ARMS, (("v4-default", None), ("v4-advice", plan.ADVICE), ("v4-ordered", plan.ORDERED)))
        runs = sum(len(cohorts[name][0]) for name in plan.COHORT_ORDER) * len(plan.ARMS)
        self.assertEqual(runs, 282)
        self.assertLessEqual(runs, plan.GENERATION_CAP)
        self.assertEqual(plan.GENERATION_CAP, 290)
        entry = {"attempt": 0, "context_framing": plan.ADVICE, "component_policy": "selected-model-context-components-v1",
                 "retrieval_arm": "ordinary_send"}
        command = replay.runner_command(Path("/b"), Path("/i.json"), Path("/o"), entry)
        self.assertEqual(command[-4:], ["--context-framing", plan.ADVICE, "--retrieval-arm", "ordinary_send"])
        self.assertEqual(plan.input_name({"cohort": "temporal-25", "question_id": "x"}), "temporal-25--x.json")
        self.assertIn("PENDING", plan.DECISION_RULES["common"]["judged_accepts"])

    def test_self_contradiction_detector(self):
        ref = "the garden task"
        wrong_first = "**You did the kitchen task first.**\n\nThe kitchen task was on May 9 [E2].\n\nSo the garden task came first."
        right_first = "**You did the garden task first.**\n\nIt was on May 2 [E1], before the kitchen task."
        hedge = "**You did the kitchen task first.**\n\nDates are close.\n\nIf you count planning, the garden task was first."
        revision = "The kitchen task came first. Wait, let me re-check: it was the garden task."
        label = "**Dates from the sources:**\n\nGarden: May 2.\n\nSo the garden task came first."
        single = "**The kitchen task.** Later the garden task."
        self.assertTrue(plan.self_contradiction(wrong_first, ref, False)["late_reference"])
        self.assertFalse(plan.self_contradiction(right_first, ref, False)["self_contradiction"])
        self.assertFalse(plan.self_contradiction(hedge, ref, False)["self_contradiction"])
        self.assertTrue(plan.self_contradiction(revision, ref, False)["explicit_revision"])
        self.assertFalse(plan.self_contradiction(label, ref, False)["self_contradiction"])
        self.assertFalse(plan.self_contradiction(single, ref, False)["self_contradiction"])
        self.assertFalse(plan.self_contradiction(wrong_first, ref, True)["late_reference"])
        numeric = "**It took 5 days.**\n\nFrom May 1 [E1] to May 8 [E3].\n\nThat is 7 days in total."
        self.assertTrue(plan.self_contradiction(numeric, "7 days. 8 days (including the last day) is also acceptable.",
                                                False)["late_reference"])
        self.assertEqual(plan.reference_targets("7 days. 8 days (including the last day) is also acceptable."),
                         ["7 days"])
        self.assertEqual(plan.reference_targets(" ".join(["word"] * 9)), [])
        counts = plan.confusion([("a", True, True), ("b", False, True), ("c", True, False), ("d", False, False)])
        self.assertEqual({key: value["count"] for key, value in counts.items()},
                         {"true_positive": 1, "false_positive": 1, "false_negative": 1, "true_negative": 1})

    def rows(self, advice_pref="answer", advice_abs="decline", advice_recent="decline", advice_disclaimer=0,
             ordered_contradiction=False, ordered_whole="answer"):
        rows, index = [], 0
        for arm, _ in plan.ARMS:
            def add(*args, **kwargs):
                nonlocal index
                rows.append(row(*args, index=index, **kwargs)); index += 1
            add("preference-27", "p1", arm, outcome=advice_pref if arm == "v4-advice" else "decline",
                kind=plan.PREFERENCE_TYPE)
            add("preference-27", "p2", arm, kind=plan.PREFERENCE_TYPE, gold="none", outcome="decline")
            add("retrieval-on-21", "54026fce", arm, outcome="decline", kind=plan.PREFERENCE_TYPE, disclaimer=1)
            add("retrieval-on-21", "x_abs", arm, abstention=True, gold="no_gold_turns",
                outcome=advice_abs if arm == "v4-advice" else "decline")
            add("retrieval-on-21", "t9", arm, kind=plan.TEMPORAL_TYPE,
                contradiction=ordered_contradiction if arm == "v4-ordered" else arm == "v4-default")
            add("temporal-25", "t1", arm, kind=plan.TEMPORAL_TYPE, outcome=ordered_whole if arm == "v4-ordered" else "answer")
            add("recent-only-21", "r1", arm, gold="none", outcome=advice_recent if arm == "v4-advice" else "decline",
                disclaimer=advice_disclaimer if arm == "v4-advice" else 0)
        return rows

    def test_advice_rule(self):
        result = plan.decision(self.rows())["v4-advice"]
        self.assertTrue(result["lexical_criteria_hold"])
        self.assertEqual(result["A1_fewer_false_declines_on_preference_gold_whole"]["questions"], 1)
        self.assertEqual(result["A4_zero_disclaimers"]["v4-advice"], 0)  # 54026fce excluded
        self.assertFalse(plan.decision(self.rows(advice_pref="decline"))["v4-advice"]["lexical_criteria_hold"])
        self.assertFalse(plan.decision(self.rows(advice_abs="answer"))["v4-advice"]["lexical_criteria_hold"])
        self.assertFalse(plan.decision(self.rows(advice_recent="answer"))["v4-advice"]["lexical_criteria_hold"])
        self.assertFalse(plan.decision(self.rows(advice_disclaimer=1))["v4-advice"]["lexical_criteria_hold"])
        missing = self.rows()
        missing[0] = {**missing[0], "status": "not_run"}
        self.assertFalse(plan.decision(missing)["v4-advice"]["A1_fewer_false_declines_on_preference_gold_whole"]["holds"])

    def test_ordered_rule(self):
        result = plan.decision(self.rows())["v4-ordered"]
        self.assertTrue(result["lexical_criteria_hold"])
        self.assertEqual(result["O1_fewer_self_contradictions_on_temporal"],
                         {"v4-default": 1, "v4-ordered": 0, "questions": 2, "holds": True})
        self.assertFalse(plan.decision(self.rows(ordered_contradiction=True))["v4-ordered"]["lexical_criteria_hold"])
        self.assertFalse(plan.decision(self.rows(ordered_whole="decline"))["v4-ordered"]["lexical_criteria_hold"])
        no_base = [dict(item, self_contradiction=False) for item in self.rows()]
        self.assertFalse(plan.decision(no_base)["v4-ordered"]["O1_fewer_self_contradictions_on_temporal"]["holds"])
        self.assertEqual(plan.decision(self.rows())["judged_accepts"], "pending (grading not authorized)")


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
