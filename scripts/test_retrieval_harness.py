#!/usr/bin/env python3
"""Synthetic contracts for the P1 retrieval harness scorer and loopback endpoint.

No model files, tokenizer files, datasets or private histories are read.
"""
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import retrieval_harness as harness  # noqa: E402


class ByteTokenizer:
    """Synthetic vocabulary: one token per UTF-8 byte."""

    class Encoding:
        def __init__(self, ids):
            self.ids = ids

    def encode(self, text, add_special_tokens=False):
        return self.Encoding(list(text.encode()))


def case(positives=("a", "b"), sizes=None, abstention=False, question_type="multi-session", question_id="q"):
    return {"question_id": question_id, "question_type": question_type, "abstention": abstention,
            "positives": list(positives), "sizes": sizes or {"a": 100, "b": 50, "c": 10}}


def attempt(recent=(), evidence=(), candidates=(), selection=None):
    return {"preparation_completed": True, "recent_source_ids": list(recent),
            "evidence": [{"event_id": e, "offset": o, "bytes": n, "source_bytes": 0} for e, o, n in evidence],
            "candidates": [{"event_id": e, "rank": r} for e, r in candidates], "selection": selection or {}}


def post(url, path, body):
    request = urllib.request.Request(url.rstrip("/").removesuffix("/v1") + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)


