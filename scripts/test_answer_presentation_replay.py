#!/usr/bin/env python3
"""Synthetic contracts for the answer presentation replay driver's offline parts: cohorts, gold
delivery scoring, decline classes and the verdict-only judge set. No private data, network or model calls."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import answer_presentation_replay as replay  # noqa: E402
import judge_calibration as jc  # noqa: E402
import judge_calibration_run as runner  # noqa: E402

TEMPLATES = jc.ROOT / "scripts" / "judge_calibration_declarations"
QUESTION_A, QUESTION_B = "0a1b2c3d", "4e5f6a7b_abs"


def history(gold_sizes=(10,), other_sizes=(7,)):
    """Synthetic history: gold turns g0.. and other turns o0.., text of the given UTF-8 byte sizes."""
    events = [{"id": f"g{index}", "text": "é" * (size // 2) + "x" * (size % 2)} for index, size in enumerate(gold_sizes)]
    events += [{"id": f"o{index}", "text": "y" * size} for index, size in enumerate(other_sizes)]
    labels = [{"event_id": f"g{index}", "has_answer": True, "session_id": "s-gold"} for index in range(len(gold_sizes))]
    labels += [{"event_id": f"o{index}", "has_answer": False, "session_id": "s-other"} for index in range(len(other_sizes))]
    return {"events": events, "source_labels": labels, "episodes": [{"answer_session_ids": ["s-gold"]}]}


def span(event_id, offset, length):
    return {"event_id": event_id, "offset": offset, "byte_length": length, "sha256": "0" * 64}


def fake_prompt(task, question, answer, response, abstention=False):
    return f"UPSTREAM[{task}] Q={question} REF={answer} RESP={response} ABS={abstention}. Answer yes or no only."


class Contracts(unittest.TestCase):
    def test_retrieval_on_cohort_is_the_hybrid_attempt_of_the_same_21_questions(self):
        cohort = replay.COHORTS["retrieval-on-21"]
        recent = replay.COHORTS["recent-only-21"]
        self.assertEqual(cohort["generation_limit"], 42)
        self.assertEqual(len(cohort["cases"]), 21)
        self.assertEqual([(q, run, policy) for q, run, _, policy in cohort["cases"]],
                         [(q, run, policy) for q, run, _, policy in recent["cases"]])
        self.assertEqual({strategy for _, _, strategy, _ in cohort["cases"]}, {"hybrid"})
        self.assertEqual(cohort["arms"], (("v3-pinned", replay.V3), ("v4-default", None)))
        self.assertEqual(set(replay.ARM_DESCRIPTIONS["retrieval-on-21"]), {"v3-pinned", "v4-default"})
        self.assertIn("lexical", replay.RETRIEVAL_SELECTION["retrieval-on-21"])
        self.assertIn("semantic index", replay.RETRIEVAL_SELECTION["retrieval-on-21"])

    def test_retrieval_arm_is_declared_only_for_hybrid_cohorts(self):
        self.assertIsNone(replay.declared_retrieval_arm("retrieval-on-21", None))
        self.assertEqual(replay.declared_retrieval_arm("retrieval-on-21", "ordinary_send"), "ordinary_send")
        for cohort in ("recent-only-21", "echo-7"):
            with self.assertRaisesRegex(replay.ReplayError, "retrieval_arm_requires_hybrid_cohort"):
                replay.declared_retrieval_arm(cohort, "ordinary_send")
        for arm in ("lexical", "hybrid", "ordinary-send"):
            with self.assertRaisesRegex(replay.ReplayError, "unknown_retrieval_arm"):
                replay.declared_retrieval_arm("retrieval-on-21", arm)
        self.assertIn("disabled by policy", replay.RETRIEVAL_ARMS["ordinary_send"])
        self.assertIn("no semantic index built or passed", replay.RETRIEVAL_ARMS["ordinary_send"])

    def test_declare_parser_accepts_only_known_retrieval_arms(self):
        import contextlib
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                replay.main(["declare", "--output", "/unused", "--dataset", "/unused", "--binary", "/unused",
                             "--cohort", "retrieval-on-21", "--retrieval-arm", "lexical"])

    def test_runner_command_passes_the_declared_retrieval_arm(self):
        entry = {"attempt": 1, "context_framing": replay.V3, "component_policy": "selected-model-context-components-v1"}
        base = replay.runner_command(Path("/b/Boros"), Path("/o/inputs/q.json"), Path("/o/run-00"), entry)
        self.assertEqual(base, ["/b/Boros", "--answer-evaluation", "/o/inputs/q.json", "--output-directory", "/o/run-00",
                                "--attempt", "1", "--context-framing", replay.V3])
        lexical = replay.runner_command(Path("/b/Boros"), Path("/o/inputs/q.json"), Path("/o/run-00"),
                                        {**entry, "context_framing": None, "retrieval_arm": "ordinary_send"})
        self.assertEqual(lexical[-2:], ["--retrieval-arm", "ordinary_send"])
        self.assertNotIn("--context-framing", lexical)
        policy = replay.runner_command(Path("/b/Boros"), Path("/i"), Path("/n"),
                                       {**entry, "component_policy": replay.NEIGHBORHOOD_POLICY})
        self.assertEqual(policy[-2:], ["--component-policy", replay.NEIGHBORHOOD_POLICY])
        self.assertNotIn("--retrieval-arm", base + policy)

    def test_retrieval_arm_is_verified_from_the_runner_report(self):
        entry = {"retrieval_arm": "ordinary_send"}
        report = {"retrieval_arm_override": "ordinary_send", "semantic_retrieval_policy": "disabled_by_policy"}
        item = {"retrieval_arm": "ordinary_send", "semantic_retrieval_policy": "disabled_by_policy",
                "preparation_received_semantic_index": False, "semantic_sidecar_present": False,
                "retrieval_arm_receipt_validated": True, "background": {"performed": False}}
        self.assertTrue(replay.retrieval_arm_as_declared(entry, report, item))
        for key, value in (("retrieval_arm", "hybrid"), ("semantic_retrieval_policy", "enabled"),
                           ("preparation_received_semantic_index", True), ("semantic_sidecar_present", True),
                           ("retrieval_arm_receipt_validated", None), ("background", {"performed": True})):
            self.assertFalse(replay.retrieval_arm_as_declared(entry, report, {**item, key: value}), key)
        self.assertFalse(replay.retrieval_arm_as_declared(entry, {}, item))
        # A run declared without an arm must come from a report without one.
        self.assertTrue(replay.retrieval_arm_as_declared({}, {"context_framing": replay.V4}, {"strategy": "hybrid"}))
        self.assertFalse(replay.retrieval_arm_as_declared({}, report, {"strategy": "hybrid"}))
        self.assertFalse(replay.retrieval_arm_as_declared({}, {}, item))

    def test_gold_delivery_matches_harness_coverage(self):
        case = history(gold_sizes=(10, 6))
        self.assertEqual(replay.gold_delivery(case, [span("g0", 0, 10), span("g1", 0, 6)])["gold_delivery"], "whole")
        # Overlapping excerpts that together cover the turn count as whole, as in the harness.
        whole = replay.gold_delivery(case, [span("g0", 0, 6), span("g0", 4, 6), span("g1", 0, 6)])
        self.assertEqual((whole["gold_turns_whole"], whole["gold_delivery"]), (2, "whole"))
        # A gap leaves the turn partial; another gold turn whole keeps the class partial.
        gap = replay.gold_delivery(case, [span("g0", 0, 4), span("g0", 5, 5), span("g1", 0, 6)])
        self.assertEqual((gap["gold_turns_whole"], gap["gold_turns_any_bytes"], gap["gold_delivery"]),
                         (1, 2, "partial"))
        self.assertEqual(replay.gold_delivery(case, [span("g0", 0, 10)])["gold_delivery"], "partial")
        self.assertEqual(replay.gold_delivery(case, [span("g1", 2, 1)])["gold_delivery"], "partial")
        none = replay.gold_delivery(case, [span("o0", 0, 7)])
        self.assertEqual((none["gold_turns"], none["gold_turns_any_bytes"], none["gold_delivery"]), (2, 0, "none"))
        self.assertEqual(replay.gold_delivery(case, [])["gold_delivery"], "none")
        self.assertEqual(replay.gold_delivery(case, None)["gold_delivery"], "none")
        self.assertEqual(replay.gold_delivery(case, [span("g0", 0, 0), span("g1", 0, 0)])["gold_delivery"], "none")
        no_gold = history(gold_sizes=())
        self.assertEqual(replay.gold_delivery(no_gold, [span("o0", 0, 7)])["gold_delivery"], "no_gold_turns")
        # Sizes are UTF-8 bytes, not characters.
        self.assertEqual(replay.gold_delivery(history(gold_sizes=(4,)), [span("g0", 0, 2)])["gold_delivery"], "partial")

    def test_decline_classes(self):
        self.assertEqual(replay.decline_class("decline", False, "whole"), "false_decline")
        self.assertEqual(replay.decline_class("partial_decline", False, "whole"), "false_decline")
        self.assertEqual(replay.decline_class("decline", False, "none"), "justified_decline")
        self.assertEqual(replay.decline_class("decline", False, "partial"), "decline_partial_gold")
        self.assertEqual(replay.decline_class("decline", True, "no_gold_turns"), "abstention_decline")
        self.assertIsNone(replay.decline_class("answer", False, "whole"))

    def test_ranges_digest_is_order_independent_and_content_free(self):
        first = [span("a", 0, 3), span("b", 5, 2)]
        self.assertEqual(replay.ranges_digest(first), replay.ranges_digest(list(reversed(first))))
        self.assertNotEqual(replay.ranges_digest(first), replay.ranges_digest([span("a", 0, 4), span("b", 5, 2)]))
        self.assertEqual(replay.ranges_digest(None), replay.ranges_digest([]))

    def test_majority_of_three(self):
        cases = ((["accept"] * 3, "accept"), (["accept", "accept", "reject"], "accept"),
                 (["reject", None, "reject"], "reject"), (["accept", None, "reject"], "unknown"),
                 (["accept", None, None], "unknown"), ([None, None, None], "unknown"),
                 (["accept", "unknown", "reject"], "unknown"))
        for verdicts, expected in cases:
            self.assertEqual(replay.majority_of_three(verdicts), expected, verdicts)
        with self.assertRaisesRegex(replay.ReplayError, "replicates_not_three"):
            replay.majority_of_three(["accept", "accept"])

    def synthetic_set(self):
        records = {QUESTION_A: {"question": "Synthetic question A?", "question_date": "2023/05/01 (Mon) 10:00",
                                "answer": "Synthetic reference A", "question_type": "single-session-user"},
                   QUESTION_B: {"question": "Synthetic question B?", "question_date": "2023/05/02 (Tue) 10:00",
                                "answer": "Synthetic reference B", "question_type": "temporal-reasoning"}}
        answered = []
        for index, (question_id, arm) in enumerate(((QUESTION_A, "v3-pinned"), (QUESTION_A, "v4-default"),
                                                    (QUESTION_B, "v3-pinned"), (QUESTION_B, "v4-default"))):
            answer = (f"Synthetic answer {index} citing {QUESTION_A}-s0001-m0002, {QUESTION_A}-s0009-m0001 "
                      f"and answer_0a1b2c3d_1" if index == 0 else f"Synthetic answer {index} [E2]")
            events = {"events": [{"id": f"{question_id}-s0001-m0002", "text": "x"}]}
            answered.append((index, {"question_id": question_id, "arm": arm}, events, answer))
        return replay.judge_items("retrieval-on-21", answered, records, "synthetic-seed"), records

    def test_judge_items_are_blinded_calibration_items_without_evidence(self):
        (items, key), _records = self.synthetic_set()
        self.assertEqual(items["format"], jc.ITEMS_FORMAT)
        self.assertTrue(items["set_id"].startswith("jr-"))
        self.assertEqual([item["item_id"] for item in items["items"]], ["item-001", "item-002", "item-003", "item-004"])
        self.assertEqual(jc.blinding_violations(items, key), [])
        for item in items["items"]:
            self.assertEqual(set(item), jc.ITEM_KEYS)
            self.assertEqual(item["evidence"], [])
            for forbidden in (QUESTION_A, QUESTION_B, "_abs", "v3-pinned", "v4-default", "retrieval-on-21",
                              "s0001-m0002", "answer_0a1b2c3d"):
                self.assertNotIn(forbidden, json.dumps(item), forbidden)
        by_index = {entry["run_index"]: entry for entry in key["items"]}
        self.assertEqual(sorted(by_index), [0, 1, 2, 3])
        self.assertEqual({entry["arm"] for entry in key["items"]}, {"v3-pinned", "v4-default"})
        self.assertEqual(by_index[2]["abstention"], True)
        # As in the calibration blinding (longest identifier first): a history event ID becomes
        # [source], and the question ID inside any other identifier becomes [question].
        self.assertEqual(by_index[0]["identifier_substitutions"], 3)
        item_by_id = {item["item_id"]: item for item in items["items"]}
        scrubbed = item_by_id[by_index[0]["item_id"]]
        self.assertEqual((scrubbed["answer"].count("[source]"), scrubbed["answer"].count("[question]")), (1, 2))
        abstention_item = item_by_id[by_index[2]["item_id"]]
        self.assertEqual((abstention_item["abstention"], abstention_item["reference"], abstention_item["question_type"]),
                         (True, "Synthetic reference B", "temporal-reasoning"))
        # Deterministic for a seed; a different seed reorders without changing the item contents.
        again, _ = self.synthetic_set()
        self.assertEqual(again, (items, key))
        with self.assertRaisesRegex(replay.ReplayError, "answer_missing"):
            replay.judge_items("retrieval-on-21", [(0, {"question_id": QUESTION_A, "arm": "v3-pinned"}, history(), None)],
                               _records, "seed")

    def test_judge_set_runs_verdict_only_through_the_unchanged_runner(self):
        (items, key), _records = self.synthetic_set()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / ".build").mkdir()
            destination = root / ".build" / "replay" / "judge-set"
            (root / ".build" / "replay").mkdir()
            manifest = replay.write_judge_set(destination, items, key, "retrieval-on-21", "synthetic-seed")
            for name in ("items.json", "key.json", "manifest.json"):
                self.assertEqual(stat.S_IMODE(os.stat(destination / name).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(destination).st_mode), 0o700)
            with self.assertRaisesRegex(jc.CalibrationError, "destination_exists"):
                replay.write_judge_set(destination, items, key, "retrieval-on-21", "synthetic-seed")
            loaded_manifest, loaded = runner.load_set(destination)
            self.assertEqual((loaded_manifest["item_count"], len(loaded)), (4, 4))
            declaration = json.loads((TEMPLATES / "vertex-sonnet.v3.template.json").read_text())
            declaration["authorization"].update(authorized_by="Synthetic Tester", authorized_on="2026-10-09")
            declaration["calibration_set"] = {"set_id": manifest["set_id"], "items_sha256": manifest["items_sha256"],
                                              "item_count": 4}
            declaration["execution"]["stages_per_item"] = ["verdict"]
            declaration["pricing"].update(input_usd_per_million_tokens="3", output_usd_per_million_tokens="15",
                                          source="synthetic", verified_on="2026-10-09")
            declaration["budget"] = {"spending_cap_usd": "1.00", "max_generation_requests": 12, "max_count_requests": 4}
            declaration["outputs"]["labels_path"] = ".build/replay/labels.json"
            self.assertEqual(jc.check_declaration(declaration, destination), [])
            plan = runner.build_plan(loaded, declaration, fake_prompt)
            self.assertEqual((len(plan), {entry["stage"] for entry in plan}), (12, {"verdict"}))
            for entry in plan:
                rendered = json.dumps(entry["body"])
                self.assertEqual(entry["body"]["system"], jc.REPLY_INSTRUCTIONS["verdict"])
                for forbidden in (QUESTION_A, QUESTION_B, "v3-pinned", "v4-default", "item-0"):
                    self.assertNotIn(forbidden, rendered)

    def test_judge_summary_joins_labels_by_run_index_and_splits_by_gold_delivery(self):
        (items, key), _records = self.synthetic_set()
        rows = [{"question_id": QUESTION_A, "arm": "v3-pinned", "gold_delivery": "whole", "outcome": "answer",
                 "decline_class": None, "contains_reference": True},
                {"question_id": QUESTION_A, "arm": "v4-default", "gold_delivery": "whole", "outcome": "decline",
                 "decline_class": "false_decline", "contains_reference": False},
                {"question_id": QUESTION_B, "arm": "v3-pinned", "gold_delivery": "no_gold_turns", "outcome": "answer",
                 "decline_class": None, "contains_reference": False},
                {"question_id": QUESTION_B, "arm": "v4-default", "gold_delivery": "no_gold_turns",
                 "outcome": "decline", "decline_class": "abstention_decline", "contains_reference": False}]
        by_index = {entry["run_index"]: entry["item_id"] for entry in key["items"]}
        votes = {0: ["accept", "accept", "reject"], 1: ["reject"] * 3, 2: ["accept", None, "reject"], 3: ["accept"] * 3}
        labels = {"set_id": key["set_id"], "labels": {by_index[index]: [{"verdict": value, "sufficiency": None}
                                                                         for value in values]
                                                       for index, values in votes.items()}}
        summary = replay.judge_summary_rows(rows, key, labels)
        self.assertEqual([(row["arm"], row["verdict"]) for row in summary],
                         [("v3-pinned", "accept"), ("v4-default", "reject"), ("v3-pinned", "unknown"),
                          ("v4-default", "accept")])
        tables = replay.judge_tables(summary, ["v3-pinned", "v4-default"])
        self.assertEqual(tables["v3-pinned"]["answerable_gold_whole"], {"answers": 1, "accept": 1, "reject": 0, "unknown": 0})
        self.assertEqual(tables["v4-default"]["false_decline"], {"answers": 1, "accept": 0, "reject": 1, "unknown": 0})
        self.assertEqual(tables["v4-default"]["abstention"], {"answers": 1, "accept": 1, "reject": 0, "unknown": 0})
        self.assertEqual(tables["v3-pinned"]["abstention"]["unknown"], 1)
        self.assertEqual(tables["v3-pinned"]["answerable_gold_not_whole"]["answers"], 0)
        # Missing labels for an item are three unparseable replicates: unknown, never accept.
        partial = {"set_id": key["set_id"], "labels": {by_index[0]: labels["labels"][by_index[0]]}}
        self.assertEqual([row["verdict"] for row in replay.judge_summary_rows(rows, key, partial)],
                         ["accept", "unknown", "unknown", "unknown"])
        with self.assertRaisesRegex(replay.ReplayError, "labels_set_mismatch"):
            replay.judge_summary_rows(rows, key, {"set_id": "other", "labels": {}})
        swapped = [rows[1], rows[0], rows[2], rows[3]]
        with self.assertRaisesRegex(replay.ReplayError, "key_row_mismatch"):
            replay.judge_summary_rows(swapped, key, labels)
        self.assertNotIn("Synthetic", json.dumps(summary))


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
