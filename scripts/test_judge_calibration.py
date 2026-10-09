#!/usr/bin/env python3
"""Synthetic contracts for the P4 judge calibration tool. No private data, network or model calls."""
from __future__ import annotations

import copy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import judge_calibration as jc  # noqa: E402


def candidate(run, question_id, arm, stratum_hint, *, model=jc.QWEN_MODEL, answer="Synthetic answer.",
              labels=None, abstention=False, delivered=True, cpu=False, question_type="multi-session"):
    c = jc.new_candidate(run=run, run_family="synthetic", arm=arm, question_id=question_id,
                         question_type=question_type, abstention=abstention, answer_model=model,
                         operational_complete=True, answer_sha256=hashlib.sha256(answer.encode()).hexdigest())
    c.update(answer_text=answer, answer_verified=True, question="Synthetic question?", question_date="2023/05/01",
             reference="Synthetic reference.", reference_check=True,
             evidence=[{"source_id": f"{question_id}-s0001-m0002", "order": (1, 2), "date": "2023/04/01",
                        "role": "user", "text": "Synthetic evidence.", "partial": False}],
             evidence_retention="text", evidence_verified=True,
             all_annotated_delivered=None if abstention else delivered, correct_plus_unsupported=cpu,
             prior_labels=labels or {})
    c["scrub_ids"].update({question_id, f"{question_id}-s0001-m0002"})
    c["eligible"] = jc.eligibility(c) is None
    c["stratum"] = jc.stratum_of(c)
    del stratum_hint
    return c


def pool(size_per=6, questions=40):
    out = []
    for index in range(questions):
        q = f"{index:08x}"
        out.append(candidate("run-a", q, "hybrid", None, labels={"qwen-local-qa": {"verdict": "accept"}}))
        out.append(candidate("run-b", q, "recent_only", None, delivered=False,
                             labels={"qwen-local-qa": {"verdict": "reject"}}, answer=f"other {index}"))
    for index in range(size_per):
        q = f"{index:08x}_abs"
        out.append(candidate("run-c", q, "hybrid", None, abstention=True, answer=f"abs {index}"))
        q2 = f"{index + 100:08x}"
        out.append(candidate("run-d", q2, "hybrid", None, labels={"jevk5-mcp-qa": {"verdict": "reject"}},
                             answer=f"rej {index}"))
        out.append(candidate("run-e", q2, "inspection", None, model=jc.SOL_MODEL, cpu=True,
                             labels={"sol-qa": {"verdict": "accept"}}, answer=f"cpu {index}"))
    return out


