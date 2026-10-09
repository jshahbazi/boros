#!/usr/bin/env python3
"""Synthetic contracts for framing V5: the System-text derivation from V4, the evaluation-only
restriction of the V4 no-G ablation, the fresh preference cohort's selection and opaque projection,
the replay plan, the declared decline measure and the pre-declared decision rule.
No private data, network or model calls."""
from __future__ import annotations

import io
import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import answer_presentation_replay as replay  # noqa: E402
import framing_v5_preference_cases as preference  # noqa: E402
import framing_v5_replay as plan  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "Boros"


def literal(name):
    text = (SOURCES / "ContextAssembler.swift").read_text()
    match = re.search(r'private static let ' + name + r' = """\n(.*?)\n\s*"""', text, re.S)
    assert match is not None, name
    return match.group(1).strip()


def tuple_field(name):
    text = (SOURCES / "ContextAssembler.swift").read_text()
    match = re.search(name + r': "((?:[^"\\]|\\.)*)"', text)
    assert match is not None, name
    return match.group(1).replace('\\"', '"')


def row(cohort, qid, arm, outcome="answer", abstention=False, kind="multi-session", gold="whole", index=0,
        disclaimer=0, status="measured"):
    return {"cohort": cohort, "question_id": qid, "arm": arm, "outcome": outcome, "abstention": abstention,
            "question_type": kind, "declared_gold_delivery": gold, "run_index": index, "ai_disclaimer": disclaimer,
            "status": status}


