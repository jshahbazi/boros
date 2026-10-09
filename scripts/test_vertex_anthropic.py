#!/usr/bin/env python3
"""Synthetic contracts for the Vertex AI adapter. No network, gcloud or credentials."""
from __future__ import annotations

import io
import json
import subprocess
import unittest
from unittest.mock import patch

import vertex_anthropic as v


def reply(**updates):
    value = {"id": "msg_synthetic", "type": "message", "role": "assistant", "model": v.MODEL,
             "content": [{"type": "text", "text": "answer"}], "stop_reason": "end_turn", "stop_sequence": None,
             "usage": {"input_tokens": 10, "output_tokens": 4, "cache_creation_input_tokens": 1,
                       "cache_read_input_tokens": 2}}
    value.update(updates)
    return v.canonical(value)


class Response:
    def __init__(self, raw):
        self.raw = raw

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, limit):
        return self.raw[:limit]


class Opener:
    def __init__(self, raw):
        self.raw, self.requests = raw, []

    def open(self, request, timeout):
        self.requests.append(request)
        return Response(self.raw)


class Contracts(unittest.TestCase):
    def test_routes_are_pinned_to_the_llm_train_project(self):
        self.assertEqual(v.PROJECT_ID, "llm-train-482420")
        self.assertEqual(v.generation_url(), "https://aiplatform.googleapis.com/v1/projects/llm-train-482420"
                         "/locations/global/publishers/anthropic/models/claude-opus-5-5:rawPredict")
        self.assertTrue(v.count_url().endswith("/publishers/anthropic/models/count-tokens:rawPredict"))
        self.assertEqual(v.host("us-east5"), "us-east5-aiplatform.googleapis.com")
        configuration = v.configuration()
        self.assertEqual((configuration["authentication"], configuration["api_key"], configuration["sampling"]),
                         ("google-application-default-credentials", False, "provider-default"))

    def test_payload_extracts_system_and_merges_consecutive_turns(self):
        messages = [{"role": "system", "content": "a"}, {"role": "system", "content": "b"},
                    {"role": "user", "content": "u1"}, {"role": "user", "content": "u2"},
                    {"role": "assistant", "content": "x"}, {"role": "user", "content": "u3"}]
        body = v.payload(messages, 64)
        self.assertEqual(body["system"], "a\n\nb")
        self.assertEqual([turn["role"] for turn in body["messages"]], ["user", "assistant", "user"])
        self.assertEqual(len(body["messages"][0]["content"]), 2)
        self.assertEqual((body["max_tokens"], body["anthropic_version"]), (64, v.ANTHROPIC_VERSION))
        self.assertTrue({"temperature", "top_p", "top_k", "thinking"}.isdisjoint(body))
        self.assertNotIn("model", body)
        count = v.count_payload(messages)
        self.assertEqual((count["model"], count["system"], count["messages"]), (v.MODEL, body["system"], body["messages"]))

    def test_payload_rejects_invalid_messages(self):
        for messages in ([], [{"role": "assistant", "content": "x"}], [{"role": "tool", "content": "x"}],
                         [{"role": "user", "content": "x"}, {"role": "system", "content": "late"}],
                         [{"role": "user", "content": 1}], [{"role": "user", "content": "x", "name": "n"}]):
            with self.subTest(messages=messages), self.assertRaises(v.VertexError):
                v.payload(messages, 8)
        for limit in (0, -1, True, 1.5):
            with self.assertRaises(v.VertexError):
                v.payload([{"role": "user", "content": "x"}], limit)

    def test_response_parsing_is_strict(self):
        text, usage = v.parse_response(reply())
        self.assertEqual(text, "answer")
        self.assertEqual(usage, {"input_tokens": 13, "output_tokens": 4, "reasoning_tokens": 0,
                                 "nonreasoning_output_upper_bound": 4, "cached_input_tokens": 2, "total_tokens": 17})
        self.assertEqual(v.parse_response(reply(model=v.MODEL + "@20260101"))[0], "answer")
        for raw in (reply(model="claude-other"), reply(model=v.MODEL + "-extra"), reply(stop_reason="max_tokens"),
                    reply(stop_reason="refusal"), reply(stop_reason=None), reply(content=[]),
                    reply(content=[{"type": "tool_use", "id": "t", "name": "n", "input": {}}]),
                    reply(content=[{"type": "text", "text": "   "}]), reply(usage=None),
                    reply(usage={"input_tokens": -1, "output_tokens": 1}), reply(usage={"input_tokens": 1, "output_tokens": True}),
                    reply(type="error"), b'{"type":"message","type":"message"}', b"{NaN}", b"x" * (v.MAXIMUM_RESPONSE_BYTES + 1)):
            with self.assertRaises(v.VertexError):
                v.parse_response(raw)

    def test_count_parsing(self):
        self.assertEqual(v.parse_count(b'{"input_tokens":16}'), 16)
        for raw in (b"{}", b'{"input_tokens":0}', b'{"input_tokens":true}', b'{"input_tokens":3,"extra":1}', b"[]"):
            with self.assertRaises(v.VertexError):
                v.parse_count(raw)

    def test_post_refuses_unpinned_destinations_before_any_opener(self):
        with patch.object(v, "build_opener", side_effect=AssertionError("network")) as opener:
            for url in ("https://api.openai.com/v1/responses", "http://aiplatform.googleapis.com/v1",
                        v.generation_url().replace("llm-train-482420", "other"), v.generation_url() + "?x=1"):
                with self.assertRaisesRegex(v.VertexError, "endpoint_refused"):
                    v.post(url, {}, "synthetic-token")
            with self.assertRaisesRegex(v.VertexError, "adc_token_unavailable"):
                v.post(v.count_url(), {}, "")
            self.assertFalse(opener.called)

    def test_post_sends_bearer_token_and_refuses_echo(self):
        opener = Opener(b'{"input_tokens":5}')
        with patch.object(v, "build_opener", return_value=opener):
            self.assertEqual(v.parse_count(v.post(v.count_url(), {"x": 1}, "synthetic-token")), 5)
        request = opener.requests[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer synthetic-token")
        self.assertEqual(request.full_url, v.count_url())
        with patch.object(v, "build_opener", return_value=Opener(b'{"echo":"synthetic-token"}')):
            with self.assertRaisesRegex(v.VertexError, "credential_echo_refused"):
                v.post(v.count_url(), {}, "synthetic-token")

    def test_http_errors_keep_status_only(self):
        from urllib.error import HTTPError
        class Failing:
            def open(self, request, timeout):
                raise HTTPError(request.full_url, 429, "PRIVATE_SENTINEL", {}, io.BytesIO(b"PRIVATE_BODY"))
        with patch.object(v, "build_opener", return_value=Failing()):
            with self.assertRaises(v.VertexError) as caught:
                v.post(v.generation_url(), {}, "synthetic-token")
        self.assertEqual(str(caught.exception), "http_status_429")

    def test_access_tokens_come_from_gcloud_adc_and_refresh(self):
        now = [0.0]
        outputs = iter([b"token-one\n", b"token-two\n"])
        def run(command, capture_output, timeout):
            return subprocess.CompletedProcess(command, 0, next(outputs), b"")
        tokens = v.AccessTokens(clock=lambda: now[0])
        with patch.object(v.subprocess, "run", side_effect=run) as process:
            self.assertEqual(tokens(), "token-one")
            self.assertEqual(tokens(), "token-one")
            now[0] = v.TOKEN_REFRESH_SECONDS
            self.assertEqual(tokens(), "token-two")
        self.assertEqual(process.call_args_list[0].args[0], ["gcloud", "auth", "application-default", "print-access-token"])
        for result in (subprocess.CompletedProcess([], 1, b"token", b""), subprocess.CompletedProcess([], 0, b"", b""),
                       subprocess.CompletedProcess([], 0, b"two words", b"")):
            with patch.object(v.subprocess, "run", return_value=result), self.assertRaises(v.VertexError):
                v.AccessTokens()()
        with patch.object(v.subprocess, "run", side_effect=FileNotFoundError("gcloud")), self.assertRaises(v.VertexError):
            v.AccessTokens()()

    def test_opus_remains_the_default_for_existing_callers(self):
        self.assertEqual(v.MODEL, "claude-opus-5-5")
        self.assertEqual(v.MODELS, ("claude-opus-5-5", "claude-sonnet-5-5"))
        messages = [{"role": "user", "content": "x"}]
        self.assertEqual(v.generation_url(), v.generation_url(model="claude-opus-5-5"))
        self.assertEqual(v.count_payload(messages), v.count_payload(messages, model="claude-opus-5-5"))
        self.assertEqual(v.configuration(), v.configuration(model="claude-opus-5-5"))
        self.assertEqual(v.parse_response(reply()), v.parse_response(reply(), model="claude-opus-5-5"))

    def test_sonnet_is_selected_per_run_with_the_same_contract(self):
        sonnet = "claude-sonnet-5-5"
        self.assertEqual(v.generation_url(model=sonnet), "https://aiplatform.googleapis.com/v1/projects/"
                         "llm-train-482420/locations/global/publishers/anthropic/models/claude-sonnet-5-5:rawPredict")
        self.assertTrue(v.is_vertex_url(v.generation_url(model=sonnet)))
        self.assertEqual(v.configuration(model=sonnet)["model"], sonnet)
        self.assertEqual(v.configuration(model=sonnet)["sampling"], "provider-default")
        messages = [{"role": "system", "content": "s"}, {"role": "user", "content": "u"}]
        self.assertEqual(v.count_payload(messages, model=sonnet)["model"], sonnet)
        body = v.payload(messages, 32)
        self.assertTrue({"temperature", "top_p", "top_k", "thinking", "model"}.isdisjoint(body))
        self.assertEqual(v.parse_response(reply(model=sonnet), model=sonnet)[0], "answer")
        self.assertEqual(v.parse_response(reply(model=sonnet + "@20260901"), model=sonnet)[0], "answer")
        for raw, model in ((reply(model=sonnet), "claude-opus-5-5"), (reply(), sonnet),
                           (reply(model=sonnet + "-extra"), sonnet)):
            with self.assertRaisesRegex(v.VertexError, "model_identity_mismatch"):
                v.parse_response(raw, model=model)
        opener = Opener(reply(model=sonnet))
        with patch.object(v, "build_opener", return_value=opener):
            v.post(v.generation_url(model=sonnet), v.payload(messages, 8), "synthetic-token")
        self.assertEqual(opener.requests[0].full_url, v.generation_url(model=sonnet))

    def test_unknown_models_are_refused_before_any_opener(self):
        with patch.object(v, "build_opener", side_effect=AssertionError("network")) as opener:
            for model in ("claude-haiku-5-5", "claude-opus-5-5 ", "", None):
                for call in (lambda: v.generation_url(model=model), lambda: v.configuration(model=model),
                             lambda: v.count_payload([{"role": "user", "content": "x"}], model=model),
                             lambda: v.parse_response(reply(), model=model)):
                    with self.subTest(model=model), self.assertRaisesRegex(v.VertexError, "model_not_supported"):
                        call()
            other = v.generation_url().replace("claude-opus-5-5", "claude-haiku-5-5")
            with self.assertRaisesRegex(v.VertexError, "endpoint_refused"):
                v.post(other, {}, "synthetic-token")
            self.assertFalse(opener.called)

    def test_generation_controls_are_opt_in_and_validated_per_model(self):
        messages = [{"role": "system", "content": "s"}, {"role": "user", "content": "u"}]
        schema = {"type": "object", "properties": {"answer": {"type": "string", "enum": ["yes", "no"]}},
                  "required": ["answer"], "additionalProperties": False}
        default = v.payload(messages, 64)
        self.assertEqual(set(default), {"anthropic_version", "messages", "max_tokens", "system"})
        self.assertEqual(v.count_payload(messages), v.count_payload(messages, schema=None))
        sonnet = v.payload(messages, 64, model="claude-sonnet-5-5", schema=schema, thinking={"type": "between_tools"})
        self.assertEqual(sonnet["thinking"], {"type": "between_tools"})
        self.assertEqual(sonnet["output_config"], {"format": {"type": "json_schema", "schema": schema}})
        self.assertEqual({key: value for key, value in sonnet.items() if key not in ("thinking", "output_config")},
                         default)
        self.assertEqual(v.payload(messages, 64, model="claude-sonnet-5-5", thinking={"type": "between_tools"},
                                   effort="high")["output_config"], {"effort": "high"})
        opus = v.payload(messages, 2048, model="claude-opus-5-5", schema=schema, effort="low")
        self.assertNotIn("thinking", opus)
        self.assertEqual(opus["output_config"], {"effort": "low", "format": {"type": "json_schema", "schema": schema}})
        for body in (sonnet, opus):
            self.assertTrue({"temperature", "top_p", "top_k", "output_format", "model"}.isdisjoint(body))
        count = v.count_payload(messages, model="claude-sonnet-5-5", schema=schema)
        self.assertEqual(count["output_config"], {"format": {"type": "json_schema", "schema": schema}})
        self.assertTrue({"thinking", "max_tokens"}.isdisjoint(count))
        for model, thinking, effort, code in (
                ("claude-sonnet-5-5", {"type": "disabled"}, None, "thinking_invalid"),
                ("claude-sonnet-5-5", {"type": "adaptive"}, None, "thinking_invalid"),
                ("claude-sonnet-5-5", {"type": "enabled", "budget_tokens": 1024}, None, "thinking_invalid"),
                ("claude-sonnet-5-5", {"type": "between_tools", "display": "omitted"}, None, "thinking_invalid"),
                ("claude-sonnet-5-5", {"type": "between_tools"}, "xhigh", "effort_invalid_with_between_tools"),
                ("claude-sonnet-5-5", {"type": "between_tools"}, "max", "effort_invalid_with_between_tools"),
                ("claude-opus-5-5", {"type": "between_tools"}, None, "thinking_unsupported_for_model"),
                ("claude-opus-5-5", {"type": "disabled"}, "low", "thinking_invalid"),
                ("claude-opus-5-5", None, "minimal", "effort_invalid"),
                ("claude-haiku-5-5", None, "low", "model_not_supported")):
            with self.subTest(model=model, thinking=thinking, effort=effort), self.assertRaisesRegex(v.VertexError, code):
                v.payload(messages, 64, model=model, thinking=thinking, effort=effort)
        for bad in ({"type": "object", "properties": {}, "required": []},
                    {"type": "object", "properties": {"a": {"type": "object", "properties": {}, "required": []}},
                     "required": ["a"], "additionalProperties": False},
                    {"type": "string"}, [], None):
            with self.subTest(schema=bad), self.assertRaisesRegex(v.VertexError, "output_schema_invalid"):
                v.payload(messages, 64, schema=bad) if bad is not None else v.output_format(bad)

    def test_response_metadata_reports_stop_reason_and_thinking_tokens_only(self):
        raw = reply(stop_reason="max_tokens", content=[{"type": "thinking", "thinking": "", "signature": "s"}],
                    usage={"input_tokens": 5, "output_tokens": 256, "output_tokens_details": {"thinking_tokens": 256}})
        self.assertEqual(v.response_metadata(raw), {"stop_reason": "max_tokens", "thinking_tokens": 256})
        self.assertEqual(v.response_metadata(reply()), {"stop_reason": "end_turn", "thinking_tokens": None})
        self.assertEqual(v.response_metadata(reply(stop_reason="PRIVATE_TEXT")), {"stop_reason": "other",
                                                                                   "thinking_tokens": None})
        self.assertEqual(v.response_metadata(b"not json"), {"stop_reason": None, "thinking_tokens": None})
        # Existing callers' usage records are unchanged: reasoning stays zero.
        self.assertEqual(v.parse_usage(json.loads(raw))["reasoning_tokens"], 0)
        with self.assertRaisesRegex(v.VertexError, "response_incomplete"):
            v.parse_response(raw)

    def test_pricing_is_declared_and_rounds_up(self):
        pricing = v.Pricing("5", "25")
        self.assertEqual(pricing.microusd(1000, 100), 7500)
        self.assertEqual(v.Pricing("0.3", "1").microusd(1, 0), 1)
        self.assertEqual(pricing.declaration()["input_usd_per_million_tokens"], "5")
        for value in ("NaN", "Infinity", "0", "-1", "bad", None):
            with self.assertRaises(v.VertexError):
                v.Pricing(value, "1")


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