class Contracts(unittest.TestCase):
    def test_strata_precedence(self):
        self.assertEqual(candidate("r", "q1_abs", "a", None, abstention=True, cpu=True)["stratum"], "abstention")
        self.assertEqual(candidate("r", "q2", "a", None, cpu=True, delivered=False)["stratum"],
                         "correct_plus_unsupported")
        self.assertEqual(candidate("r", "q3", "a", None, delivered=False,
                                   labels={"x": {"verdict": "accept"}})["stratum"], "incomplete_evidence")
        self.assertEqual(candidate("r", "q4", "a", None, labels={"x": {"verdict": "reject"},
                                                                  "y": {"verdict": "accept"}})["stratum"], "accepted")
        self.assertEqual(candidate("r", "q5", "a", None, labels={"x": {"verdict": "reject"}})["stratum"], "rejected")
        self.assertEqual(candidate("r", "q6", "a", None)["stratum"], "unlabeled")

    def test_selection_is_deterministic_and_order_independent(self):
        items = pool()
        first, shortfalls, _ = jc.select(items, "seed-1")
        again, _, _ = jc.select(list(reversed(items)), "seed-1")
        other, _, _ = jc.select(items, "seed-2")
        keys = [entry["candidate"]["key"] for entry in first]
        self.assertEqual(keys, [entry["candidate"]["key"] for entry in again])
        self.assertNotEqual(keys, [entry["candidate"]["key"] for entry in other])
        self.assertEqual(len(keys), 50)
        self.assertEqual(shortfalls, {"correct_plus_unsupported": 4, "abstention": 4, "rejected": 4})
        with self.assertRaises(jc.CalibrationError):
            jc.select(items, "")

    def test_selection_is_blind_to_answer_text_and_label_values(self):
        items = pool()
        changed = copy.deepcopy(items)
        for c in changed:
            c["answer_text"] = c["answer_text"][::-1] + " changed"
            for label in c["prior_labels"].values():
                label["confidence"] = 0.123
        a = [e["candidate"]["key"] for e in jc.select(items, "s")[0]]
        b = [e["candidate"]["key"] for e in jc.select(changed, "s")[0]]
        self.assertEqual(a, b)

    def test_stratum_counts_cap_and_fill(self):
        chosen, shortfalls, available = jc.select(pool(), "seed", per_stratum=10, minimum=50, max_per_question=2)
        counts = {}
        for entry in chosen:
            counts[entry["stratum"]] = counts.get(entry["stratum"], 0) + 1
        self.assertEqual(available["abstention"], 6)
        self.assertEqual(counts["abstention"], 6)
        self.assertEqual(counts["correct_plus_unsupported"], 6)
        self.assertEqual(counts["accepted"] + counts["incomplete_evidence"], 50 - 6 - 6 - counts["rejected"])
        self.assertTrue(all(not e["fill"] for e in chosen if e["stratum"] in ("abstention",)))
        per_question = {}
        for entry in chosen:
            q = entry["candidate"]["question_id"]
            per_question[q] = per_question.get(q, 0) + 1
        self.assertLessEqual(max(per_question.values()), 2)
        capped, _, _ = jc.select(pool(), "seed", max_per_question=1)
        self.assertEqual(len({e["candidate"]["question_id"] for e in capped}), len(capped))
        small, short, _ = jc.select(pool(questions=2, size_per=1), "seed", minimum=50)
        self.assertLess(len(small), 50)
        self.assertIn("accepted", short)

    def test_duplicate_answers_are_selected_once(self):
        a = candidate("run-a", "00000001", "hybrid", None, labels={"q": {"verdict": "accept"}}, answer="same")
        b = candidate("run-b", "00000001", "hybrid", None, labels={"q": {"verdict": "accept"}}, answer="same")
        chosen, _, available = jc.select([a, b], "s", minimum=5)
        self.assertEqual(len(chosen), 1)
        self.assertEqual(available["accepted"], 1)

    def test_blinding_removes_identity_and_identifiers(self):
        leaky = ("Per q0000001_abs-s0001-m0002 and gpt4_1234abcd-s0003-m0004, session answer_deadbeef_1, "
                 "event " + "a" * 64 + ", the question q0000001_abs is unanswerable.")
        c = candidate("orientation-zoom-v1", "q0000001_abs", "orientation_inspection", None, model=jc.SOL_MODEL,
                      answer=leaky, abstention=True, labels={"sol-qa": {"verdict": "accept"},
                                                             "jevk5-mcp-qa": {"verdict": "reject"}})
        with tempfile.TemporaryDirectory() as directory:
            manifest = jc.assemble([c] + pool(questions=3, size_per=1), "seed", Path(directory) / "set",
                                   per_stratum=2, minimum=5)
            raw = (Path(directory) / "set" / "items.json").read_text()
            items = json.loads(raw)
            key = json.loads((Path(directory) / "set" / "key.json").read_text())
            form = (Path(directory) / "set" / "adjudication-form.html").read_text()
        for forbidden in ("q0000001", "_abs", "answer_deadbeef", "a" * 64, "gpt4_1234abcd", "gpt-6.1-sol", "Qwen3.8",
                          "orientation", "inspection", "hybrid", "recent_only", "sol-qa", "jevk5", "qwen-local",
                          "verdict\": \"accept", "stratum", "prior_labels", "run-a", "answer_model"):
            self.assertNotIn(forbidden, raw, forbidden)
        self.assertNotIn("Qwen3.8", form)
        self.assertNotIn("prior_labels", form)
        for item in items["items"]:
            self.assertEqual(set(item), jc.ITEM_KEYS)
            self.assertRegex(item["item_id"], r"\Aitem-\d{3}\Z")
            self.assertTrue(all(re.fullmatch(r"E\d+", e["label"]) for e in item["evidence"]))
        leaked_item = next(i for i in items["items"] if "E1" in i["answer"])
        self.assertIn("[source]", leaked_item["answer"])
        self.assertIn("[session]", leaked_item["answer"])
        self.assertTrue(any(entry["prior_labels"] for entry in key["items"]))
        self.assertEqual(manifest["item_count"], len(items["items"]))
        self.assertEqual(manifest["items_sha256"], hashlib.sha256(raw.encode()).hexdigest())

    def test_violation_detector_catches_leaks(self):
        c = candidate("r", "q0000009", "hybrid", None, labels={"x": {"verdict": "accept"}})
        item, _ = jc.blind_item(c, "item-001")
        key = {"items": [{"item_id": "item-001", "question_id": "q0000009", "run": "r", "arm": "hybrid"}]}
        document = {"format": jc.ITEMS_FORMAT, "set_id": "jc-x", "items": [item]}
        self.assertEqual(jc.blinding_violations(document, key), [])
        for mutate, code in ((lambda i: i.update(answer="see q0000009"), "question_id_leak"),
                             (lambda i: i.update(answer="x_abs"), "abstention_cue_leak"),
                             (lambda i: i.update(model="qwen"), "item_keys"),
                             (lambda i: i.update(question_type="hybrid"), "structural_identity"),
                             (lambda i: i.update(item_id="q0000009"), "item_id_not_opaque")):
            bad = copy.deepcopy(item)
            mutate(bad)
            codes = [v[1] for v in jc.blinding_violations({**document, "items": [bad]}, key)]
            self.assertIn(code, codes)

    def test_private_files_and_self_contained_form(self):
        c = candidate("r", "q0000010", "hybrid", None, labels={"x": {"verdict": "accept"}},
                      answer="</script><script>fetch('https://example.invalid')</script>")
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "set"
            jc.assemble([c], "seed", out, per_stratum=1, minimum=1)
            self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o700)
            for name in ("items.json", "key.json", "manifest.json", "adjudication-form.html"):
                self.assertEqual(stat.S_IMODE(os.stat(out / name).st_mode), 0o600, name)
            form = (out / "adjudication-form.html").read_text()
            with self.assertRaises(jc.CalibrationError):
                jc.assemble([c], "seed", out, per_stratum=1, minimum=1)
        self.assertIn("Content-Security-Policy", form)
        self.assertIn("connect-src 'none'", form)
        self.assertEqual(form.count("</script>"), 2)
        self.assertNotRegex(form, r"<script[^>]+src=")
        self.assertNotRegex(form, r"<link[^>]+href=")
        self.assertNotIn("https://example.invalid')</script>", form)

    def test_private_destination_must_be_under_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".build").mkdir()
            self.assertEqual(jc.check_private_destination(root / ".build" / "x", root, require_git_ignore=False),
                             (root / ".build" / "x").resolve())
            with self.assertRaises(jc.CalibrationError):
                jc.check_private_destination(root / "docs" / "x", root, require_git_ignore=False)
        self.assertEqual(jc.check_private_destination(jc.ROOT / ".build" / "judge-calibration" / "probe"),
                         (jc.ROOT / ".build" / "judge-calibration" / "probe").resolve())

    def test_wilson_interval_values(self):
        self.assertIsNone(jc.wilson(0, 0))
        low, high = jc.wilson(5, 10)
        self.assertAlmostEqual(low, 0.236593, places=5)
        self.assertAlmostEqual(high, 0.763407, places=5)
        low, high = jc.wilson(0, 10)
        self.assertEqual(low, 0.0)
        self.assertAlmostEqual(high, 0.277533, places=5)
        low, high = jc.wilson(25, 50)
        self.assertAlmostEqual(high - 0.5, 0.1336, places=3)
        self.assertAlmostEqual(jc.wilson(10, 10)[1], 1.0)
        with self.assertRaises(jc.CalibrationError):
            jc.wilson(11, 10)

    def test_kappa_and_majority(self):
        self.assertAlmostEqual(jc.cohen_kappa([("a", "a"), ("b", "b"), ("a", "b"), ("b", "a")]), 0.0)
        self.assertAlmostEqual(jc.cohen_kappa([("a", "a"), ("b", "b")]), 1.0)
        self.assertEqual(jc.majority(["accept", "accept", "reject"]), ("accept", 2 / 3))
        self.assertEqual(jc.majority(["accept", "reject"])[0], "unknown")
        self.assertEqual(jc.majority([None]), (None, None))

    def _scored_set(self, directory, decisions, prior=None):
        items = []
        for index in range(8):
            c = candidate("r", f"{index:08x}", "hybrid", None,
                          labels=prior[index] if prior else {"qwen-local-qa": {"verdict": "accept"}},
                          model=jc.QWEN_MODEL if index < 4 else jc.SOL_MODEL, answer=f"a{index}",
                          question_type="temporal-reasoning" if index % 2 else "multi-session")
            items.append(c)
        out = Path(directory) / "set"
        manifest = jc.assemble(items, "seed", out, per_stratum=8, minimum=8)
        key = json.loads((out / "key.json").read_text())
        by_question = {entry["question_id"]: entry["item_id"] for entry in key["items"]}
        adjudications = {"format": jc.ADJUDICATION_FORMAT, "set_id": manifest["set_id"],
                         "items_sha256": manifest["items_sha256"],
                         "decisions": {by_question[f"{i:08x}"]: d for i, d in enumerate(decisions)}}
        path = Path(directory) / "adjudications.json"
        path.write_text(json.dumps(adjudications))
        return out, path, manifest, by_question

    def test_scoring_rates_and_variants(self):
        decisions = [{"verdict": "accept", "sufficiency": "sufficient"}] * 3 + [
            {"verdict": "reject", "sufficiency": "insufficient", "unsupported_claims": True},
            {"verdict": "reject", "sufficiency": "insufficient"},
            {"verdict": "reject", "sufficiency": "sufficient"},
            {"verdict": "unsure", "sufficiency": "unsure"},
            {"verdict": "accept", "sufficiency": "sufficient"}]
        with tempfile.TemporaryDirectory() as directory:
            out, path, manifest, ids = self._scored_set(directory, decisions)
            labels = {"format": jc.LABELS_FORMAT, "set_id": manifest["set_id"], "judge": "vertex-opus",
                      "labels": {ids[f"{i:08x}"]: v for i, v in enumerate([
                          {"verdict": "accept", "sufficiency": "sufficient"},
                          {"verdict": "reject", "sufficiency": "sufficient"},
                          [{"verdict": "accept"}, {"verdict": "accept"}, {"verdict": "reject"}],
                          {"verdict": "accept", "sufficiency": "insufficient"},
                          {"verdict": "accept", "sufficiency": "sufficient"},
                          {"verdict": "reject", "sufficiency": "sufficient"},
                          {"verdict": "accept"},
                          {"verdict": "unknown"}])}}
            label_path = Path(directory) / "labels.json"
            label_path.write_text(json.dumps(labels))
            result = jc.score(out, path, [("vertex-opus", str(label_path))])
        columns = {entry["judge"]: entry for entry in result["candidate_judges"]}
        self.assertEqual(set(columns), set(jc.CANDIDATE_JUDGES))
        self.assertEqual(columns["vertex-sonnet"]["status"], "no labels supplied")
        self.assertEqual(columns["jev-hosted"]["status"], "no labels supplied")
        opus = columns["vertex-opus"]
        grounded = opus["grounded"]["overall"]
        # compared: items 0-5 (6 unsure excluded, 7 judge unknown)
        self.assertEqual(grounded["compared"], 6)
        self.assertEqual(grounded["adjudicated_accept"], 3)
        self.assertEqual(grounded["adjudicated_reject"], 3)
        self.assertEqual(grounded["false_reject"]["count"], 1)
        self.assertEqual(grounded["false_accept"]["count"], 2)
        self.assertEqual(grounded["false_accept"]["wilson95"], jc.wilson(2, 3))
        reference = opus["reference_only"]["overall"]
        self.assertEqual(reference["adjudicated_accept"], 4)
        self.assertEqual(reference["false_accept"]["count"], 1)
        self.assertEqual(opus["judge_unknown_labels"], 1)
        self.assertAlmostEqual(opus["replicate_verdict_agreement_mean"], 2 / 3)
        self.assertEqual(opus["sufficiency_agreement"]["of"], 5)
        self.assertEqual(opus["sufficiency_agreement"]["count"], 4)
        self.assertEqual(opus["self_preference"]["same_model_items"], 0)
        self.assertFalse(opus["self_preference"]["testable"])
        self.assertIn("multi-session", opus["grounded"]["by_category"])
        prior = {entry["judge"]: entry for entry in result["historical_labels"]}
        self.assertEqual(prior["qwen-local-qa"]["self_preference"]["same_model_items"], 4)
        self.assertTrue(prior["qwen-local-qa"]["self_preference"]["testable"])
        self.assertTrue(prior["qwen-local-qa"]["historical"])

    def test_score_refuses_mismatched_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            out, path, manifest, _ = self._scored_set(directory, [{"verdict": "accept"}] * 8)
            bad = json.loads(path.read_text())
            bad["items_sha256"] = "0" * 64
            path.write_text(json.dumps(bad))
            with self.assertRaises(jc.CalibrationError):
                jc.score(out, path)
            bad["items_sha256"] = manifest["items_sha256"]
            bad["decisions"] = {"item-001": {"verdict": "maybe"}}
            path.write_text(json.dumps(bad))
            with self.assertRaises(jc.CalibrationError):
                jc.score(out, path)

    def _revision_pair(self, directory):
        """Synthetic v1 export and a v2 revision of it that lists every change."""
        original_decisions = [{"verdict": "accept", "sufficiency": "sufficient", "unsupported_claims": False,
                               "note": f"synthetic note {i}", "sufficiency_at_reveal": "sufficient",
                               "revealed": True} for i in range(8)]
        out, original_path, manifest, ids = self._scored_set(directory, original_decisions)
        original = json.loads(original_path.read_text())
        original["format"] = jc.ADJUDICATION_FORMAT_V1
        original_path.write_text(json.dumps(original))
        revised = copy.deepcopy(original)
        revised.update(format=jc.ADJUDICATION_FORMAT, adjudicator="synthetic adjudicator")
        for decision in revised["decisions"].values():
            decision["faithful"] = None
        first, second = ids["00000000"], ids["00000005"]
        revised["decisions"][first].update(verdict="reject", faithful="yes")
        revised["decisions"][second].update(verdict="reject", sufficiency="insufficient", faithful="yes")
        revised["revision"] = {
            "of_export_sha256": hashlib.sha256(original_path.read_bytes()).hexdigest(),
            "revised_on": "2026-10-09", "authorized_by": "synthetic", "applied_by": "synthetic",
            "rubric": "synthetic rubric", "faithful_coverage": "synthetic coverage",
            "changes": [{"item": first, "verdict": "accept->reject", "faithful": "yes", "reason": "synthetic"},
                        {"item": second, "verdict": "accept->reject", "sufficiency": "sufficient->insufficient",
                         "faithful": "yes", "reason": "synthetic"}]}
        revised_path = Path(directory) / "adjudications-v2.json"
        revised_path.write_text(json.dumps(revised))
        return out, original_path, revised_path, revised, manifest, ids

    def test_adjudication_formats_v1_and_v2(self):
        with tempfile.TemporaryDirectory() as directory:
            out, path, manifest, ids = self._scored_set(directory, [{"verdict": "accept"}] * 8)
            base = json.loads(path.read_text())
            for form, faithful, code in (
                    (jc.ADJUDICATION_FORMAT_V1, None, None),
                    (jc.ADJUDICATION_FORMAT, None, None),
                    (jc.ADJUDICATION_FORMAT, "yes", None),
                    (jc.ADJUDICATION_FORMAT, "unsure", None),
                    (jc.ADJUDICATION_FORMAT, "maybe", "adjudication_faithful_invalid"),
                    (jc.ADJUDICATION_FORMAT, True, "adjudication_faithful_invalid"),
                    (jc.ADJUDICATION_FORMAT_V1, "yes", "adjudication_faithful_requires_v2"),
                    ("boros-judge-calibration-adjudications-v3", None, "adjudication_format")):
                document = copy.deepcopy(base)
                document["format"] = form
                if faithful is not None or form == jc.ADJUDICATION_FORMAT:
                    document["decisions"][ids["00000001"]]["faithful"] = faithful
                path.write_text(json.dumps(document))
                if code is None:
                    loaded = jc.read_adjudications(path, manifest)
                    self.assertEqual(loaded["format"], form)
                    self.assertIsNone(loaded["revision"])
                    self.assertEqual(len(loaded["decisions"]), 8)
                else:
                    with self.assertRaisesRegex(jc.CalibrationError, f"^{code}$"):
                        jc.read_adjudications(path, manifest)
            v1 = dict(copy.deepcopy(base), format=jc.ADJUDICATION_FORMAT_V1, revision={})
            path.write_text(json.dumps(v1))
            with self.assertRaisesRegex(jc.CalibrationError, "^adjudication_revision_requires_v2$"):
                jc.read_adjudications(path, manifest)
            self.assertIn(jc.ADJUDICATION_FORMAT_V1, jc.ADJUDICATION_FORMATS)
            self.assertTrue(jc.ADJUDICATION_FORMAT.endswith("-v2"))

    def test_revision_consistency_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            out, original_path, revised_path, revised, manifest, ids = self._revision_pair(directory)
            loaded = jc.read_adjudications(revised_path, manifest, original_path)
            self.assertTrue(loaded["revision"]["original_verified"])
            self.assertEqual(loaded["revision"]["changed_items"], 2)
            self.assertEqual(loaded["revision"]["changes_by_field"], {"verdict": 2, "faithful": 2, "sufficiency": 1})
            self.assertFalse(jc.read_adjudications(revised_path, manifest)["revision"]["original_verified"])
            first, other = ids["00000000"], ids["00000003"]

            def expect(code, mutate, *, with_original=True):
                document = copy.deepcopy(revised)
                mutate(document)
                revised_path.write_text(json.dumps(document))
                with self.assertRaisesRegex(jc.CalibrationError, f"^{code}$"):
                    jc.read_adjudications(revised_path, manifest, original_path if with_original else None)

            expect("adjudication_revision_original_hash",
                   lambda d: d["revision"].update(of_export_sha256="0" * 64))
            # A verdict changed on an item the revision does not list.
            expect("adjudication_revision_unlisted_change",
                   lambda d: d["decisions"][other].update(verdict="reject"))
            # A note edited without being listed, and a form-history field changed.
            expect("adjudication_revision_unlisted_change",
                   lambda d: d["decisions"][other].update(note="edited"))
            expect("adjudication_revision_unlisted_change",
                   lambda d: d["decisions"][other].update(revealed=False))
            # Faithful set on an item without a listed change.
            expect("adjudication_revision_unlisted_change",
                   lambda d: d["decisions"][other].update(faithful="no"))
            # The listed target differs from the revised file (detectable without the original).
            expect("adjudication_revision_target_mismatch",
                   lambda d: d["revision"]["changes"][0].update(faithful="no"), with_original=False)
            # The listed source differs from the original.
            expect("adjudication_revision_source_mismatch",
                   lambda d: d["revision"]["changes"][0].update(verdict="unsure->reject"))
            # A listed change that did not happen.
            expect("adjudication_revision_listed_change_absent",
                   lambda d: d["revision"]["changes"][0].update(unsupported_claims="true->false"))
            expect("adjudication_revision_listed_change_absent",
                   lambda d: d["revision"]["changes"][0].update(note="changed"))
            expect("adjudication_revision_unknown_item",
                   lambda d: d["revision"]["changes"].append({"item": "item-999", "verdict": "accept->reject"}))
            expect("adjudication_revision_duplicate_item",
                   lambda d: d["revision"]["changes"].append(dict(d["revision"]["changes"][0])))
            for bad in ("accept=>reject", "accept->accept", "accept->maybe", "a->b->c", ""):
                expect("adjudication_revision_change_invalid",
                       lambda d, bad=bad: d["revision"]["changes"][0].update(verdict=bad), with_original=False)
            expect("adjudication_revision_change_invalid",
                   lambda d: d["revision"]["changes"][0].update(revealed="true->false"), with_original=False)
            expect("adjudication_revision_invalid", lambda d: d["revision"].update(changes=[]))
            expect("adjudication_revision_invalid", lambda d: d["revision"].update(revised_on="October 9"))
            expect("adjudication_revision_invalid", lambda d: d["revision"].pop("authorized_by"))
            expect("adjudication_revision_missing", lambda d: d.pop("revision"))
            # A listed note change is accepted when the note did change; its text is never compared.
            document = copy.deepcopy(revised)
            document["decisions"][first]["note"] = "edited synthetic note"
            document["revision"]["changes"][0]["note"] = "changed"
            revised_path.write_text(json.dumps(document))
            self.assertEqual(jc.read_adjudications(revised_path, manifest, original_path)["revision"]
                             ["changes_by_field"]["note"], 1)
            # The CLI refuses an inconsistent file with exit 1 and the fixed code only.
            document["decisions"][other]["verdict"] = "reject"
            revised_path.write_text(json.dumps(document))
            stdout = io.StringIO()
            with unittest.mock.patch("sys.stdout", stdout):
                code = jc.main(["score", "--set", str(out), "--adjudications", str(revised_path),
                                "--original-adjudications", str(original_path), "--no-prior"])
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(stdout.getvalue()), {"error": "adjudication_revision_unlisted_change"})

    def test_faithful_reporting_stays_out_of_error_rates(self):
        with tempfile.TemporaryDirectory() as directory:
            out, original_path, revised_path, revised, manifest, ids = self._revision_pair(directory)
            labels = {"format": jc.LABELS_FORMAT, "set_id": manifest["set_id"], "judge": "vertex-opus",
                      "labels": {item: {"verdict": "accept"} for item in ids.values()}}
            label_path = Path(directory) / "labels.json"
            label_path.write_text(json.dumps(labels))
            result = jc.score(out, revised_path, [("vertex-opus", str(label_path))],
                              original_adjudications=original_path)
            summary = result["adjudication"]
            self.assertEqual(summary["format"], jc.ADJUDICATION_FORMAT)
            self.assertEqual(summary["faithful_adjudicated"], 2)
            self.assertEqual(summary["faithful"], {"yes": 2, "not_adjudicated": 6})
            self.assertEqual(summary["faithful_set_by_revision"], 2)
            self.assertEqual(summary["verdict_faithful_sufficiency"],
                             {"accept/not_adjudicated/sufficient": 6, "reject/yes/sufficient": 1,
                              "reject/yes/insufficient": 1})
            self.assertEqual(summary["faithful_by_answerer"], {"openai": {"not_adjudicated": 3, "yes": 1},
                                                               "qwen": {"not_adjudicated": 3, "yes": 1}})
            self.assertEqual(summary["faithful_by_category"]["multi-session"], {"yes": 1, "not_adjudicated": 3})
            self.assertEqual(sum(sum(v.values()) for v in summary["faithful_by_stratum"].values()), 8)
            self.assertEqual(summary["revision"]["changed_item_ids"], sorted([ids["00000000"], ids["00000005"]]))
            self.assertNotIn("listed", summary["revision"])
            # A revision's sufficiency change is not a change after reveal in the form.
            self.assertEqual(summary["sufficiency_changed_after_reveal"], 0)
            self.assertEqual(summary["verdict"], {"accept": 6, "reject": 2})
            # Faithful never enters judge error rates: changing it leaves every rate identical.
            flipped = copy.deepcopy(revised)
            flipped.pop("revision")
            for decision in flipped["decisions"].values():
                decision["faithful"] = "no"
            flipped_path = Path(directory) / "flipped.json"
            flipped_path.write_text(json.dumps(flipped))
            other = jc.score(out, flipped_path, [("vertex-opus", str(label_path))])
            column = lambda r: {e["judge"]: e for e in r["candidate_judges"]}["vertex-opus"]  # noqa: E731
            self.assertEqual(column(result)["grounded"], column(other)["grounded"])
            self.assertEqual(column(result)["grounded"]["overall"]["false_accept"]["count"], 2)
            self.assertEqual(other["adjudication"]["faithful"], {"no": 8})
            self.assertEqual(result["historical_labels"], other["historical_labels"])
            # Without a revision, a form-side sufficiency change after reveal is still counted.
            self.assertEqual(other["adjudication"]["sufficiency_changed_after_reveal"], 1)
            self.assertIn("faithful", result["definitions"])
            printed = json.dumps(result)
            self.assertNotIn("synthetic note", printed)
            self.assertNotIn("synthetic rubric", printed)

    def test_form_records_and_exports_faithful(self):
        c = candidate("r", "q0000014", "hybrid", None, labels={"x": {"verdict": "accept"}})
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "set"
            jc.assemble([c], "seed", out, per_stratum=1, minimum=1)
            form = (out / "adjudication-form.html").read_text()
            destination = Path(directory) / "forms" / "adjudication-form.html"
            summary = jc.regenerate_form(out, destination)
            # Same template and data as at assembly; only the item key order differs (items.json is key-sorted).
            items_raw = (out / "items.json").read_bytes()
            self.assertEqual(destination.read_bytes(),
                             jc.render_form(json.loads(items_raw), hashlib.sha256(items_raw).hexdigest()))
            data = lambda html: json.loads(re.search(r'id="data">(.*?)</script>', html, re.S).group(1))  # noqa: E731
            self.assertEqual(data(destination.read_text()), data(form))
            self.assertEqual(stat.S_IMODE(os.stat(destination).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(destination.parent).st_mode), 0o700)
            self.assertEqual(summary["adjudication_format"], jc.ADJUDICATION_FORMAT)
            self.assertEqual(summary["form_sha256"], hashlib.sha256(destination.read_bytes()).hexdigest())
            with self.assertRaisesRegex(jc.CalibrationError, "^file_exists$"):
                jc.regenerate_form(out, destination)
            with self.assertRaisesRegex(jc.CalibrationError, "^form_output_not_html$"):
                jc.regenerate_form(out, Path(directory) / "forms" / "form.json")
            (out / "items.json").chmod(0o600)
            (out / "items.json").write_text((out / "items.json").read_text() + " ")
            with self.assertRaisesRegex(jc.CalibrationError, "^items_hash_mismatch$"):
                jc.regenerate_form(out, Path(directory) / "forms" / "again.html")
        for value in ("yes", "no", "unsure"):
            self.assertIn(f'<input type="radio" name="faithful" value="{value}">', form)
        # Faithful sits in the answer block, which opens only after the reveal.
        self.assertLess(form.index('id="answerblock"'), form.index('name="faithful"'))
        self.assertLess(form.index('name="faithful"'), form.index('<fieldset><legend>Note'))
        self.assertIn("3. Faithful to the evidence", form)
        self.assertIn("A decline (\"no record of that\") on an answerable question is a reject", form)
        self.assertIn(f'format:"{jc.ADJUDICATION_FORMAT}"', form)
        self.assertIn("faithful:FAITHFUL.indexOf(d.faithful) >= 0 ? d.faithful : null", form)
        self.assertIn(json.dumps(list(jc.ADJUDICATION_FORMATS)) + ".indexOf(parsed.format)", form)
        self.assertIn("state.decisions = normalized(parsed.decisions)", form)
        self.assertNotIn("__ADJ_FORMAT", form)
        self.assertIn("connect-src 'none'", form)

    def test_judge_messages_keep_answer_out_of_sufficiency(self):
        c = candidate("r", "q0000011", "hybrid", None, answer="UNIQUE-ANSWER-TOKEN")
        item, _ = jc.blind_item(c, "item-001")
        sufficiency = json.dumps(jc.judge_messages(item, "sufficiency"))

        def upstream(task, question, answer, response, abstention=False):  # synthetic stand-in
            return f"{task} {question} {answer} {response} {abstention}"
        verdict = json.dumps(jc.judge_messages(item, "verdict", upstream))
        self.assertNotIn("UNIQUE-ANSWER-TOKEN", sufficiency)
        self.assertIn("UNIQUE-ANSWER-TOKEN", verdict)
        self.assertNotIn("temperature", sufficiency + verdict)

    def test_declaration_templates(self):
        directory = jc.ROOT / "scripts" / "judge_calibration_declarations"
        for (judge, model), suffix in ((pair, suffix) for pair in jc.DECLARATION_MODELS.items()
                                       for suffix in ("", ".v3")):
            template = json.loads((directory / f"{judge}{suffix}.template.json").read_text())
            self.assertEqual(template["provider"]["model"], model)
            self.assertEqual(template["provider"]["project_id"], "llm-train-482420")
            self.assertEqual(template["provider"]["location"], "global")
            problems = jc.check_declaration(template)
            self.assertIn("unfilled:budget.spending_cap_usd", problems)
            self.assertIn("unfilled:pricing.input_usd_per_million_tokens", problems)
            filled = json.loads(json.dumps(template).replace('"REQUIRED"', '"1"'))
            filled["calibration_set"]["item_count"] = 50
            filled["budget"].update(max_generation_requests=300, max_count_requests=100)
            filled["outputs"]["labels_path"] = f".build/judge-calibration/labels-{judge}.json"
            self.assertEqual(jc.check_declaration(filled), [])
            for mutate, code in ((lambda d: d["execution"].update(temperature=0), "forbidden_field:execution.temperature"),
                                 (lambda d: d["execution"].update(count_tokens_before_generation=False), "token_counting"),
                                 (lambda d: d["provider"].update(location="us-east5"), "provider_route"),
                                 (lambda d: d["budget"].update(spending_cap_usd="0"), "positive_decimal:budget.spending_cap_usd"),
                                 (lambda d: d["prompts"].update(sha256="0" * 64), "prompt_hash")):
                bad = copy.deepcopy(filled)
                mutate(bad)
                self.assertIn(code, jc.check_declaration(bad))

    def test_native_adapter_resolves_and_verifies_ranges(self):
        message = "Alpha beta gamma délta."
        dataset = {"q0000012": {"question_id": "q0000012", "question_type": "multi-session", "question": "Q?",
                                "answer": "R", "question_date": "2023/05/01", "haystack_dates": ["2023/01/01"],
                                "haystack_sessions": [[{"role": "user", "content": message}]]}}
        raw = message.encode()
        good = {"event_id": "q0000012-s0000-m0000", "offset": 6, "byte_length": 4,
                "field_sha256_x": hashlib.sha256(raw[6:10]).hexdigest()}
        evidence, verified, issue = jc.ranges_to_evidence(
            [good], ["q0000012-s0000-m0000"], lambda e: jc.dataset_message(dataset, e))
        self.assertTrue(verified)
        self.assertIsNone(issue)
        self.assertEqual(evidence[0]["text"], "beta")
        self.assertTrue(evidence[0]["partial"])
        bad = dict(good, field_sha256_x="0" * 64)
        self.assertEqual(jc.ranges_to_evidence([bad], [], lambda e: jc.dataset_message(dataset, e))[2],
                         "range_hash_mismatch")
        outside = dict(good, offset=100)
        self.assertEqual(jc.ranges_to_evidence([outside], [], lambda e: jc.dataset_message(dataset, e))[2],
                         "range_out_of_bounds")
        whole, verified, _ = jc.ranges_to_evidence([], ["q0000012-s0000-m0000"],
                                                   lambda e: jc.dataset_message(dataset, e))
        self.assertFalse(whole[0]["partial"])
        self.assertEqual(whole[0]["date"], "2023/01/01")

    def test_native_longmemeval_run_end_to_end(self):
        message = "The synthetic value is seven."
        dataset = {"q0000013": {"question_id": "q0000013", "question_type": "single-session-user", "question": "Q?",
                                "answer": "seven", "question_date": "2023/05/01", "haystack_dates": ["2023/01/01"],
                                "haystack_sessions": [[{"role": "user", "content": message}]]}}
        answer = "Seven."
        attempt = {"question_id": "q0000013", "question_type": "single-session-user", "abstention": False,
                   "strategy": "hybrid", "operational_complete": True,
                   "answer_sha256": hashlib.sha256(answer.encode()).hexdigest(),
                   "delivery": {"all_evidence_turns_delivered": True},
                   "metadata": {"delivered_ranges": [{"event_id": "q0000013-s0000-m0000", "offset": 0,
                                                      "byte_length": len(message.encode())}],
                                "delivered_recent_source_ids": []}}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name, report, hypotheses, qa = jc.NATIVE_LONGMEMEVAL_RUNS[2]
            (root / report).write_text(json.dumps({"configuration": {"model": jc.QWEN_MODEL},
                                                   "histories": [{"attempts": [attempt]}]}))
            (root / hypotheses).mkdir()
            (root / hypotheses / "hybrid.jsonl").write_text(json.dumps({"question_id": "q0000013",
                                                                        "hypothesis": answer}) + "\n")
            (root / qa).mkdir()
            (root / qa / "report.json").write_text(json.dumps({"attempts": [
                {"category": "single-session-user", "strategy": "hybrid", "scored": True,
                 "upstream_yes_substring_label": True}]}))
            found = jc.native_longmemeval_candidates([root], dataset)
            self.assertEqual(len(found), 1)
            c = found[0]
            self.assertIsNone(jc.eligibility(c))
            self.assertEqual(jc.stratum_of(c), "accepted")
            self.assertEqual(c["prior_labels"], {"qwen-local-qa": {"verdict": "accept"}})
            self.assertEqual(c["answerer_family"], "qwen")
            row = jc.inventory_row({**c, "eligible": True, "stratum": "accepted"})
            self.assertNotIn(message, json.dumps(row))
            self.assertNotIn(answer, json.dumps(row))
            (root / qa / "report.json").write_text(json.dumps({"attempts": [
                {"category": "multi-session", "strategy": "hybrid", "scored": True,
                 "upstream_yes_substring_label": True}]}))
            with self.assertRaises(jc.CalibrationError):
                jc.native_longmemeval_candidates([root], dataset)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
