#!/usr/bin/env python3
"""Portable contracts for the content-free answerer diagnostic."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import evaluate_answerer_controls as a


class Contracts(unittest.TestCase):
    def test_strict_json_rejects_duplicate_extra_and_fenced_judge(self):
        with self.assertRaises(a.DiagnosticError):
            a.strict_json(b'{"x":1,"x":2}')
        with self.assertRaises(a.DiagnosticError):
            a.parse_judge('{"question_answered":"yes","reference_consistent":"yes",'
                          '"all_claims_supported":"yes","pack_sufficient":"yes","extra":"no"}')
        with self.assertRaises(a.DiagnosticError):
            a.parse_judge('```json {"question_answered":"yes"} ```')

    def test_judge_requires_exact_fields_and_values(self):
        valid = {key: "yes" for key in a.FIELDS}
        self.assertEqual(a.parse_judge(json.dumps(valid)), valid)
        for key, value in (("question_answered", "maybe"), ("pack_sufficient", 1)):
            bad = dict(valid); bad[key] = value
            with self.assertRaises(a.DiagnosticError):
                a.parse_judge(json.dumps(bad))

    def test_openai_usage_bounds_reasoning_separately(self):
        raw = {"model": a.OPENAI_MODEL, "status": "completed", "error": None,
               "output": [{"type": "reasoning", "status": "completed"},
                          {"type": "message", "role": "assistant", "status": "completed",
                           "content": [{"type": "output_text", "text": "answer"}]}],
               "usage": {"input_tokens": 10, "output_tokens": 1200, "total_tokens": 1210,
                         "output_tokens_details": {"reasoning_tokens": 400},
                         "input_tokens_details": {"cached_tokens": 2}}}
        content, usage = a.parse_response("openai", json.dumps(raw).encode())
        self.assertEqual(content, "answer")
        self.assertEqual(usage["nonreasoning_output_upper_bound"], 800)
        for mutation in (lambda x: x["usage"].update(total_tokens=1),
                         lambda x: x["usage"].update(output_tokens_details={"reasoning_tokens": 1300}),
                         lambda x: x["usage"].update(input_tokens=True),
                         lambda x: x.update(model="other")):
            bad = copy.deepcopy(raw); mutation(bad)
            with self.assertRaises(a.DiagnosticError):
                a.parse_response("openai", json.dumps(bad).encode())

    def test_qwen_usage_and_incomplete_response_refused(self):
        raw = {"model": a.QWEN_MODEL, "choices": [{"finish_reason": "stop",
               "message": {"role": "assistant", "content": "answer"}}],
               "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18,
                         "completion_tokens_details": {"reasoning_tokens": 0},
                         "prompt_tokens_details": {"cached_tokens": 0}}}
        self.assertEqual(a.parse_response("qwen", json.dumps(raw).encode())[1]["nonreasoning_output_upper_bound"], 8)
        for mutation in (lambda x: x["choices"][0].update(finish_reason="length"),
                         lambda x: x["usage"].update(total_tokens=19),
                         lambda x: x["usage"].update(completion_tokens=True)):
            bad = copy.deepcopy(raw); mutation(bad)
            with self.assertRaises(a.DiagnosticError):
                a.parse_response("qwen", json.dumps(bad).encode())

    def test_nested_output_and_usage_shapes_are_refused(self):
        valid_openai = {"model": a.OPENAI_MODEL, "status": "completed", "error": None,
                        "output": [{"type": "message", "role": "assistant", "status": "completed",
                                    "content": [{"type": "output_text", "text": "answer"}]}],
                        "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2,
                                  "output_tokens_details": {"reasoning_tokens": 0},
                                  "input_tokens_details": {"cached_tokens": 0}}}
        for mutation in (lambda x: x["output"].append("bad"),
                         lambda x: x["output"][0].update(content="bad"),
                         lambda x: x["output"][0]["content"][0].update(type="refusal"),
                         lambda x: x["usage"].update(output_tokens_details=[])):
            bad = copy.deepcopy(valid_openai); mutation(bad)
            with self.assertRaises(a.DiagnosticError):
                a.parse_response("openai", json.dumps(bad).encode())
        valid_qwen = {"model": a.QWEN_MODEL, "choices": [{"finish_reason": "stop",
                     "message": {"role": "assistant", "content": "answer", "refusal": None}}],
                     "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2,
                               "completion_tokens_details": {"reasoning_tokens": 0},
                               "prompt_tokens_details": {"cached_tokens": 0}}}
        for mutation in (lambda x: x["choices"].append({}),
                         lambda x: x["choices"][0].update(message=[]),
                         lambda x: x["usage"].update(prompt_tokens_details=[])):
            bad = copy.deepcopy(valid_qwen); mutation(bad)
            with self.assertRaises(a.DiagnosticError):
                a.parse_response("qwen", json.dumps(bad).encode())

    def test_usage_parser_preserves_valid_usage_before_response_rejection(self):
        value = {"usage": {"input_tokens": 3, "output_tokens": 1300, "total_tokens": 1303,
                            "output_tokens_details": {"reasoning_tokens": 400},
                            "input_tokens_details": {"cached_tokens": 1}}}
        usage = a.parse_usage("openai", value)
        self.assertEqual(usage["nonreasoning_output_upper_bound"], 900)
        incomplete = {"model": a.OPENAI_MODEL, "status": "incomplete", "error": None,
                      "output": [], **value}
        with self.assertRaises(a.DiagnosticError):
            a.parse_response("openai", json.dumps(incomplete).encode())

    def test_evidence_only_qwen_render_omits_generation_prefix(self):
        messages = [{"role": "system", "content": "system"}, {"role": "user", "content": "evidence"}]
        rendered = a.qwen_render(messages, generation_prefix=False)
        expected = "<|im_start|>system\nsystem<|im_end|>\n<|im_start|>user\nevidence<|im_end|>\n"
        self.assertEqual(rendered, expected)

    def test_qwen_literal_ascii_trim_and_think_normalization(self):
        messages = [{"role": "system", "content": "  system  "},
                    {"role": "user", "content": "  literal </think></think>  "}]
        rendered = a.qwen_render(messages)
        self.assertIn("system", rendered)
        self.assertIn("literal </think><|im_end|>", rendered)
        self.assertNotIn("</think></think>", rendered)

    def test_message_allowlist_excludes_reference_and_annotations(self):
        case = {"question_date": "synthetic-date", "question": "synthetic-question",
                "reference": "private-reference-sentinel", "annotations": {"x": "private"},
                "sources": [{"event_id": "event", "original_session_id": "session", "role": "user",
                             "status": "complete", "session_index": 0, "turn_index": 0,
                             "content": "synthetic-record", "source_time": None,
                             "reference": "private-source-reference", "has_answer": True}]}
        messages = a.messages_for(case)
        encoded = json.dumps(messages)
        self.assertNotIn("private-reference-sentinel", encoded)
        self.assertNotIn("private-source-reference", encoded)
        self.assertNotIn("has_answer", encoded)
        self.assertIn("synthetic-record", encoded)

    def test_endpoint_and_key_preflight_happens_before_opener(self):
        with patch.object(a, "build_opener", side_effect=AssertionError("network")) as opener:
            for url, key in (("http://example.com/v1", None),
                             ("https://api.openai.com/v1/responses", None),
                             ("http://127.0.0.1:11234/v1/tokenize", "secret")):
                with self.assertRaises(a.DiagnosticError):
                    a.http(url, {}, key)
            self.assertFalse(opener.called)

    def test_reuse_rejects_altered_parent_before_transport(self):
        """A mismatched parent pin must fail before any provider opener is built."""
        case_ids = ("synthetic-case",)
        inputs = {"case_ids": list(case_ids), "source_sha256": "synthetic-source",
                  "contains_reference_or_positive_labels": False,
                  "cases": [{"question_id": case_ids[0]}]}
        scorer = {"case_ids": list(case_ids), "cases": [{"question_id": case_ids[0]}]}
        eval_root = Path(__file__).resolve().parents[1] / ".build" / "evaluation"
        eval_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=eval_root) as root_name:
            root = Path(root_name)
            inputs_path, scorer_path, key_path = root / "inputs.json", root / "scorer.json", root / "key"
            inputs_raw, scorer_raw = a.canonical(inputs), a.canonical(scorer)
            inputs_path.write_bytes(inputs_raw); scorer_path.write_bytes(scorer_raw); key_path.write_text("synthetic-key")
            old = (a.CASE_IDS, a.SOURCE_SHA, a.INPUT_SHA, a.SCORER_SHA, a.PARENT_REPORT_SHA)
            try:
                a.CASE_IDS = case_ids; a.SOURCE_SHA = "synthetic-source"
                a.INPUT_SHA = hashlib.sha256(inputs_raw).hexdigest()
                a.SCORER_SHA = hashlib.sha256(scorer_raw).hexdigest(); a.PARENT_REPORT_SHA = "0" * 64
                with patch.object(a, "build_opener", side_effect=AssertionError("transport")) as opener:
                    for index, report_raw in enumerate((b"{}", b"[]", b"null", b"false", b"")):
                        parent = root / ("parent-" + str(index)); parent.mkdir()
                        (parent / "report.json").write_bytes(report_raw)
                        args = type("Args", (), {"inputs": str(inputs_path), "scorer": str(scorer_path),
                            "output": str(root / ("out-" + str(index))), "api_key_file": str(key_path),
                            "reuse_openai_run": str(parent)})()
                        with self.assertRaisesRegex(a.DiagnosticError, "parent_report_pin_mismatch"):
                            a.run(args)
                self.assertFalse(opener.called)
            finally:
                a.CASE_IDS, a.SOURCE_SHA, a.INPUT_SHA, a.SCORER_SHA, a.PARENT_REPORT_SHA = old


if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    raise SystemExit(not result.wasSuccessful())