class Contracts(unittest.TestCase):
    def test_whole_delivery_requires_byte_union_to_cover_the_source(self):
        whole, partial = harness.coverage(attempt(evidence=[("a", 0, 60), ("a", 60, 40), ("b", 10, 40)]), case()["sizes"])
        self.assertEqual(whole, {"a"})
        self.assertEqual(partial, {"a", "b"})

    def test_gapped_ranges_are_not_whole(self):
        whole, _ = harness.coverage(attempt(evidence=[("a", 0, 40), ("a", 50, 50)]), case()["sizes"])
        self.assertEqual(whole, set())

    def test_recent_sources_are_delivered_whole(self):
        whole, _ = harness.coverage(attempt(recent=["b"]), case()["sizes"])
        self.assertEqual(whole, {"b"})

    def test_candidates_beyond_declared_depth_do_not_count(self):
        scored = harness.score_attempt(attempt(candidates=[("a", 3), ("b", harness.DECLARED_CANDIDATE_DEPTH)]), case())
        self.assertEqual(scored["candidate"], 1)
        self.assertEqual(scored["whole"], 0)
        self.assertEqual(scored["turns"][0]["candidate_rank"], 3)

    def test_packed_r1_uses_only_the_recorded_candidate_units(self):
        short = lambda identifier: harness.digest(identifier.encode())[:harness.PACKED_CANDIDATE_ID_DIGITS]
        value = attempt(evidence=[("a", 0, 100)], candidates=[("b", 0)])
        value["exchange"] = {"candidate_block_depth": harness.PACKED_CANDIDATE_BLOCK_DEPTH,
                             "candidates": [[0, [[short("x"), "p", "D"], [short("a"), "l", "D"]]],
                                            [1, [[short("a"), "n", "U"], [short("c"), "l", "T"]]]]}
        scored = harness.score_attempt(value, case())
        # "b" is in the assembler trace but not among the recorded units, so it is not an R1 candidate.
        self.assertEqual(scored["candidate"], 1)
        self.assertEqual(scored["turns"][0]["block_rank"], 0)
        self.assertEqual(scored["turns"][0]["unit_kind"], "l")
        self.assertEqual(scored["turns"][0]["block_disposition"], "D")
        self.assertIsNone(scored["turns"][1]["block_rank"])
        self.assertTrue(scored["candidate_list"])
        self.assertEqual(scored["delivered_outside_candidates"], 0)
        # The unit list itself is not copied into the report; the declared depth is.
        self.assertEqual(scored["exchange"], {"candidate_block_depth": harness.PACKED_CANDIDATE_BLOCK_DEPTH})
        value["exchange"]["candidates"] = [[0, []]] * (harness.PACKED_CANDIDATE_BLOCK_DEPTH + 1)
        with self.assertRaises(harness.HarnessError):
            harness.score_attempt(value, case())
        # The wide arm declares 48 blocks; the scorer accepts its depth and refuses an undeclared one.
        value["exchange"]["candidate_block_depth"] = harness.WIDE_CANDIDATE_BLOCK_DEPTH
        value["exchange"]["candidates"] = [[0, []]] * harness.WIDE_CANDIDATE_BLOCK_DEPTH
        self.assertEqual(harness.score_attempt(value, case())["exchange"],
                         {"candidate_block_depth": harness.WIDE_CANDIDATE_BLOCK_DEPTH})
        value["exchange"]["candidates"] = [[0, []]] * (harness.WIDE_CANDIDATE_BLOCK_DEPTH + 1)
        with self.assertRaises(harness.HarnessError):
            harness.score_attempt(value, case())
        value["exchange"].pop("candidate_block_depth")
        with self.assertRaisesRegex(harness.HarnessError, "packed_candidate_depth_undeclared"):
            harness.score_attempt(value, case())
        self.assertIn("exchange_wide", harness.ARMS)
        self.assertEqual(harness.ARMS.index("exchange_wide"), harness.ARMS.index("exchange_packed") + 1)

    def test_failed_preparation_scores_zero_and_keeps_its_reason(self):
        scored = harness.score_attempt({"preparation_completed": False, "failure": "context_overflow"}, case())
        self.assertEqual((scored["failure"], scored["whole"], scored["candidate"]), ("context_overflow", 0, 0))
        self.assertEqual(harness.score_attempt(None, case())["failure"], "missing_attempt")

    def test_feasibility_requires_whole_unreduced_declared_delivery(self):
        sizes = case()["sizes"]
        good = {"attempts": [attempt(evidence=[("a", 0, 100), ("b", 0, 50)])]}
        reduced = {"attempts": [attempt(evidence=[("a", 0, 100), ("b", 0, 50)], selection={"evidenceTokenExcludedCount": 1})]}
        missing = {"attempts": [attempt(evidence=[("a", 0, 100)])]}
        self.assertEqual(harness.feasibility(good, case(sizes=sizes)), "feasible")
        self.assertEqual(harness.feasibility(reduced, case()), "infeasible")
        self.assertEqual(harness.feasibility(missing, case()), "infeasible")
        self.assertEqual(harness.feasibility({"process_failure": "exit_1"}, case()), "control_failed")
        self.assertEqual(harness.feasibility(None, case(abstention=True)), "not_answerable")
        self.assertEqual(harness.feasibility(None, case(positives=())), "not_answerable")

    def test_summary_drops_infeasible_but_keeps_failures_in_denominators(self):
        def row(feasibility, arm_score):
            return {"question_id": "x", "question_type": "temporal-reasoning", "feasibility": feasibility,
                    "arms": {arm: arm_score for arm in harness.ARMS}}
        delivered = harness.score_attempt(attempt(evidence=[("a", 0, 100), ("b", 0, 50)]), case())
        failed = harness.score_attempt(None, case())
        rows = [row("feasible", delivered), row("feasible", failed), row("control_failed", delivered),
                row("infeasible", delivered), row("not_answerable", failed)]
        summary = harness.summarize(rows)
        hybrid = summary["arms"]["hybrid"]
        self.assertEqual(summary["eligible_cases"], 3)
        self.assertEqual(hybrid["r2_delivered_recall"], {"passed": 2, "cases": 3, "fraction": 0.6667})
        self.assertEqual(hybrid["r1_candidate_recall"]["passed"], 2)
        self.assertEqual(hybrid["turn_delivered_whole"], {"passed": 4, "cases": 6, "fraction": 0.6667})
        self.assertEqual(hybrid["failures"], 2)

    def test_endpoint_counts_with_injected_tokenizer_and_refuses_generation(self):
        endpoint = harness.OfflineEndpoint(Path("/nonexistent"), parity_sample=2, tokenizer=ByteTokenizer()).start()
        try:
            self.assertEqual(len(post(endpoint.url, "/tokenize", {"model": harness.MODEL, "content": "héllo"})["tokens"]), 6)
            calibration = post(endpoint.url, "/v1/chat/completions", {"model": harness.MODEL, "stream": False,
                "max_tokens": 1, "enable_thinking": False, "messages": [{"role": "system", "content": "s"},
                                                                        {"role": "user", "content": "u"}]})
            self.assertEqual(calibration["usage"]["completion_tokens"], 1)
            self.assertGreater(calibration["usage"]["prompt_tokens"], 0)
            with self.assertRaises(urllib.error.HTTPError) as refused:
                post(endpoint.url, "/v1/chat/completions", {"model": harness.MODEL, "stream": True, "messages": []})
            self.assertEqual(refused.exception.code, 503)
            self.assertEqual(endpoint.counters["refused_generation"], 1)
            self.assertEqual(endpoint.counters["calibration"], 1)
        finally:
            endpoint.stop()

    def test_endpoint_refuses_an_unpinned_tokenizer_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "tokenizer.json"
            path.write_text("{}")
            with self.assertRaises(harness.HarnessError):
                harness.OfflineEndpoint(path, parity_sample=0)

    def test_parity_sample_is_order_independent(self):
        contents = [f"synthetic-{n}" for n in range(20)]
        samples = []
        for order in (contents, list(reversed(contents))):
            endpoint = harness.OfflineEndpoint(Path("/nonexistent"), parity_sample=4, tokenizer=ByteTokenizer())
            for content in order:
                endpoint.record(content, len(content))
            samples.append(sorted(item[1] for item in endpoint.sample))
            endpoint.server.server_close()
        self.assertEqual(samples[0], samples[1])
        self.assertEqual(samples[0], sorted(harness.digest(c.encode()) for c in contents)[:4])

    def test_cli_failures_print_no_input_material(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                patch.object(harness, "run", side_effect=ValueError("PRIVATE_SENTINEL")), \
                patch.object(sys, "argv", ["retrieval_harness.py", "--cohort", "regression", "--output", "/tmp/unused.json"]):
            self.assertEqual(harness.main(), 1)
        self.assertNotIn("PRIVATE_SENTINEL", out.getvalue() + err.getvalue())

    def test_known_misses_are_reported_individually(self):
        scored = harness.score_attempt(attempt(), case())
        rows = [{"question_id": qid, "question_type": "t", "feasibility": "feasible", "positives": 2,
                 "arms": {arm: scored for arm in harness.ARMS}} for qid in (*harness.KNOWN_MISSES, "other")]
        self.assertEqual(set(harness.known_miss_rows(rows)), set(harness.KNOWN_MISSES))

    def test_exchange_index_parity_compares_delivery_audits_and_labels(self):
        def attempt_with(label, evidence, extra=None):
            return {"preparation_completed": True, "recent_source_ids": ["r1"], "prompt_tokens": 10,
                    "components": {"evidence_tokens": 5}, "evidence": evidence,
                    "exchange": {"index": label, "matched_block_count": 3, **(extra or {})}}
        evidence = [{"event_id": "e1", "offset": 0, "bytes": 4}]
        attempts = {"exchange_adjacent": attempt_with(harness.PERSISTENT_INDEX_LABEL, evidence),
                    "exchange_adjacent_rebuild": attempt_with(harness.REBUILD_INDEX_LABEL, evidence),
                    "exchange_packed": attempt_with(harness.PERSISTENT_INDEX_LABEL, evidence),
                    "exchange_packed_rebuild": attempt_with(harness.REBUILD_INDEX_LABEL,
                        [{"event_id": "e1", "offset": 0, "bytes": 3}], {"matched_block_count": 4})}
        parity = harness.exchange_index_parity(attempts)
        self.assertEqual(parity["exchange_adjacent"], {"evidence": True, "audit": True, "tokens": True, "labels": True,
                                                       "differing_audit_keys": []})
        self.assertEqual(parity["exchange_packed"]["evidence"], False)
        self.assertEqual(parity["exchange_packed"]["differing_audit_keys"], ["matched_block_count"])
        rows = [{"exchange_index_parity": parity}, {"exchange_index_parity": {"exchange_adjacent": None, "exchange_packed": None}}]
        summary = harness.exchange_index_parity_summary(rows)
        self.assertEqual(summary["exchange_adjacent"]["compared"], 1)
        self.assertEqual(summary["exchange_packed"]["evidence"], 0)
        self.assertTrue(set(harness.PARITY_ARMS) <= set(harness.ARMS))

    def test_ordinary_send_equivalence_is_with_the_default_exchange_packed_arm(self):
        def attempt_with(mode, policy, evidence, received=False, extra=None):
            return {"preparation_completed": True, "recent_source_ids": ["r1"], "prompt_tokens": 10,
                    "components": {"evidence_tokens": 5, "policyVersion": policy}, "evidence": evidence,
                    "retrieval": {"mode": mode}, "preparation_received_semantic_index": received,
                    "exchange": {"index": harness.PERSISTENT_INDEX_LABEL, "candidates": [[0, []]], **(extra or {})}}
        evidence = [{"event_id": "e1", "offset": 0, "bytes": 4}]
        packed = attempt_with("exchange_packed", harness.ORDINARY_SEND_POLICY, evidence)
        ordinary = attempt_with("exchange_packed", harness.ORDINARY_SEND_POLICY, evidence)
        # The v1 lexical arm no longer defines ordinary Send.
        lexical = {"preparation_completed": True, "recent_source_ids": ["r1"], "evidence": evidence,
                   "retrieval": {"mode": "lexical", "semantic_retrieval": "disabled_by_policy"}}
        self.assertEqual(harness.ordinary_send_equivalence({"ordinary_send": ordinary, "exchange_packed": packed, "lexical": lexical}),
                         {key: True for key in harness.ORDINARY_SEND_EQUIVALENCE_KEYS})
        self.assertIsNone(harness.ordinary_send_equivalence({"ordinary_send": ordinary, "lexical": lexical}))
        v1 = attempt_with("lexical", "selected-model-context-components-v1", evidence)
        self.assertFalse(harness.ordinary_send_equivalence({"ordinary_send": v1, "exchange_packed": packed})["policy_recorded"])
        received = attempt_with("exchange_packed", harness.ORDINARY_SEND_POLICY, evidence, received=True)
        self.assertFalse(harness.ordinary_send_equivalence({"ordinary_send": received, "exchange_packed": packed})["policy_recorded"])
        reordered = attempt_with("exchange_packed", harness.ORDINARY_SEND_POLICY, evidence + [{"event_id": "e2", "offset": 0, "bytes": 1}])
        other = attempt_with("exchange_packed", harness.ORDINARY_SEND_POLICY, [{"event_id": "e2", "offset": 0, "bytes": 1}] + evidence)
        self.assertFalse(harness.ordinary_send_equivalence({"ordinary_send": reordered, "exchange_packed": other})["delivery"])
        audited = attempt_with("exchange_packed", harness.ORDINARY_SEND_POLICY, evidence, extra={"matched_block_count": 2})
        self.assertFalse(harness.ordinary_send_equivalence({"ordinary_send": audited, "exchange_packed": packed})["candidates"])
        self.assertEqual(harness.ORDINARY_SEND_EQUIVALENT_ARM, "exchange_packed")
        self.assertIn(harness.ORDINARY_SEND_ARM, harness.ARMS)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
