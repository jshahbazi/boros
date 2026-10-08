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

    def test_judge_messages_keep_answer_out_of_sufficiency(self):
        c = candidate("r", "q0000011", "hybrid", None, answer="UNIQUE-ANSWER-TOKEN")
        item, _ = jc.blind_item(c, "item-001")
        sufficiency = json.dumps(jc.judge_messages(item, "sufficiency"))
        verdict = json.dumps(jc.judge_messages(item, "verdict"))
        self.assertNotIn("UNIQUE-ANSWER-TOKEN", sufficiency)
        self.assertIn("UNIQUE-ANSWER-TOKEN", verdict)
        self.assertNotIn("temperature", sufficiency + verdict)

    def test_declaration_templates(self):
        directory = jc.ROOT / "scripts" / "judge_calibration_declarations"
        for judge, model in jc.DECLARATION_MODELS.items():
            template = json.loads((directory / f"{judge}.template.json").read_text())
            self.assertEqual(template["provider"]["model"], model)
            self.assertEqual(template["provider"]["project_id"], "llm-train-482420")
            self.assertEqual(template["provider"]["location"], "global")
            problems = jc.check_declaration(template)
            self.assertIn("unfilled:budget.spending_cap_usd", problems)
            self.assertIn("unfilled:pricing.input_usd_per_million_tokens", problems)
            filled = json.loads(json.dumps(template).replace('"REQUIRED"', '"1"'))
            filled["calibration_set"]["item_count"] = 50
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
