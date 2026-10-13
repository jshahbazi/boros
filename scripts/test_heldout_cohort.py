#!/usr/bin/env python3
"""Structural contracts for the committed held-out cohort manifest. No network and no dataset
needed; the row-hash check runs only when the pinned dataset is present and passes trivially
otherwise (it never skips)."""
from __future__ import annotations

import io
import json
from pathlib import Path
import re
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import framing_v4_temporal_cases as v4  # noqa: E402
import framing_v5_preference_cases as v5  # noqa: E402
import heldout_cohort as hc  # noqa: E402
import local_longmemeval_qa as qa  # noqa: E402
import longmemeval_independent_cases as independent  # noqa: E402
import native_investigation_hundred_cases as hundred  # noqa: E402

SHA = re.compile(r"[0-9a-f]{64}\Z")
# Dataset fields and generic content keys that must never reach the manifest.
FORBIDDEN_KEYS = frozenset(("question", "answer", "question_date", "answer_session_ids", "haystack_dates",
                            "haystack_session_ids", "haystack_sessions", "sessions", "session", "turns",
                            "content", "text", "prompt", "response", "history", "events"))
EARLIER_COHORTS = {
    "local_longmemeval_qa.CASE_IDS": tuple(qa.CASE_IDS),
    "longmemeval_independent_cases.CASE_IDS": tuple(independent.CASE_IDS),
    "native_investigation_hundred_cases.EARLY_CASE_IDS": tuple(hundred.EARLY_CASE_IDS),
    "framing_v5_preference_cases.PROJECTION_PINS": tuple(v5.PROJECTION_PINS),
    "framing_v4_temporal_cases.PROJECTION_PINS": tuple(v4.PROJECTION_PINS),
}
EXPECTED_SOURCE_COUNTS = {"local_longmemeval_qa.CASE_IDS": 7, "longmemeval_independent_cases.CASE_IDS": 14,
                          "native_investigation_hundred_cases.EARLY_CASE_IDS": 30,
                          "native_investigation_hundred_cases.select_rows": 100,
                          "framing_v5_preference_cases.PROJECTION_PINS": 27,
                          "framing_v4_temporal_cases.PROJECTION_PINS": 25}
DATASET_CHECKED = False


class IdentityOnly(dict):
    """A row that raises when the selector reads anything but identity and type."""

    def get(self, key, default=None):
        if key not in ("question_id", "question_type"):
            raise AssertionError("selector accessed non-identity row data")
        return super().get(key, default)

    def __getitem__(self, key):
        if key not in ("question_id", "question_type"):
            raise AssertionError("selector accessed non-identity row data")
        return super().__getitem__(key)


def keys_in(value):
    if isinstance(value, dict):
        for key, inner in value.items():
            yield key
            yield from keys_in(inner)
    elif isinstance(value, list):
        for inner in value:
            yield from keys_in(inner)


def synthetic_rows():
    """Every identity an earlier cohort pinned, plus a pool of 40 per type and 20 abstentions. The frozen-100
    selection recomputed over these rows takes a proportional share of the pool before this cohort selects."""
    rows, present = [], set()
    # Four preference pins are also early native-investigation cases; each identity appears once.
    for index, qid in enumerate(hundred.EXCLUDED_CASE_IDS):
        rows.append(IdentityOnly(question_id=qid, question_type=hc.QUESTION_TYPES[index % len(hc.QUESTION_TYPES)],
                                 answer="never read"))
        present.add(qid)
    for qid in v5.PROJECTION_PINS:
        if qid not in present:
            rows.append(IdentityOnly(question_id=qid, question_type="single-session-preference", answer="never read"))
            present.add(qid)
    for qid in v4.PROJECTION_PINS:
        if qid not in present:
            rows.append(IdentityOnly(question_id=qid, question_type="temporal-reasoning", answer="never read"))
            present.add(qid)
    for question_type in hc.QUESTION_TYPES:
        for index in range(40):
            rows.append(IdentityOnly(question_id=f"{question_type}-{index:02d}", question_type=question_type,
                                     answer="never read"))
    for index in range(20):
        rows.append(IdentityOnly(question_id=f"synthetic-{index:02d}_abs", question_type=hc.QUESTION_TYPES[index % 6],
                                 answer="never read"))
    assert len({row["question_id"] for row in rows}) == len(rows) and len(rows) > len(present)
    return rows


class Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = hc.load_manifest(hc.MANIFEST_PATH)
        cls.questions = cls.manifest["questions"]
        cls.ids = [item["question_id"] for item in cls.questions]

    def test_version_source_pin_quotas_and_rules_are_declared(self):
        manifest = self.manifest
        self.assertEqual(manifest["version"], "boros-heldout-cohort-v1")
        self.assertEqual(manifest["rank_domain"], "boros-heldout-cohort-v1")
        self.assertEqual(manifest["cohort"], hc.COHORT)
        self.assertEqual(manifest["source"], {"sha256": qa.SOURCE_SHA256, "bytes": qa.SOURCE_BYTES,
                                              "revision": qa.SOURCE_REVISION, "name": qa.SOURCE_NAME, "records": 500})
        self.assertEqual(manifest["usage_rule"], hc.USAGE_RULE)
        self.assertTrue(manifest["usage_rule"].startswith("Held-out. Not for tuning, prompt iteration, "
                                                          "retrieval parameter choice"))
        self.assertIn("docs/DESIGN-REPAIR-PLAN.md P6", manifest["usage_rule"])
        self.assertIn("declared before generation and reported in full", manifest["usage_rule"])
        self.assertEqual(manifest["selection_rule"], hc.SELECTION_RULE)
        self.assertIn("reads question_id and question_type only", manifest["selection_rule"])
        self.assertEqual(manifest["quotas"], {"answerable_per_type": 12, "abstention": 5})
        self.assertEqual(manifest["rank_rule"], hc.RANK_RULE)
        self.assertEqual(manifest["row_hash_rule"], hc.ROW_HASH_RULE)
        for key in ("selection_uses_answers", "selection_uses_positive_labels",
                    "selection_uses_history_or_question_content"):
            self.assertIs(manifest[key], False)

    def test_sixty_five_distinct_questions_fill_the_declared_strata(self):
        manifest = self.manifest
        self.assertEqual(len(self.questions), 65)
        self.assertEqual(len(set(self.ids)), 65)
        self.assertEqual(manifest["declared_questions"], 65)
        self.assertEqual((manifest["answerable_questions"], manifest["abstention_questions"]), (60, 5))
        abstentions = [item for item in self.questions if item["abstention"]]
        self.assertEqual(len(abstentions), 5)
        self.assertTrue(all(item["question_id"].endswith("_abs") for item in abstentions))
        self.assertTrue(all(not item["question_id"].endswith("_abs") for item in self.questions if not item["abstention"]))
        by_stratum = {}
        for item in self.questions:
            by_stratum.setdefault(hc.stratum_of(item["question_id"], item["question_type"]), []).append(item)
        self.assertEqual(sorted(manifest["strata"]), sorted(hc.STRATA))
        for name, entry in manifest["strata"].items():
            self.assertEqual(entry["taken"], len(by_stratum.get(name, [])))
            self.assertEqual(entry["quota"], 5 if name == "abstention" else 12)
            self.assertLessEqual(entry["taken"], min(entry["quota"], entry["available"]))
            self.assertEqual(entry["short"], entry["taken"] < entry["quota"])
            if not entry["short"]:
                self.assertEqual(entry["taken"], entry["quota"])
        for name in ("single-session-user", "single-session-assistant", "multi-session", "knowledge-update",
                     "temporal-reasoning"):
            self.assertEqual(manifest["strata"][name]["taken"], 12)
            self.assertTrue(all(item["question_type"] == name for item in by_stratum[name]))
        # single-session-preference is exhausted by earlier cohorts and the manifest says so.
        self.assertEqual(manifest["strata"]["single-session-preference"],
                         {"quota": 12, "available": 0, "taken": 0, "short": True})
        self.assertEqual(manifest["short_strata"], ["single-session-preference"])
        self.assertEqual(manifest["strata"]["abstention"]["taken"], 5)
        self.assertTrue(all(item["question_type"] in hc.QUESTION_TYPES for item in self.questions))

    def test_no_overlap_with_any_earlier_cohort(self):
        manifest = self.manifest
        selected = set(self.ids)
        excluded = manifest["excluded"]["question_ids"]
        self.assertEqual(excluded, sorted(set(excluded)))
        self.assertEqual(manifest["excluded"]["count"], len(excluded))
        self.assertEqual(manifest["excluded"]["sources"], EXPECTED_SOURCE_COUNTS)
        self.assertEqual(manifest["excluded"]["count"] + manifest["unused_count"], 500)
        self.assertFalse(selected & set(excluded))
        for name, ids in EARLIER_COHORTS.items():
            self.assertFalse(selected & set(ids), name)
            self.assertTrue(set(ids).issubset(excluded), name)
        # The frozen 100 contains the 25 temporal pins and the 51 earlier identities are disjoint from it.
        self.assertGreaterEqual(len(excluded), 7 + 14 + 30 + 100 + 27 - 25)
        self.assertLessEqual(len(excluded), 500 - 65)

    def test_rank_hashes_recompute_from_identities_in_declared_order(self):
        for item in self.questions:
            self.assertEqual(item["rank_sha256"], hc.rank_sha256(item["question_id"]))
            self.assertEqual(item["rank_sha256"],
                             qa.digest(("boros-heldout-cohort-v1\0" + item["question_id"]).encode()))
        position = {name: index for index, name in enumerate(hc.STRATA)}
        keys = [(position[hc.stratum_of(item["question_id"], item["question_type"])], item["rank_sha256"],
                 item["question_id"]) for item in self.questions]
        self.assertEqual(keys, sorted(keys))

    def test_manifest_carries_identities_and_hashes_only(self):
        self.assertFalse(set(keys_in(self.manifest)) & FORBIDDEN_KEYS)
        for item in self.questions:
            self.assertEqual(sorted(item), sorted(hc.QUESTION_KEYS))
            self.assertRegex(item["row_sha256"], SHA)
            self.assertRegex(item["rank_sha256"], SHA)
            self.assertRegex(item["question_id"], r"\A[A-Za-z0-9_]{1,32}\Z")
            self.assertIs(item["abstention"], item["question_id"].endswith("_abs"))
        for qid in self.manifest["excluded"]["question_ids"]:
            self.assertRegex(qid, r"\A[A-Za-z0-9_]{1,32}\Z")
        report = hc.summary(self.manifest)
        self.assertFalse(set(keys_in(report)) & {"question_ids", "questions"})
        self.assertRegex(report["manifest_sha256"], SHA)
        self.assertEqual(report["manifest_sha256"], qa.digest(hc.MANIFEST_PATH.read_bytes()))
        self.assertEqual(hc.render(self.manifest), hc.MANIFEST_PATH.read_bytes())

    def test_selection_reads_identity_and_type_only_and_is_deterministic(self):
        rows = synthetic_rows()
        first = hc.select_rows(rows)
        self.assertEqual(first, hc.select_rows(list(reversed(rows))))
        chosen = [item["question_id"] for item in first["questions"]]
        self.assertEqual(len(chosen), len(set(chosen)))
        self.assertFalse(set(chosen) & set(first["excluded"]["question_ids"]))
        for name, ids in EARLIER_COHORTS.items():
            self.assertTrue(set(ids).issubset(first["excluded"]["question_ids"]), name)
        self.assertEqual(first["excluded"]["sources"]["native_investigation_hundred_cases.select_rows"], 100)
        self.assertEqual(first["unused_count"], len(rows) - first["excluded"]["count"])
        strata = first["strata"]
        self.assertEqual(strata["abstention"]["taken"], 5)
        self.assertTrue(all(item["question_id"].endswith("_abs") == item["abstention"] for item in first["questions"]))
        for name in hc.QUESTION_TYPES:
            self.assertEqual(strata[name]["taken"], min(12, strata[name]["available"]))
            self.assertEqual(strata[name]["short"], strata[name]["available"] < 12)
        # A declared exclusion list is honoured and a short stratum is recorded, not padded.
        pool = [IdentityOnly(question_id=f"k-{index}", question_type="knowledge-update") for index in range(3)]
        pool += [IdentityOnly(question_id=f"m-{index}", question_type="multi-session") for index in range(14)]
        pool += [IdentityOnly(question_id=f"a-{index}_abs", question_type="multi-session") for index in range(2)]
        short = hc.select_rows(pool, excluded=("k-0", "m-0"))
        self.assertEqual(short["strata"]["knowledge-update"], {"quota": 12, "available": 2, "taken": 2, "short": True})
        self.assertEqual(short["strata"]["multi-session"], {"quota": 12, "available": 13, "taken": 12, "short": False})
        self.assertEqual(short["strata"]["abstention"], {"quota": 5, "available": 2, "taken": 2, "short": True})
        self.assertEqual(short["short_strata"], ["knowledge-update", "single-session-assistant",
                                                 "single-session-preference", "single-session-user",
                                                 "temporal-reasoning", "abstention"])
        self.assertNotIn("k-0", [item["question_id"] for item in short["questions"]])
        with self.assertRaisesRegex(hc.HeldoutError, "heldout_excluded_identity_missing"):
            hc.select_rows(pool, excluded=("absent",))
        with self.assertRaisesRegex(hc.HeldoutError, "heldout_identity_invalid"):
            hc.select_rows([{"question_id": "x", "question_type": "unknown"}], excluded=())

    def test_row_hashes_recompute_when_the_pinned_dataset_is_present(self):
        global DATASET_CHECKED
        source = hc.source_path()
        if not source.is_file():
            self.assertFalse(source.is_file())
            return
        rows = hc.load_rows(source)
        by_id = {row["question_id"]: row for row in rows}
        for item in self.questions:
            row = by_id[item["question_id"]]
            self.assertEqual(item["question_type"], row["question_type"])
            self.assertEqual(item["row_sha256"], qa.digest(qa.canonical(row)))
        self.assertEqual(hc.render(hc.manifest_for(rows)), hc.MANIFEST_PATH.read_bytes())
        DATASET_CHECKED = True


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped),
        "dataset_rows_verified": DATASET_CHECKED}))
    raise SystemExit(not result.wasSuccessful())
