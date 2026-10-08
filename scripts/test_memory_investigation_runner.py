#!/usr/bin/env python3
"""Synthetic, offline runner contracts. No real tokens, histories or HTTP calls."""
from __future__ import annotations

import argparse
import contextlib
from dataclasses import asdict
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock
import uuid

import run_memory_investigation as runner
from memory_investigation import InvestigationLimits


SYNTHETIC_TOKEN = "synthetic-access-token-for-tests"
PRICING = {"input_usd_per_million_tokens": "2", "output_usd_per_million_tokens": "10"}
COUNT = runner.canonical({"input_tokens": 20})


def is_count(endpoint):
    return endpoint == runner.vertex.count_url()


def case():
    return {"question": "Which project did the synthetic user choose?", "question_date": "2026-01-02",
            "sources": [
                {"event_id": "opaque-source_abs", "original_session_id": "synthetic-source_abs",
                 "role": "user", "status": "complete", "session_index": 0, "turn_index": 0,
                 "content": "I chose the Cedar project.", "source_time": {"original_value": "2026-01-01",
                 "locator": "/synthetic/private-source_abs"}},
                {"event_id": "other-original-id", "original_session_id": "synthetic-source_abs",
                 "role": "assistant", "status": "complete", "session_index": 0, "turn_index": 1,
                 "content": "Cedar is recorded.", "source_time": None}]}


