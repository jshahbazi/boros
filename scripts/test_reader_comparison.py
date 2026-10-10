#!/usr/bin/env python3
"""Synthetic contracts for the Gemini adapter and the reader comparison driver. No network, gcloud or
credentials, and no harness build."""
from __future__ import annotations

import io
import json
import re
import unittest
from pathlib import Path
from unittest.mock import patch

import reader_comparison as rc
import vertex_anthropic as va
import vertex_gemini as vg

ROOT = Path(__file__).resolve().parents[1]
MESSAGES = [{"role": "system", "content": "host"}, {"role": "user", "content": "earlier"},
            {"role": "assistant", "content": "reply"}, {"role": "user", "content": "question"}]


def gemini_reply(text="answer", reason="STOP", thought=True, **updates):
    parts = ([{"text": "private", "thought": True}] if thought else []) + [{"text": text}]
    value = {"candidates": [{"content": {"role": "model", "parts": parts}, "finishReason": reason}],
             "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 3, "thoughtsTokenCount": 40,
                               "totalTokenCount": 55},
             "modelVersion": "gemini-3.8-flash"}
    value.update(updates)
    return va.canonical(value)


def claude_reply(stop="end_turn", text="answer", model="claude-haiku-5-5"):
    return va.canonical({"type": "message", "role": "assistant", "model": model,
                         "content": [{"type": "text", "text": text}], "stop_reason": stop,
                         "usage": {"input_tokens": 10, "output_tokens": 4}})


