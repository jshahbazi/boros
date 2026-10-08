#!/usr/bin/env python3
"""Portable contracts for the content-free answerer diagnostic."""
import copy
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

    def vertex_reply(self, **updates):
        value = {"id": "msg_synthetic", "type": "message", "role": "assistant", "model": a.REMOTE_MODEL,
                 "content": [{"type": "text", "text": "answer"}], "stop_reason": "end_turn", "stop_sequence": None,
                 "usage": {"input_tokens": 10, "output_tokens": 800,
                           "cache_creation_input_tokens": 0, "cache_read_input_tokens": 2}}
        value.update(updates)
        return value

    def test_vertex_response_usage_and_output_bound(self):
        content, usage = a.parse_response(a.REMOTE, json.dumps(self.vertex_reply()).encode())
        self.assertEqual(content, "answer")
        self.assertEqual((usage["input_tokens"], usage["cached_input_tokens"]), (12, 2))
        self.assertEqual(usage["nonreasoning_output_upper_bound"], 800)
        for mutation in (lambda x: x["usage"].update(input_tokens=True),
                         lambda x: x["usage"].update(output_tokens=a.OUTPUT_CAP + 1),
                         lambda x: x.update(model="other"),
                         lambda x: x.update(stop_reason="max_tokens"),
                         lambda x: x.update(stop_reason="refusal")):
            bad = copy.deepcopy(self.vertex_reply()); mutation(bad)
            with self.assertRaises(a.DiagnosticError):
                a.parse_response(a.REMOTE, json.dumps(bad).encode())

    def test_vertex_payloads_extract_system_and_match_count_input(self):
        messages = [{"role": "system", "content": "system"}, {"role": "user", "content": "evidence"},
                    {"role": "user", "content": "question"}]
        body = a.payload_for(a.REMOTE, messages)
        count = a.vertex.count_payload(messages)
        self.assertNotIn("model", body)
        self.assertEqual(body["system"], "system")
        self.assertEqual(body["messages"], [{"role": "user", "content": [{"type": "text", "text": "evidence"},
                                                                         {"type": "text", "text": "question"}]}])
        self.assertEqual(body["max_tokens"], a.OUTPUT_CAP)
        self.assertEqual((count["system"], count["messages"], count["model"]), (body["system"], body["messages"], a.REMOTE_MODEL))

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
        for mutation in (lambda x: x["content"].append("bad"),
                         lambda x: x.update(content="bad"),
                         lambda x: x["content"][0].update(type="tool_use"),
                         lambda x: x.update(usage=[])):
            bad = copy.deepcopy(self.vertex_reply()); mutation(bad)
            with self.assertRaises(a.DiagnosticError):
                a.parse_response(a.REMOTE, json.dumps(bad).encode())
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
        value = self.vertex_reply(stop_reason="max_tokens")
        usage = a.parse_usage(a.REMOTE, value)
        self.assertEqual(usage["output_tokens"], 800)
        with self.assertRaises(a.DiagnosticError):
            a.parse_response(a.REMOTE, json.dumps(value).encode())

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

    def test_endpoint_preflight_happens_before_opener(self):
        with patch.object(a, "build_opener", side_effect=AssertionError("network")) as opener:
            for url in ("http://example.com/v1", "https://api.openai.com/v1/responses", a.vertex.generation_url(),
                        "http://127.0.0.1:11234/v1/tokenize"):
                with self.assertRaises(a.DiagnosticError):
                    a.http(url, {})
            self.assertFalse(opener.called)
        with patch.object(a.vertex, "build_opener", side_effect=AssertionError("network")) as opener:
            for url in ("https://example.com/v1", "https://api.openai.com/v1/responses",
                        a.vertex.generation_url().replace(a.vertex.PROJECT_ID, "other-project")):
                with self.assertRaises(a.DiagnosticError):
                    a.vertex.post(url, {}, "synthetic-token")
            self.assertFalse(opener.called)

    def test_input_pins_fail_before_credentials_or_transport(self):
        eval_root = Path(__file__).resolve().parents[1] / ".build" / "evaluation"
        eval_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=eval_root) as root_name:
            root = Path(root_name)
            inputs_path, scorer_path = root / "inputs.json", root / "scorer.json"
            inputs_path.write_bytes(b"{}"); scorer_path.write_bytes(b"{}")
            args = type("Args", (), {"inputs": str(inputs_path), "scorer": str(scorer_path), "output": str(root / "out")})()
            with patch.object(a.vertex.subprocess, "run", side_effect=AssertionError("credential")) as tokens, \
                 patch.object(a.vertex, "build_opener", side_effect=AssertionError("transport")) as opener:
                with self.assertRaisesRegex(a.DiagnosticError, "input_pin_mismatch"):
                    a.run(args)
            self.assertFalse(tokens.called or opener.called)
            self.assertFalse((root / "out").exists())

if __name__ == "__main__":
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    raise SystemExit(not result.wasSuccessful())