def reply(text="synthetic reply", input_tokens=20, output_tokens=3, **updates):
    value = {"id": "msg_synthetic", "type": "message", "role": "assistant", "model": runner.MODEL,
             "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "stop_sequence": None,
             "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens}}
    value.update(updates)
    return runner.canonical(value)


class RunnerContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.temp_path = Path(self.temp.name)
        self.input = self.temp_path / "synthetic-case.json"
        self.input.write_bytes(runner.canonical(case()))
        self.output = Path(__file__).resolve().parents[1] / ".build" / "evaluation" / ("synthetic-investigation-" + uuid.uuid4().hex)

    def tearDown(self):
        if self.output.exists() and not self.output.is_symlink():
            shutil.rmtree(self.output)
        self.temp.cleanup()

    def prepare(self):
        return runner.prepare(self.input, self.output, "0.10", runner.vertex.Pricing("2", "10"))

    def provider(self, cap="0.10", transport=None, limits=None, frozen=None, clock=None):
        self.output.mkdir(mode=0o700, parents=True)
        declaration = {"maximum_cost_microusd": runner.cost_cap_microusd(cap), "pricing": PRICING,
                       "limits": limits or asdict(InvestigationLimits())}
        calls = []
        def http(endpoint, payload, key):
            calls.append((endpoint, payload, key))
            if transport:
                return transport(endpoint, payload, key)
            if is_count(endpoint):
                return COUNT
            return reply()
        provider = runner.VertexProvider(self.output, declaration, http_fn=http, token_fn=lambda: SYNTHETIC_TOKEN,
                                         frozen_check=frozen or (lambda: None), clock_fn=clock)
        return provider, calls

    def messages(self):
        return [{"role": "system", "content": "Synthetic instruction."},
                {"role": "user", "content": "Synthetic data."}]

    def assert_fenced(self, provider, calls):
        length = len(calls)
        for operation in (lambda: provider.count(self.messages()),
                          lambda: provider.generate("answer", self.messages(), 8)):
            with self.assertRaisesRegex(runner.Error, "provider_fenced"):
                operation()
        self.assertEqual(len(calls), length)

    def test_offline_default_never_reads_credentials_or_calls_http(self):
        args = argparse.Namespace(input=str(self.input), output=str(self.output), execute=False,
                                  max_cost_usd=None, input_usd_per_mtok=None, output_usd_per_mtok=None)
        with mock.patch.object(runner.vertex, "AccessTokens", side_effect=AssertionError("credential read")), \
             mock.patch.object(runner.vertex, "post", side_effect=AssertionError("HTTP call")):
            result = runner.run(args)
        self.assertEqual(result, {"status": "prepared", "provider_calls": 0, "source_records": 2, "source_sessions": 1})
        declaration = runner.client.strict_json((self.output / "declaration.json").read_bytes())
        self.assertIsNone(declaration["maximum_cost_microusd"])

    def test_preparation_freezes_exact_input_and_private_files(self):
        declaration = self.prepare()
        self.assertEqual((self.output / "input-original.json").read_bytes(), self.input.read_bytes())
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        for path in self.output.rglob("*"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else 0o600)
        runner.verify_prepared(self.output, declaration)
        preview = (self.output / "navigation-preview.json").read_text()
        self.assertNotIn("synthetic-source_abs", preview)
        self.assertNotIn("opaque-source_abs", preview)
        self.assertNotIn("private-source_abs", preview)

    def test_no_clobber(self):
        self.prepare()
        sentinel = (self.output / "declaration.json").read_bytes()
        with self.assertRaisesRegex(runner.Error, "output_exists"):
            self.prepare()
        self.assertEqual((self.output / "declaration.json").read_bytes(), sentinel)

    def test_input_tampering_fences_before_http(self):
        declaration = self.prepare()
        self.input.write_bytes(runner.canonical({**case(), "question": "Changed synthetic question."}))
        calls = []
        provider = runner.VertexProvider(self.output, declaration, token_fn=lambda: SYNTHETIC_TOKEN,
                                         http_fn=lambda *args: calls.append(args))
        with self.assertRaisesRegex(runner.Error, "input_changed"):
            provider.count(self.messages())
        self.assert_fenced(provider, calls)

    def test_frozen_map_tampering_fences_before_http(self):
        declaration = self.prepare()
        (self.output / "navigation-preview.json").write_bytes(b"{}")
        calls = []
        provider = runner.VertexProvider(self.output, declaration, token_fn=lambda: SYNTHETIC_TOKEN,
                                         http_fn=lambda *args: calls.append(args))
        with self.assertRaisesRegex(runner.Error, "frozen_artifact_changed"):
            provider.count(self.messages())
        self.assertEqual(calls, [])

    def test_implementation_pin_tampering_fences_before_http(self):
        declaration = self.prepare()
        calls = []
        provider = runner.VertexProvider(self.output, declaration, token_fn=lambda: SYNTHETIC_TOKEN,
                                         http_fn=lambda *args: calls.append(args))
        with mock.patch.object(runner, "dependency_pins", return_value={}):
            with self.assertRaisesRegex(runner.Error, "implementation_changed"):
                provider.count(self.messages())
        self.assertEqual(calls, [])

    def test_strict_inputs_reject_labels_references_and_unknown_fields(self):
        for field in ("question_id", "reference", "answer", "question_type", "scorer", "positive_ids"):
            with self.subTest(field=field):
                with self.assertRaisesRegex(runner.Error, "case_fields_invalid"):
                    runner.validate_case(runner.canonical({**case(), field: "synthetic"}))
        value = case()
        value["sources"][0]["has_answer"] = True
        with self.assertRaisesRegex(runner.Error, "source_inventory_invalid"):
            runner.validate_case(runner.canonical(value))

    def test_duplicate_json_keys_and_constants_rejected(self):
        with self.assertRaises(runner.Error):
            runner.validate_case(b'{"question":"one","question":"two","question_date":"date","sources":[]}')
        with self.assertRaises(runner.Error):
            runner.validate_case(b'{"question":NaN,"question_date":"date","sources":[]}')

    def test_execution_requires_cap_and_declared_prices_before_preparation(self):
        for cap, rate_in, rate_out in ((None, "2", "10"), ("0.01", None, "10"), ("0.01", "2", None)):
            args = argparse.Namespace(input=str(self.input), output=str(self.output), execute=True,
                                      max_cost_usd=cap, input_usd_per_mtok=rate_in, output_usd_per_mtok=rate_out)
            with mock.patch.object(runner.vertex, "AccessTokens", side_effect=AssertionError("read")):
                with self.assertRaisesRegex(runner.Error, "execution_arguments_required"):
                    runner.run(args)
            self.assertFalse(self.output.exists())

    def test_synthetic_execution_failure_retains_engine_accounting(self):
        args = argparse.Namespace(input=str(self.input), output=str(self.output), execute=True,
                                  max_cost_usd="0.50", input_usd_per_mtok="2", output_usd_per_mtok="10")
        calls = []
        def http(endpoint, payload, key):
            calls.append(endpoint)
            return COUNT if is_count(endpoint) else reply(text="synthetic invalid plan")
        with mock.patch.object(runner.vertex, "AccessTokens", return_value=lambda: SYNTHETIC_TOKEN), \
             mock.patch.object(runner.vertex, "post", side_effect=http):
            result = runner.run(args)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["generation_calls"], 1)
        self.assertTrue(result["fenced"])
        receipt = runner.client.strict_json((self.output / "engine-failure-receipt.json").read_bytes())
        self.assertTrue(receipt["failed"])
        self.assertEqual(receipt["generation_calls"], 1)
        self.assertEqual(receipt["reserved_output_tokens"], 1024)
        self.assertFalse((self.output / "result.json").exists())
        self.assertEqual(sum(not is_count(url) for url in calls), 1)

    def test_synthetic_execution_preserves_transport_failure_code(self):
        args = argparse.Namespace(input=str(self.input), output=str(self.output), execute=True,
                                  max_cost_usd="0.50", input_usd_per_mtok="2", output_usd_per_mtok="10")
        def http(endpoint, payload, key):
            if is_count(endpoint):
                return COUNT
            raise runner.Error("http_status_429")
        with mock.patch.object(runner.vertex, "AccessTokens", return_value=lambda: SYNTHETIC_TOKEN), \
             mock.patch.object(runner.vertex, "post", side_effect=http):
            result = runner.run(args)
        self.assertEqual(result["failure"], "provider_generation_failed")
        self.assertEqual(result["provider_failure"], "http_status_429")
        self.assertEqual(result["unknown_generation_requests"], 1)
        self.assertTrue((self.output / "engine-failure-receipt.json").exists())

    def test_permission_tampering_fences_before_http(self):
        declaration = self.prepare()
        (self.output / "case.json").chmod(0o644)
        provider = runner.VertexProvider(self.output, declaration, token_fn=lambda: SYNTHETIC_TOKEN,
                                         http_fn=lambda *args: self.fail("unexpected HTTP"))
        with self.assertRaisesRegex(runner.Error, "frozen_permissions_changed"):
            provider.count(self.messages())

    def test_reply_byte_bound_is_enforced_even_with_small_reported_usage(self):
        with self.assertRaisesRegex(runner.Error, "stage_output_byte_bound_exceeded"):
            runner.parse_response(reply(text="x" * 257), 20, 8, 8)

    def test_known_usage_is_retained_when_stage_parser_fails(self):
        def transport(endpoint, payload, key):
            return COUNT if is_count(endpoint) else reply(stop_reason="max_tokens")
        provider, calls = self.provider(transport=transport)
        with self.assertRaisesRegex(runner.Error, "response_incomplete"):
            provider.generate("answer", self.messages(), 8)
        self.assertEqual(provider.reserved_cost, 120)
        self.assertEqual(provider.observed_cost, 70)
        self.assertEqual(provider.receipt()["unknown_generation_requests"], 0)
        self.assert_fenced(provider, calls)

    def test_cap_is_finite_positive_and_floored(self):
        for value in ("NaN", "Infinity", "-Infinity", "0", "-1", "bad", "0.0000009"):
            with self.subTest(value=value), self.assertRaises(runner.Error):
                runner.cost_cap_microusd(value)
        self.assertEqual(runner.cost_cap_microusd("0.0000019"), 1)

    def test_reserved_full_output_and_input_never_decrease(self):
        provider, calls = self.provider()
        self.assertEqual(provider.generate("answer", self.messages(), 8), "synthetic reply")
        self.assertEqual(provider.reserved_input, 20)
        self.assertEqual(provider.reserved_output, 8)
        self.assertEqual(provider.reserved_cost, 20 * 2 + 8 * 10)
        self.assertEqual(provider.observed_cost, 20 * 2 + 3 * 10)
        provider.generate("extract", self.messages(), 8)
        self.assertEqual(provider.reserved_cost, 2 * (20 * 2 + 8 * 10))
        self.assertEqual(provider.count_calls, 1)
        self.assertEqual(provider.generation_calls, 2)
        self.assertEqual(len(calls), 3)

    def test_cost_cap_stops_before_generation_and_all_further_calls(self):
        provider, calls = self.provider(cap="0.000119")
        with self.assertRaisesRegex(runner.Error, "cost_cap_exhausted"):
            provider.generate("answer", self.messages(), 8)
        self.assertEqual(len(calls), 1)  # Only the exact input count was dispatched.
        self.assertEqual(provider.generation_calls, 0)
        self.assert_fenced(provider, calls)

    def test_429_retains_unknown_reservation_and_fences(self):
        def transport(endpoint, payload, key):
            if is_count(endpoint):
                return COUNT
            raise runner.Error("http_status_429")
        provider, calls = self.provider(transport=transport)
        with self.assertRaisesRegex(runner.Error, "http_status_429"):
            provider.generate("answer", self.messages(), 8)
        self.assertEqual(provider.reserved_cost, 120)
        self.assertEqual(provider.receipt()["unknown_generation_requests"], 1)
        self.assert_fenced(provider, calls)
        self.assertTrue((self.output / "operation-0002-receipt.json").exists())

    def test_interrupt_during_generation_retains_reservation_and_fences(self):
        def transport(endpoint, payload, key):
            if is_count(endpoint):
                return COUNT
            raise KeyboardInterrupt()
        provider, calls = self.provider(transport=transport)
        with self.assertRaisesRegex(runner.Error, "investigation_cancelled"):
            provider.generate("answer", self.messages(), 8)
        self.assertEqual(provider.reserved_cost, 120)
        self.assertEqual(provider.receipt()["unknown_generation_requests"], 1)
        self.assert_fenced(provider, calls)
        self.assertTrue((self.output / "operation-0002-receipt.json").exists())

    def test_admission_deadline_fences_before_dispatch(self):
        clock = mock.Mock(side_effect=[0, 301])
        provider, calls = self.provider(clock=clock)
        with self.assertRaisesRegex(runner.Error, "provider_admission_deadline_exceeded"):
            provider.count(self.messages())
        self.assertEqual(calls, [])
        self.assert_fenced(provider, calls)

    def test_admission_deadline_after_reply_retains_reservation(self):
        now = [0]
        def transport(endpoint, payload, key):
            if is_count(endpoint):
                return COUNT
            now[0] = 301
            return reply()
        provider, calls = self.provider(transport=transport, clock=lambda: now[0])
        with self.assertRaisesRegex(runner.Error, "provider_admission_deadline_exceeded"):
            provider.generate("answer", self.messages(), 8)
        self.assertEqual(provider.reserved_cost, 120)
        self.assertEqual(provider.receipt()["unknown_generation_requests"], 1)
        self.assert_fenced(provider, calls)

    def test_missing_usage_retains_unknown_reservation(self):
        def transport(endpoint, payload, key):
            return COUNT if is_count(endpoint) else reply(usage=None)
        provider, calls = self.provider(transport=transport)
        with self.assertRaisesRegex(runner.Error, "usage_missing"):
            provider.generate("answer", self.messages(), 8)
        self.assertEqual(provider.reserved_cost, 120)
        self.assert_fenced(provider, calls)

    def test_count_failure_fences_all_generation(self):
        provider, calls = self.provider(transport=lambda *args: b"{}")
        with self.assertRaisesRegex(runner.Error, "count_invalid"):
            provider.count(self.messages())
        self.assertEqual(provider.generation_calls, 0)
        self.assert_fenced(provider, calls)

    def test_capture_failure_before_dispatch_fences(self):
        provider, calls = self.provider()
        with mock.patch.object(runner, "private_write", side_effect=runner.Error("private_capture_failed")):
            with self.assertRaisesRegex(runner.Error, "private_capture_failed"):
                provider.count(self.messages())
        self.assertEqual(calls, [])
        self.assert_fenced(provider, calls)

    def test_response_capture_failure_retains_generation_reservation(self):
        provider, calls = self.provider()
        provider.count(self.messages())
        original_write = runner.private_write
        def write(path, raw):
            if str(path).endswith("-response.json"):
                raise runner.Error("private_capture_failed")
            return original_write(path, raw)
        with mock.patch.object(runner, "private_write", side_effect=write):
            with self.assertRaisesRegex(runner.Error, "private_capture_failed"):
                provider.generate("answer", self.messages(), 8)
        self.assertEqual(provider.reserved_cost, 120)
        self.assert_fenced(provider, calls)

    def test_count_and_generation_caps(self):
        limits = asdict(InvestigationLimits())
        limits["maximum_count_calls"] = 1
        provider, calls = self.provider(limits=limits)
        provider.count(self.messages())
        with self.assertRaisesRegex(runner.Error, "count_budget_exhausted"):
            provider.count([{"role": "user", "content": "Different synthetic data."}])
        self.assert_fenced(provider, calls)

    def test_aggregate_reservations_stop_before_extra_generation(self):
        limits = asdict(InvestigationLimits())
        limits["reserved_output_tokens"] = 8
        provider, calls = self.provider(limits=limits)
        provider.generate("answer", self.messages(), 8)
        with self.assertRaisesRegex(runner.Error, "aggregate_token_budget_exhausted"):
            provider.generate("extract", self.messages(), 8)
        self.assertEqual(provider.generation_calls, 1)
        self.assertEqual(len(calls), 2)

    def test_stage_names_and_limits_are_bounded_before_any_http(self):
        for stage, bound in (("../../answer", 8), ("plan", 8), ("plan_7", 8),
                             ("plan_0", 1025), ("extract", 2049), ("answer", 1025), ("answer", True)):
            self.output = self.output.parent / ("synthetic-investigation-" + uuid.uuid4().hex)
            provider, calls = self.provider()
            with self.assertRaisesRegex(runner.Error, "stage_output_limit_invalid"):
                provider.generate(stage, self.messages(), bound)
            self.assertEqual(calls, [])
            shutil.rmtree(self.output)

    def test_parser_output_bound_counts_all_output(self):
        with self.assertRaisesRegex(runner.Error, "stage_output_bound_exceeded"):
            runner.parse_response(reply(output_tokens=9), 20, 8, 8)
        content, usage = runner.parse_response(reply(output_tokens=8), 20, 8, 8)
        self.assertEqual(content, "synthetic reply")
        self.assertEqual(usage["reasoning_tokens"], 0)
        thinking = reply(content=[{"type": "thinking", "thinking": "synthetic"}, {"type": "text", "text": "visible"}])
        self.assertEqual(runner.parse_response(thinking, 20, 8, 8)[0], "visible")

    def test_parser_rejects_unbounded_or_incomplete_outputs(self):
        variants = [reply(input_tokens=21), reply(model="different-model"), reply(stop_reason="max_tokens"),
                    reply(stop_reason="refusal"), reply(content=[]), reply(content=[None]),
                    reply(content=[{"type": "tool_use", "id": "synthetic", "name": "x", "input": {}}]),
                    reply(type="error"), reply(role="user")]
        for raw in variants:
            with self.subTest(raw_hash=runner.client.digest(raw)), self.assertRaises(runner.Error):
                runner.parse_response(raw, 20, 8, 8)

    def test_receipts_and_stdout_are_content_free(self):
        provider, calls = self.provider()
        provider.generate("answer", self.messages(), 8)
        summary = json.dumps(provider.receipt())
        self.assertNotIn("Synthetic data", summary)
        self.assertNotIn("synthetic reply", summary)
        self.assertNotIn(SYNTHETIC_TOKEN, summary)
        for receipt in self.output.glob("*-receipt.json"):
            self.assertNotIn("Synthetic data", receipt.read_text())
            self.assertNotIn("synthetic reply", receipt.read_text())
            self.assertNotIn(SYNTHETIC_TOKEN, receipt.read_text())
        stream = io.StringIO()
        with mock.patch.object(runner, "run", side_effect=ValueError("private source fragment")), \
             contextlib.redirect_stdout(stream):
            self.assertEqual(runner.main(["--input", str(self.input), "--output", str(self.output)]), 1)
        self.assertNotIn("private source fragment", stream.getvalue())

    def test_credential_echo_is_never_captured(self):
        def transport(endpoint, payload, key):
            return runner.canonical({"input_tokens": 20, "echo": SYNTHETIC_TOKEN})
        provider, calls = self.provider(transport=transport)
        with self.assertRaisesRegex(runner.Error, "credential_echo_refused"):
            provider.count(self.messages())
        self.assertFalse((self.output / "operation-0001-response.json").exists())
        self.assert_fenced(provider, calls)


if __name__ == "__main__":
    unittest.main()
