#!/usr/bin/env python3
"""Synthetic, content-free-output tests for frozen exact-answer diagnostics."""
import copy
import json
import unittest

from answer_rubrics import (MAX_RESPONSE_BYTES, RESPONSE_DIAGNOSTIC_VERSION, RESPONSE_ERROR_CODES,
                             RUBRIC_VERSION, RubricError, score_response, validate_oracle)


def oracle(kind="exact_quote"):
    row = {"rubric_version": RUBRIC_VERSION, "kind": kind, "expected_answers": ["value-new"],
           "required_source_ids": ["event-a"], "forbidden_answers": [], "answerable": True}
    if kind == "cross_message_quotes":
        row.update(expected_answers=["value-first", "value-second"], required_source_ids=["event-a", "event-b"])
    elif kind == "correction":
        row["forbidden_answers"] = ["value-old"]
    elif kind == "absence":
        row.update(expected_answers=[], required_source_ids=[], answerable=False)
    return row


def response(answer="value-new", citations=None, abstain=False):
    return json.dumps({"answer": answer, "citations": ["event-a"] if citations is None else citations,
                       "abstain": abstain}, ensure_ascii=False)


class RubricChecks(unittest.TestCase):
    def score(self, raw=None, gold=None, complete=True, delivered=None):
        return score_response(response() if raw is None else raw, oracle() if gold is None else gold,
                              operational_complete=complete,
                              delivered_source_ids={"event-a", "event-b"} if delivered is None else delivered)

    def test_exact_success(self):
        self.assertEqual(self.score()["score"], 1)

    def test_cross_message_success(self):
        row = self.score(response(["value-first", "value-second"], ["event-b", "event-a"]), oracle("cross_message_quotes"))
        self.assertEqual(row["score"], 1)
        self.assertEqual(row["required_source_count"], 2)

    def test_cross_message_order_is_frozen(self):
        self.assertEqual(self.score(response(["value-second", "value-first"], ["event-a", "event-b"]),
                                    oracle("cross_message_quotes"))["score"], 0)

    def test_cross_message_shape_is_fixed(self):
        row = self.score(response(), oracle("cross_message_quotes"))
        self.assertEqual(row["failure_code"], "response_invalid")
        self.assertEqual(row["response_error_code"], "response_answer_shape_array")

    def test_quote_shape_is_fixed(self):
        row = self.score(response(["value-new"]))
        self.assertEqual(row["failure_code"], "response_invalid")
        self.assertEqual(row["response_error_code"], "response_answer_shape_string")

    def test_negated_correct_value_fails(self):
        self.assertFalse(self.score(response("not value-new"))["answer_correct"])

    def test_case_and_unicode_normalization_are_exact(self):
        gold = oracle()
        gold["expected_answers"] = ["caf\u00e9"]
        self.assertEqual(self.score(response("cafe\u0301"), gold)["score"], 0)
        self.assertEqual(self.score(response("Value-new"))["score"], 0)

    def test_correction_success(self):
        self.assertEqual(self.score(response(), oracle("correction"))["score"], 1)

    def test_obsolete_answer_fails(self):
        row = self.score(response("value-old"), oracle("correction"))
        self.assertFalse(row["answer_correct"])
        self.assertEqual(row["failure_code"], "answer_mismatch")

    def test_obsolete_answer_in_explanation_fails(self):
        self.assertEqual(self.score(response("value-new instead of value-old"), oracle("correction"))["score"], 0)

    def test_absence_requires_empty_answer(self):
        self.assertEqual(self.score(response("", [], True), oracle("absence"))["score"], 1)
        self.assertEqual(self.score(response("unknown", [], True), oracle("absence"))["score"], 0)

    def test_absence_requires_empty_citations(self):
        self.assertFalse(self.score(response("", ["event-a"], True), oracle("absence"))["citation_correct"])

    def test_absence_requires_abstention(self):
        self.assertEqual(self.score(response("", [], False), oracle("absence"))["failure_code"], "abstention_mismatch")

    def test_answerable_refuses_abstention(self):
        self.assertEqual(self.score(response(abstain=True))["score"], 0)

    def test_missing_citation_fails_separately(self):
        row = self.score(response(citations=[]))
        self.assertTrue(row["answer_correct"])
        self.assertFalse(row["citation_correct"])

    def test_extra_citation_fails(self):
        self.assertEqual(self.score(response(citations=["event-a", "event-c"]))["score"], 0)

    def test_duplicate_citation_fails(self):
        self.assertEqual(self.score(response(citations=["event-a", "event-a"]))["score"], 0)

    def test_undelivered_source_fails(self):
        row = self.score(delivered=set())
        self.assertEqual(row["delivered_required_source_count"], 0)
        self.assertTrue(row["answer_correct"])
        self.assertFalse(row["citation_correct"])

    def test_partial_and_failed_score_zero(self):
        row = self.score(complete=False)
        self.assertEqual(row["score"], 0)
        self.assertEqual(row["failure_code"], "invocation_incomplete")
        self.assertFalse(row["answer_correct"])
        self.assertFalse(row["citation_correct"])

    def test_malformed_and_non_json_fail_closed(self):
        invalid = ["", "{", "```json\n" + response() + "\n```", response() + " extra",
                   response() + response(), "[]", "null", "true", "42", "\ufeff" + response()]
        for raw in invalid:
            self.assertEqual(self.score(raw)["failure_code"], "response_invalid")

    def test_duplicate_keys_fail_closed(self):
        raw = '{"answer":"value-old","answer":"value-new","citations":["event-a"],"abstain":false}'
        self.assertEqual(self.score(raw)["failure_code"], "response_invalid")

    def test_extra_and_missing_fields_fail_closed(self):
        payload = json.loads(response())
        payload["extra"] = "value-new"
        self.assertEqual(self.score(json.dumps(payload))["failure_code"], "response_invalid")
        del payload["extra"]
        del payload["abstain"]
        self.assertEqual(self.score(json.dumps(payload))["failure_code"], "response_invalid")

    def test_nonfinite_and_wrong_types_fail_closed(self):
        for raw in ['{"answer":NaN,"citations":[],"abstain":false}',
                    '{"answer":"value-new","citations":[],"abstain":0}',
                    '{"answer":"value-new","citations":"event-a","abstain":false}',
                    '{"answer":"value-new","citations":[1],"abstain":false}',
                    '{"answer":{},"citations":[],"abstain":false}']:
            self.assertEqual(self.score(raw)["failure_code"], "response_invalid")

    def test_invalid_utf8_surrogates_and_size_fail_closed(self):
        for raw in [b"\xff", response("\ud800"), " " * (MAX_RESPONSE_BYTES + 1), 1, None]:
            # None is a malformed input here, bypassing the convenience wrapper.
            row = score_response(raw, oracle(), operational_complete=True, delivered_source_ids={"event-a"})
            self.assertEqual(row["failure_code"], "response_invalid")

    def test_utf8_and_outer_whitespace_supported(self):
        self.assertEqual(self.score(("\n " + response() + " \t").encode())["score"], 1)

    def test_unknown_oracle_fields_and_version_rejected(self):
        for field, value in [("rubric_version", "unknown"), ("kind", "unknown"), ("extra", True), ("answerable", 1)]:
            gold = oracle()
            gold[field] = value
            with self.assertRaises(RubricError):
                validate_oracle(gold)

    def test_oracle_inconsistency_rejected(self):
        candidates = []
        for field, value in [("expected_answers", []), ("required_source_ids", []),
                             ("required_source_ids", ["event-a", "event-a"]), ("answerable", False),
                             ("forbidden_answers", ["value-old"])]:
            gold = oracle()
            gold[field] = value
            candidates.append(gold)
        gold = oracle("correction")
        gold["forbidden_answers"] = ["value"]
        candidates.append(gold)
        gold = oracle("absence")
        gold["required_source_ids"] = ["event-a"]
        candidates.append(gold)
        gold = oracle("cross_message_quotes")
        gold["required_source_ids"] = ["event-a"]
        candidates.append(gold)
        for gold in candidates:
            with self.assertRaises(RubricError):
                validate_oracle(gold)

    def test_host_evidence_types_rejected(self):
        for complete, delivered in [(1, {"event-a"}), (True, ["event-a"]), (True, {1})]:
            with self.assertRaises(RubricError):
                score_response(response(), oracle(), operational_complete=complete, delivered_source_ids=delivered)

    def test_results_contain_no_supplied_text(self):
        gold = copy.deepcopy(oracle())
        gold["expected_answers"] = ["synthetic-secret-value"]
        row = self.score(response("synthetic-secret-value", ["synthetic-secret-id"]), gold)
        encoded = json.dumps(row)
        self.assertFalse("synthetic-secret" in encoded)
        self.assertEqual(set(row), {"rubric_version", "kind", "score", "operational_complete", "response_valid",
                                   "answer_correct", "citation_correct", "abstention_correct", "required_source_count",
                                   "delivered_required_source_count", "citation_count", "failure_code",
                                   "response_diagnostic_version", "response_error_code"})

    def test_response_diagnostic_codes_are_fixed_and_content_free(self):
        cases = [
            (b"\xff", "response_utf8"), ("\ud800", "response_utf8"), (1, "response_type"),
            (b"{" + b"x" * (MAX_RESPONSE_BYTES + 1), "response_size"),
            (" " * (MAX_RESPONSE_BYTES + 1), "response_size"),
            ("{", "response_json_syntax"), ("[]", "response_top_level"),
            ("null", "response_top_level"), ("true", "response_top_level"),
            ("42", "response_top_level"),
            ("{" + '"answer":"x","answer":"y","citations":[],"abstain":false}', "response_duplicate_key"),
            ('{"answer":NaN,"citations":[],"abstain":false}', "response_nonfinite"),
            ('{"answer":"x","citations":[],"abstain":0}', "response_abstain_shape"),
            ('{"answer":"x","citations":"event-a","abstain":false}', "response_citations_shape"),
            ('{"answer":"x","citations":[],"abstain":false,"extra":1}', "response_keys"),
        ]
        for raw, code in cases:
            row = self.score(raw)
            self.assertEqual(row["failure_code"], "response_invalid")
            self.assertEqual(row["response_diagnostic_version"], RESPONSE_DIAGNOSTIC_VERSION)
            self.assertEqual(row["response_error_code"], code)
            self.assertIn(row["response_error_code"], RESPONSE_ERROR_CODES)

    def test_diagnostic_precedence_and_incomplete_preservation(self):
        row = self.score("{", complete=False)
        self.assertEqual(row["failure_code"], "invocation_incomplete")
        self.assertIsNone(row["response_error_code"])

    def test_valid_response_has_no_response_error(self):
        row = self.score()
        self.assertEqual(row["response_error_code"], None)
        self.assertEqual(row["failure_code"], None)


if __name__ == "__main__":
    import sys
    class SafeResult(unittest.TestResult):
        def __init__(self):
            super().__init__(); self.failed_names = []; self.error_names = []
        def addFailure(self, test, err):
            super().addFailure(test, err); self.failed_names.append(test.id().rsplit(".", 1)[-1])
        def addError(self, test, err):
            super().addError(test, err); self.error_names.append(test.id().rsplit(".", 1)[-1])
    result = SafeResult()
    unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]).run(result)
    print(json.dumps({"checks": result.testsRun, "failed": result.failed_names,
                      "errors": result.error_names, "skipped": len(result.skipped)}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