class Contracts(unittest.TestCase):
    def test_v5_and_ablation_system_text_derive_from_v4_bytes(self):
        v4, v5, ablation = literal("quotedHistoryFraming"), literal("scopedDeclineHistoryFraming"), \
            literal("insufficientEvidenceAblationHistoryFraming")
        first, second, scoped = tuple_field("first"), tuple_field("second"), tuple_field("scoped")
        self.assertEqual(v4.count(first + " " + second), 1)
        self.assertEqual(v5, v4.replace(second, scoped))
        self.assertEqual(ablation, v4.replace(" " + first + " " + second, ""))
        self.assertNotIn("conversation history provided here", v5)
        self.assertIn("including the historical excerpts", v5)
        self.assertIn("advice or suggestions", v5)
        self.assertIn("specific fact from the user's past", v5)
        self.assertIn("do not say that you are an AI", v5)
        self.assertNotIn("do not guess", ablation)
        # The V4 bytes are the ones measured since commit 85c5117.
        import hashlib
        pinned = re.search(r'v4SystemFramingSHA256 = "([0-9a-f]{64})"',
                           (SOURCES / "RecentSourceFramingChecks.swift").read_text()).group(1)
        self.assertEqual(hashlib.sha256(v4.encode()).hexdigest(), pinned)

    def test_ablation_is_reachable_only_through_answer_evaluation(self):
        constant = "insufficientEvidenceAblationSelectionVersion"
        raw = "context-source-snapshot-v4-no-g"
        checks = {"RecentSourceFramingChecks.swift", "ComponentPreparationChecks.swift"}
        referencing = {path.name for path in SOURCES.glob("*.swift") if constant in path.read_text()}
        self.assertEqual(referencing - checks, {"ContextSourceFraming.swift", "ContextAssembler.swift",
                                                "AnswerEvaluationCommand.swift"})
        literal_files = {path.name for path in SOURCES.glob("*.swift") if raw in path.read_text()}
        self.assertEqual(literal_files - checks - {"AnswerEvaluationCommand.swift"}, {"ContextSourceFraming.swift"})
        granting = {path.name for path in SOURCES.glob("*.swift")
                    if re.search(r"evaluationOnlyFramingPermitted\s*=(?!=)(?!\s*false\b)", path.read_text())}
        self.assertEqual(granting - checks, {"AnswerEvaluationCommand.swift"})
        gui = (SOURCES / "BonsaiPlayground.swift").read_text()
        self.assertNotIn("contextFraming =", gui)
        self.assertNotIn("evaluationOnlyFramingPermitted", gui)
        self.assertNotIn(constant, gui)
        coordinator = (SOURCES / "AnswerAttemptCoordinator.swift").read_text()
        self.assertIn("ContextSourceFraming.permits(settings.contextFraming", coordinator)
        framing = (SOURCES / "ContextSourceFraming.swift").read_text()
        self.assertIn("static let defaultSelectionVersion = quotedSelectionVersion", framing)
        self.assertIn("evaluationOnlySelectionVersions: Set<String> = [insufficientEvidenceAblationSelectionVersion]", framing)
        command = (SOURCES / "AnswerEvaluationCommand.swift").read_text()
        self.assertIn("settings.evaluationOnlyFramingPermitted = options?.framingPinned == true", command)

    def test_preference_selection_is_type_only_and_excludes_the_three(self):
        rows = [{"question_id": qid, "question_type": "single-session-preference"}
                for qid in ("p1", "p2", "54026fce", "06878be2", "1a1907b4", "p3_abs")]
        rows += [{"question_id": "m1", "question_type": "multi-session"}]
        chosen, manifest = preference.select_rows(rows)
        self.assertEqual(set(chosen), {"p1", "p2", "p3_abs"})
        self.assertEqual(list(chosen), sorted(chosen, key=lambda qid: (preference.rank_sha256(qid), qid)))
        self.assertEqual(manifest["population"], 6)
        self.assertFalse(manifest["selection_uses_answers"])
        with self.assertRaises(Exception):
            preference.select_rows([{"question_id": "x", "question_type": "single-session-preference"}])
        self.assertEqual(len(preference.PROJECTION_PINS), 27)
        self.assertFalse(set(preference.PROJECTION_PINS) & set(preference.EXCLUDED_CASE_IDS))
        swift = (SOURCES / "AnswerEvaluationCommand.swift").read_text()
        block = swift.split("preferenceLongMemoryCorpusProjectionSHA256: Set<String> = [", 1)[1].split("]", 1)[0]
        self.assertEqual(set(re.findall(r'"([0-9a-f]{64})"', block)), set(preference.PROJECTION_PINS.values()))

    def test_opaque_projection_has_no_answerability_cue(self):
        case = {"id": "q9_abs", "row": {"haystack_session_ids": ["s-a", "s-b"], "haystack_sessions": [
                    [{"role": "user", "content": "x", "has_answer": True}], [{"role": "assistant", "content": "y"}]],
                    "answer": "ref", "question_type": "single-session-preference", "answer_session_ids": ["s-a"]},
                "events": [{"id": "q9_abs-s0000-m0000", "project_id": "longmemeval-q9_abs", "conversation_key": "session-0000",
                            "role": "user", "status": "complete", "text": "x", "source_time": None},
                           {"id": "q9_abs-s0001-m0000", "project_id": "longmemeval-q9_abs", "conversation_key": "session-0001",
                            "role": "assistant", "status": "complete", "text": "y", "source_time": None}],
                "attempts": [{"project_id": "longmemeval-q9_abs", "conversation_key": "session-0001", "prompt": "Q",
                              "question_time": None}]}
        history = preference.opaque_history(case, 3)
        document = preference.runner_input(history)
        visible = json.dumps({key: value for key, value in document.items() if key != "configuration"})
        self.assertNotIn("q9", visible)
        self.assertNotIn("_abs", visible)
        self.assertNotIn("longmemeval", visible)
        self.assertEqual(document["version"], 9)
        self.assertEqual([attempt["strategy"] for attempt in document["attempts"]], ["hybrid"])
        self.assertEqual(document["configuration"]["maximum_output"], 1024)
        gold = [label["event_id"] for label in history["source_labels"] if label.get("has_answer")]
        self.assertEqual(gold, [document["events"][0]["id"]])

    def test_plan_cohorts_arms_and_generation_cap(self):
        cohorts = plan.cohorts()
        self.assertEqual(list(cohorts), list(plan.COHORT_ORDER))
        self.assertEqual([len(cohorts[name][0]) for name in plan.COHORT_ORDER], [21, 27, 21])
        self.assertEqual([cohorts[name][1] for name in plan.COHORT_ORDER], ["ordinary_send", "ordinary_send", None])
        self.assertEqual({strategy for _, _, strategy, _ in cohorts["retrieval-on-21"][0]}, {"hybrid"})
        self.assertEqual({strategy for _, _, strategy, _ in cohorts["recent-only-21"][0]}, {"recent_only"})
        self.assertEqual(plan.ARMS, (("v4-default", None), ("v5", plan.V5), ("v4-no-g", plan.ABLATION)))
        self.assertEqual(sum(len(cohorts[name][0]) for name in plan.COHORT_ORDER) * len(plan.ARMS), plan.GENERATION_CAP)
        entry = {"attempt": 1, "context_framing": plan.ABLATION, "component_policy": "selected-model-context-components-v1",
                 "retrieval_arm": "ordinary_send"}
        command = replay.runner_command(Path("/b"), Path("/i.json"), Path("/o"), entry)
        self.assertEqual(command[-4:], ["--context-framing", plan.ABLATION, "--retrieval-arm", "ordinary_send"])
        self.assertNotIn("--context-framing", replay.runner_command(Path("/b"), Path("/i.json"), Path("/o"),
                                                                    {**entry, "context_framing": None}))
        self.assertEqual(plan.JUDGE_PLAN["spending_cap_usd"], 2.0)
        self.assertGreater(plan.JUDGE_PLAN["max_generation_requests"], 3 * plan.GENERATION_CAP)
        self.assertTrue(16 <= plan.JUDGE_PLAN["max_output_tokens_per_request"] <= 4096)

    def test_declared_decline_measure(self):
        self.assertEqual(plan.decline_outcome("The quoted sources do not show your budget.")["outcome"], "decline")
        self.assertEqual(plan.decline_outcome("None of the quoted sources states a date.")["outcome"], "decline")
        self.assertEqual(plan.decline_outcome("The excerpts don't mention it.")["outcome"], "decline")
        self.assertEqual(plan.decline_outcome("Try recipes that do not include sugar [E3].")["outcome"], "answer")
        self.assertEqual(plan.decline_outcome("x" * 300 + " the history does not show it")["outcome"], "partial_decline")
        self.assertEqual(plan.decline_outcome("Here are ideas based on your notes [E2].")["outcome"], "answer")

    def test_harness_ranges_score_like_runner_ranges(self):
        history = {"events": [{"id": "g0", "text": "abcd"}, {"id": "o0", "text": "zz"}],
                   "source_labels": [{"event_id": "g0", "has_answer": True}, {"event_id": "o0", "has_answer": False}]}
        sizes = {"g0": 4, "o0": 2}
        whole = plan.delivered_ranges([], [{"event_id": "g0", "offset": 0, "bytes": 4}], sizes)
        recent = plan.delivered_ranges(["g0"], [], sizes)
        part = plan.delivered_ranges([], [{"event_id": "g0", "offset": 1, "bytes": 2}], sizes)
        self.assertEqual(replay.gold_delivery(history, whole)["gold_delivery"], "whole")
        self.assertEqual(replay.gold_delivery(history, recent)["gold_delivery"], "whole")
        self.assertEqual(replay.gold_delivery(history, part)["gold_delivery"], "partial")
        self.assertEqual(replay.gold_delivery(history, [])["gold_delivery"], "none")
        self.assertEqual(replay.ranges_digest(recent), replay.ranges_digest(
            [{"event_id": "g0", "offset": 0, "byte_length": 4, "sha256": "x"}]))

    def rows_for_rule(self, v5_preference="answer", v5_abstention="decline", v5_recent="decline", v5_disclaimer=0):
        rows, index = [], 0
        for arm in ("v4-default", "v5", "v4-no-g"):
            def add(*args, **kwargs):
                nonlocal index
                rows.append(row(*args, index=index, **kwargs)); index += 1
            pref = "decline" if arm != "v5" else v5_preference
            add("preference-27", "p1", arm, outcome=pref, kind="single-session-preference")
            add("preference-27", "p2", arm, outcome="answer", kind="single-session-preference")
            add("preference-27", "p3", arm, outcome="decline", kind="single-session-preference", gold="none")
            add("retrieval-on-21", "54026fce", arm, outcome="decline", kind="single-session-preference")
            add("retrieval-on-21", "a1", arm, outcome="answer")
            add("retrieval-on-21", "x_abs", arm, outcome=v5_abstention if arm == "v5" else "decline", abstention=True,
                gold="no_gold_turns")
            add("recent-only-21", "a1", arm, outcome=v5_recent if arm == "v5" else "decline", gold="none",
                disclaimer=v5_disclaimer if arm == "v5" else 0)
            add("recent-only-21", "54026fce", arm, outcome="answer", gold="none", disclaimer=1)
        return rows

    def test_decision_rule_adopts_only_when_every_criterion_holds(self):
        rows = self.rows_for_rule()
        accept_all = {item["run_index"]: "accept" for item in rows}
        result = plan.decision(rows, accept_all)
        self.assertTrue(result["adopt_v5"])
        self.assertEqual(result["R1_preference_declines_reduced"], {"v4-default": 1, "v5": 0, "questions": 2, "holds": True})
        # 54026fce's decline and disclaimer never count.
        self.assertEqual(result["R4_zero_disclaimers"]["v5"], 0)
        self.assertFalse(plan.decision(rows, None)["adopt_v5"])
        tie = plan.decision(self.rows_for_rule(v5_preference="decline"), accept_all)
        self.assertFalse(tie["R1_preference_declines_reduced"]["holds"])
        self.assertFalse(tie["adopt_v5"])
        self.assertFalse(plan.decision(self.rows_for_rule(v5_abstention="answer"), accept_all)["adopt_v5"])
        self.assertFalse(plan.decision(self.rows_for_rule(v5_recent="answer"), accept_all)["adopt_v5"])
        self.assertFalse(plan.decision(self.rows_for_rule(v5_disclaimer=1), accept_all)["adopt_v5"])
        lower = dict(accept_all)
        v5_a1 = [item["run_index"] for item in rows if item["arm"] == "v5" and item["question_id"] == "a1"
                 and item["cohort"] == "retrieval-on-21"][0]
        lower[v5_a1] = "unknown"
        result = plan.decision(rows, lower)
        self.assertFalse(result["R5_gold_whole_accepts_not_lower"]["holds"])
        self.assertFalse(result["adopt_v5"])
        missing = self.rows_for_rule()
        missing[1] = {**missing[1], "status": "not_run"}
        self.assertFalse(plan.decision(missing, accept_all)["R1_preference_declines_reduced"]["holds"])
        none_to_reduce = [dict(item, outcome="answer") if item["cohort"] == "preference-27" else item for item in rows]
        self.assertFalse(plan.decision(none_to_reduce, accept_all)["R1_preference_declines_reduced"]["holds"])

    def test_verdict_join_is_by_run_index(self):
        rows = [row("retrieval-on-21", "a1", "v4-default", index=0), row("retrieval-on-21", "a1", "v5", index=1)]
        key = {"set_id": "s", "items": [{"item_id": "item-002", "run_index": 1, "question_id": "a1", "arm": "v5"},
                                        {"item_id": "item-001", "run_index": 0, "question_id": "a1", "arm": "v4-default"}]}
        labels = {"set_id": "s", "labels": {"item-001": [{"verdict": "accept"}] * 3,
                                            "item-002": [{"verdict": "accept"}, {"verdict": "reject"}, {"verdict": None}]}}
        joined = plan.verdict_rows(rows, key, labels)
        self.assertEqual([item["verdict"] for item in joined], ["accept", "unknown"])
        with self.assertRaisesRegex(plan.PlanError, "key_row_mismatch"):
            plan.verdict_rows(list(reversed(rows)), key, labels)
        tables = plan.verdict_tables(joined)
        self.assertEqual(tables["retrieval-on-21"]["v5"]["all"]["unknown"], 1)
        self.assertEqual(tables["retrieval-on-21"]["v5"]["all"]["split_votes"], 1)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