class Contracts(unittest.TestCase):
    def test_gemini_urls_are_pinned_to_the_project_and_global(self):
        self.assertEqual(vg.generation_url("gemini-3.8-flash"), "https://aiplatform.googleapis.com/v1/projects/"
                         "llm-train-482420/locations/global/publishers/google/models/gemini-3.8-flash:generateContent")
        self.assertTrue(vg.is_vertex_url(vg.count_url("gemini-3.8-flash")))
        for model in ("gemini-3.8-pro", "gemini-3.8-flash ", "", None):
            with self.subTest(model=model), self.assertRaisesRegex(va.VertexError, "model_not_supported"):
                vg.generation_url(model)
        with patch.object(vg, "build_opener", side_effect=AssertionError("network")) as opener:
            with self.assertRaisesRegex(va.VertexError, "endpoint_refused"):
                vg.post(va.generation_url(model="claude-haiku-5-5"), {}, "synthetic-token")
            self.assertFalse(opener.called)

    def test_gemini_payload_maps_roles_and_sends_no_sampling(self):
        body = vg.payload(MESSAGES, 1024, thinking_level="low")
        self.assertEqual(body["systemInstruction"], {"parts": [{"text": "host"}]})
        self.assertEqual([turn["role"] for turn in body["contents"]], ["user", "model", "user"])
        self.assertEqual(body["generationConfig"], {"maxOutputTokens": 1024, "thinkingConfig": {"thinkingLevel": "low"}})
        self.assertNotIn("temperature", json.dumps(body))
        self.assertEqual(vg.count_payload(MESSAGES)["contents"], body["contents"])
        for level in ("minimal", "none", None):
            with self.subTest(level=level), self.assertRaisesRegex(va.VertexError, "thinking_invalid"):
                vg.payload(MESSAGES, 64, thinking_level=level)
        with self.assertRaisesRegex(va.VertexError, "first_turn_must_be_user"):
            vg.payload([{"role": "assistant", "content": "x"}], 64, thinking_level="low")

    def test_gemini_response_skips_thoughts_and_counts_them_as_output(self):
        text, usage = vg.parse_response(gemini_reply(), "gemini-3.8-flash")
        self.assertEqual(text, "answer")
        self.assertEqual(usage["output_tokens"], 43)
        self.assertEqual(usage["reasoning_tokens"], 40)
        self.assertEqual(usage["nonreasoning_output_upper_bound"], 3)
        self.assertEqual(vg.response_metadata(gemini_reply(reason="MAX_TOKENS")),
                         {"stop_reason": "MAX_TOKENS", "thinking_tokens": 40})
        for raw, code in ((gemini_reply(reason="MAX_TOKENS"), "response_incomplete"),
                          (gemini_reply(reason="SAFETY"), "refusal_or_output_invalid"),
                          (gemini_reply(modelVersion="gemini-3.8-pro"), "model_identity_mismatch"),
                          (gemini_reply(text=" "), "empty_answer"),
                          (b"{", "json_invalid")):
            with self.subTest(code=code), self.assertRaisesRegex(va.VertexError, code):
                vg.parse_response(raw, "gemini-3.8-flash")
        self.assertEqual(vg.parse_count(va.canonical({"totalTokens": 7})), 7)
        with self.assertRaisesRegex(va.VertexError, "count_invalid"):
            vg.parse_count(va.canonical({"totalTokens": 0}))

    def test_driver_requests_use_each_readers_declared_controls(self):
        row = {"maximum_output": 1024}
        url, body = rc.generation_request("claude-sonnet-5-5", MESSAGES, row)
        self.assertTrue(url.endswith("/claude-sonnet-5-5:rawPredict"))
        self.assertEqual((body["thinking"], body["max_tokens"], body["system"]), ({"type": "between_tools"}, 1024, "host"))
        _url, body = rc.generation_request("claude-haiku-5-5", MESSAGES, row)
        self.assertEqual(body["thinking"], {"type": "disabled"})
        url, body = rc.generation_request("gemini-3.8-flash", MESSAGES, row)
        self.assertTrue(url.endswith(":generateContent"))
        self.assertEqual(body["generationConfig"]["maxOutputTokens"], 1024 + 2048)
        for model in rc.READERS:
            _url, body = rc.generation_request(model, MESSAGES, {"maximum_output": 512})
            self.assertTrue({"temperature", "seed", "top_k", "top_p"}.isdisjoint(json.dumps(body).replace('"', " ").split()))

    def test_incomplete_responses_keep_text_and_other_failures_keep_none(self):
        text, usage, stop, failure = rc.parse("claude-haiku-5-5", claude_reply(stop="max_tokens"))
        self.assertEqual((text, stop, failure), ("answer", "max_tokens", "incomplete_result"))
        self.assertEqual(usage["output_tokens"], 4)
        text, _usage, stop, failure = rc.parse("gemini-3.8-flash", gemini_reply(reason="MAX_TOKENS"))
        self.assertEqual((text, stop, failure), ("answer", "MAX_TOKENS", "incomplete_result"))
        self.assertEqual(rc.parse("claude-haiku-5-5", claude_reply(stop="refusal"))[3], "refusal_or_output_invalid")
        self.assertIsNone(rc.parse("claude-haiku-5-5", claude_reply(stop="refusal"))[0])
        self.assertEqual(rc.parse("claude-haiku-5-5", claude_reply())[:4:3], ("answer", None))

    def test_jobs_cover_every_reader_question_and_replicate_once(self):
        manifest = {"rows": [{"cohort": "c", "question_id": f"q{n}"} for n in range(4)]}
        jobs = rc.jobs_for(manifest)
        self.assertEqual(len(jobs), 4 * len(rc.READERS) * rc.REPLICATES)
        self.assertEqual(len({(job["model"], job["question_id"], job["replicate"]) for job in jobs}), len(jobs))
        self.assertEqual([job["replicate"] for job in jobs], sorted(job["replicate"] for job in jobs))
        firsts = [jobs[n * len(rc.READERS)]["model"] for n in range(len(rc.READERS))]
        self.assertEqual(sorted(firsts), sorted(rc.READERS))

    def test_captured_bodies_must_be_plain_role_messages(self):
        self.assertEqual(rc.request_messages(va.canonical({"messages": MESSAGES, "stream": True})), MESSAGES)
        for body in ({"messages": []}, {"messages": [{"role": "tool", "content": "x"}]},
                     {"messages": [{"role": "user", "content": ["x"]}]}, []):
            with self.subTest(body=body), self.assertRaises(rc.ComparisonError):
                rc.request_messages(va.canonical(body))

    def test_worst_case_prices_stay_under_the_declared_cap_for_the_step3_sizes(self):
        # Qwen counted about 1.09M prompt tokens per pass; allow 40 percent more for other tokenizers.
        per_pass = 1_088_404 * 14 // 10
        worst = 0
        for model in rc.READERS:
            outputs = 94 * rc.max_output(model, {"maximum_output": 1024})
            worst += rc.pricing(model).microusd(per_pass, outputs) * rc.REPLICATES
        self.assertLessEqual(worst, int(rc.SPENDING_CAP_USD) * 10**6)

    def test_driver_prints_no_text_fields(self):
        source = (ROOT / "scripts/reader_comparison.py").read_text()
        for printed in re.findall(r"print\((.*)", source):
            for name in ("answer)", "text)", "messages", "raw)", "body)", "prompt"):
                self.assertNotIn(name, printed)

    def test_gemini_judge_uses_the_default_judges_request_and_parser(self):
        import gemini_judge as gj
        import judge_calibration as jc
        shape = jc.REPLY_INSTRUCTIONS["shapes"]["verdict"]
        accept = [key for key, value in shape["mapping"].items() if value == "accept"][0]
        reply = json.dumps({shape["field"]: accept})
        self.assertEqual(gj.label_from(gemini_reply(text=reply)), ("completed", "accept", None))
        self.assertEqual(gj.label_from(gemini_reply(text="```json\n" + reply + "\n```"))[1], "accept")
        self.assertEqual(gj.label_from(gemini_reply(text="yes")), ("parse_failed", None, "output_off_schema"))
        self.assertEqual(gj.label_from(gemini_reply(text=reply, reason="MAX_TOKENS"))[:2], ("response_invalid", None))
        source = (ROOT / "scripts/gemini_judge.py").read_text()
        self.assertIn('jc.judge_messages(item, "verdict", prompt_function, reply_instruction=True, verdict_rubric=False)',
                      source)
        self.assertEqual((gj.MODEL, gj.THINKING_LEVEL, gj.REPLICATES), ("gemini-3.8-flash", "low", 3))
        self.assertIn("vertex-gemini", jc.CANDIDATE_JUDGES)

    def test_harness_capture_writes_only_the_prepared_request_and_reports_digests(self):
        source = (ROOT / "Tests/Evaluation/DeliveryHarness.swift").read_text()
        self.assertIn("let capture_directory: String?", source)
        self.assertIn("EndpointRequest.digest(body) == preparation.requestDigest", source)
        self.assertIn('appendingPathComponent(arm + ".request.json")', source)
        self.assertIn("[.posixPermissions: 0o600]", source)
        self.assertIn("input.capture_directory == nil", source)  # control mode refuses capture
        self.assertIn('if stage == .answering { captured = preparation; coordinatorRef?.cancel() }', source)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
