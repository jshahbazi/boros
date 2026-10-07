#!/usr/bin/env python3
"""Public synthetic continuation contracts; no providers or private corpus reads."""
import copy
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

import continue_orientation_zoom as c


class Error(Exception):
    pass


GENERATION = {"model": "public-model", "input": [{"role": "user", "content": "Public fixture"}], "max_output_tokens": 8}
COUNT = {"model": "public-model", "input": GENERATION["input"]}
USAGE = {"input_tokens": 5, "output_tokens": 2, "reasoning_tokens": 0, "cached_input_tokens": 0}


def response(text="Public answer"):
    return c.canonical({"model": "public-model", "status": "completed", "text": text, "usage": USAGE})


def parse_response(raw, limit):
    value = c.strict_json(raw)
    if value.get("model") != "public-model" or value.get("status") != "completed":
        raise Error("invalid_public_response")
    return value["text"], value["usage"]


def parse_sufficiency(text):
    value = c.strict_json(text)
    c.require(isinstance(value, dict) and set(value) == {'sufficient'}
        and value['sufficient'] in ('yes', 'no', 'unknown'), 'public_sufficiency_invalid')
    return value


class FakeAPI:
    failure = None

    def __init__(self, output, key, declaration, protocol):
        self.output, self.declaration = output, declaration
        self.operations = {}
        self.http_calls = self.generation_calls = self.reserved_input = self.reserved_output = 0

    def frozen(self):
        pass

    def request(self, name, kind, payload, reserved_input=0):
        self.http_calls += 1
        self.generation_calls += kind == "generation"
        self.reserved_input += reserved_input
        self.reserved_output += payload.get("max_output_tokens", 0)
        raw = None if self.failure else response("New public answer")
        operation = write_operation(self.output, name, kind, payload, raw, failure=self.failure)
        self.operations[name] = operation
        if self.failure:
            raise Error(self.failure)
        return raw


PILOT = SimpleNamespace(API=FakeAPI, Error=Error, parse_response=parse_response,
    judging=SimpleNamespace(parse_sufficiency=parse_sufficiency),
    client=SimpleNamespace(private_write=c.private_write), private_json=lambda path, value: c.private_write(path, c.canonical(value)),
    ARMS=("baseline", "inspection", "orientation"), CASE_IDS=("public-case",))


def write_operation(root, name, kind, payload, raw=None, failure=None):
    operation = {"name": name, "kind": kind, "prepared": True, "dispatched": True, "received": raw is not None,
        "request_sha256": c.digest(c.canonical(payload)), "elapsed_seconds": 1.5}
    c.private_write(root / (name + "-request.json"), c.canonical(payload))
    if raw is not None:
        c.private_write(root / (name + "-response.json"), raw)
        operation["response_sha256"] = c.digest(raw)
        if kind == "generation":
            operation["usage"] = copy.deepcopy(USAGE)
    if failure:
        operation["failure"] = failure
    c.private_write(root / (name + "-operation.json"), c.canonical(operation))
    return operation


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.parent, self.output = self.root / "parent", self.root / "output"
        self.parent.mkdir(mode=0o700); self.output.mkdir(mode=0o700)
        self.operations = {}
        FakeAPI.failure = None

    def index(self):
        return c.ReplayIndex(self.parent, {"operations": self.operations}, PILOT)

    def api(self, index=None, **kwargs):
        return c.ReplayAPI(PILOT, self.output, "unused-public-fixture", {"dependencies": {}}, None,
            index or self.index(), **kwargs)

    def add(self, name, kind="generation", payload=GENERATION, raw=None, failure=None):
        self.operations[name] = write_operation(self.parent, name, kind, payload,
            response() if raw is None and failure is None else raw, failure)

    def test_generation_reuse_is_stage_specific_even_for_identical_bodies(self):
        self.add("stage-a", raw=response("Public A")); self.add("stage-b", raw=response("Public B"))
        api = self.api()
        self.assertEqual(c.strict_json(api.request("stage-a", "generation", GENERATION))["text"], "Public A")
        self.assertEqual(c.strict_json(api.request("stage-b", "generation", GENERATION))["text"], "Public B")
        self.assertEqual(c.strict_json(api.request("stage-c", "generation", GENERATION))["text"], "New public answer")
        self.assertEqual(api.http_calls, 1)
        self.assertEqual(api.provenance["stage-a"]["parent_name"], "stage-a")
        self.assertEqual(api.provenance["stage-b"]["parent_name"], "stage-b")

    def test_counts_can_reuse_identical_canonical_body_under_another_name(self):
        raw = c.canonical({"object": "response.input_tokens", "input_tokens": 5})
        self.add("count-a", "count", COUNT, raw)
        api = self.api()
        self.assertEqual(api.request("count-b", "count", COUNT), raw)
        self.assertEqual(api.http_calls, 0)
        self.assertEqual(api.provenance["count-b"]["parent_name"], "count-a")

    def test_source_only_sufficiency_can_reuse_valid_label_under_another_arm(self):
        raw = response('{"sufficient":"yes"}')
        self.add('arm-a-sufficiency', raw=raw)
        api = self.api()
        self.assertEqual(api.request('arm-b-sufficiency', 'generation', GENERATION), raw)
        self.assertEqual(api.http_calls, 0)
        self.assertEqual(api.provenance['arm-b-sufficiency']['parent_name'], 'arm-a-sufficiency')
        # The body exception never applies to answers, support or QA stages.
        api.request('arm-b-answer', 'generation', GENERATION)
        self.assertEqual(api.http_calls, 1)

    def test_failed_or_invalid_sufficiency_is_not_a_cross_arm_cache_hit(self):
        self.add('arm-a-sufficiency', raw=None, failure='transport_failed')
        self.add('arm-c-sufficiency', raw=response('{"sufficient":"maybe"}'))
        api = self.api()
        with self.assertRaises(Error):
            api.request('arm-a-sufficiency', 'generation', GENERATION)
        self.assertEqual(api.http_calls, 0)
        api.request('arm-b-sufficiency', 'generation', GENERATION)
        self.assertEqual(api.http_calls, 1)

    def test_changed_request_or_kind_is_refused_before_dispatch(self):
        self.add("stage-a")
        api = self.api()
        for kind, payload in (("count", COUNT), ("generation", {**GENERATION, "max_output_tokens": 9})):
            with self.assertRaises(c.ContinuationError):
                api.request("stage-a", kind, payload)
        self.assertEqual(api.http_calls, 0)

    def test_malformed_counts_model_identity_and_receipt_hashes_are_refused(self):
        for mutation in ("response", "operation", "count", "model"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as path:
                parent = Path(path)
                raw = response() if mutation != "count" else c.canonical({"object": "response.input_tokens", "input_tokens": 0})
                if mutation == "model":
                    raw = c.canonical({"model": "wrong", "status": "completed", "text": "Public", "usage": USAGE})
                operation = write_operation(parent, "public", "count" if mutation == "count" else "generation", GENERATION, raw)
                if mutation == "response":
                    (parent / "public-response.json").write_bytes(b"{}");
                if mutation == "operation":
                    (parent / "public-operation.json").write_bytes(b"{}")
                with self.assertRaises(c.ContinuationError):
                    c.ReplayIndex(parent, {"operations": {"public": operation}}, PILOT)

    def test_unreceived_failure_requires_explicit_fill_and_never_retries_same_stage(self):
        self.add("unknown-stage", raw=None, failure="transport_failed")
        api = self.api()
        with self.assertRaises(Error):
            api.request("unknown-stage", "generation", GENERATION)
        self.assertEqual(api.http_calls, 0)
        self.assertEqual(api.provenance["unknown-stage"]["mode"], "blocked")
        with self.assertRaises(c.ContinuationError):
            api.request("unknown-stage", "generation", GENERATION)
        fresh = self.root / "fresh"; fresh.mkdir()
        filled = c.ReplayAPI(PILOT, fresh, "unused-public-fixture", {"dependencies": {}}, None, self.index(), fill_unreceived=True)
        filled.request("unknown-stage", "generation", GENERATION)
        self.assertEqual(filled.http_calls, 1)
        self.assertEqual(filled.provenance["unknown-stage"]["prior_failure"], "transport_failed")

    def test_first_new_429_stops_dispatch_but_authenticated_reuse_remains_available(self):
        self.add("retained-stage")
        api = self.api()
        FakeAPI.failure = "http_status_429"
        with self.assertRaises(Error):
            api.request("new-stage", "generation", GENERATION)
        self.assertTrue(api.halted)
        with self.assertRaises(Error):
            api.request("another-stage", "generation", GENERATION)
        self.assertEqual(api.request("retained-stage", "generation", GENERATION), response())
        self.assertEqual(api.http_calls, 1)
        self.assertEqual(api.provenance["another-stage"]["mode"], "blocked")
        self.assertEqual(api.provenance["retained-stage"]["mode"], "retained")

    def test_count_429_also_stops_all_new_dispatches(self):
        api = self.api()
        FakeAPI.failure = "http_status_429"
        with self.assertRaises(Error):
            api.request("new-count", "count", COUNT)
        self.assertEqual(api.halt_reason, "first_new_http_429")
        with self.assertRaises(Error):
            api.request("new-generation", "generation", GENERATION)
        self.assertEqual(api.http_calls, 1)

    def test_captures_are_rechecked_after_token_wait_before_dispatch(self):
        checks = [0]
        class Guard:
            def reserve(self, _tokens):
                checks[0] = 1
                return 0
        api = self.api(guard=Guard())
        original_frozen = api.frozen
        def frozen():
            if checks[0]:
                raise c.ContinuationError("synthetic_capture_changed_during_wait")
            original_frozen()
        api.frozen = frozen
        with self.assertRaises(c.ContinuationError):
            api.request("new-stage", "generation", GENERATION)
        self.assertEqual(api.http_calls, 0)

    def test_private_publication_and_stage_capture_never_overwrite(self):
        path = self.output / "public.json"
        c.private_write(path, b"{}"); self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(c.ContinuationError):
            c.private_write(path, b"changed")
        self.assertEqual(path.read_bytes(), b"{}")
        self.add("retained-stage")
        api = self.api(); api.request("retained-stage", "generation", GENERATION)
        with self.assertRaises(c.ContinuationError):
            api.request("retained-stage", "generation", GENERATION)
        self.assertEqual((self.parent / "retained-stage-response.json").read_bytes(), response())

    def test_token_rate_guard_limits_wait_chunks_and_rolling_reservations(self):
        clock, waits = [0.0], []
        def sleep(value):
            waits.append(value); clock[0] += value
        guard = c.TokenRateGuard(limit=10, now=lambda: clock[0], sleep=sleep)
        self.assertEqual(guard.reserve(6), 0)
        self.assertEqual(guard.reserve(6), 60)
        self.assertTrue(all(0 < wait <= 30 for wait in waits))
        with self.assertRaises(c.ContinuationError):
            guard.reserve(11)

    def test_unknown_fallback_rows_keep_unknown_timing_and_usage_separate(self):
        self.add("retained-stage")
        api = self.api(); api.request("retained-stage", "generation", GENERATION)
        api.request("new-stage", "generation", GENERATION)
        rows = [{"case": "public-case", "arm": arm, "operational_complete": False, "qa": "unknown", "sufficiency": "unknown",
            "support": "unknown", "citation_support": "unknown", "tool_actions": 0} for arm in PILOT.ARMS]
        parent_report = {"usage": USAGE, "operations": self.operations, "held_input_tokens_including_unknown": 99,
            "held_output_tokens_including_unknown": 88, "unknown_generation_receipts": 1}
        provenance = {"parent_report_sha256": "0" * 64}
        c.private_write(self.output / "declaration.json", b"{}")
        result = c.terminal_report(api, rows, parent_report, provenance)
        self.assertEqual(result['usage_retained_captures'], USAGE)
        self.assertEqual(result['usage_new_receipts'], USAGE)
        self.assertEqual(result['usage_cumulative_observed']['input_tokens'], 10)
        self.assertEqual(result['prior_unknown_generation_receipts'], 1)
        self.assertEqual(result['paired_qa']['inspection']['unknown'], 1)
        self.assertTrue(all(summary['summary_creation_p95_seconds'] is None for summary in result['summaries'].values()))
        self.assertTrue(all('summary_creation_seconds' not in row for row in result['attempts']))

    def test_only_hash_verified_capture_imports_execute_and_live_modules_are_restored(self):
        capture = self.parent / 'source-capture'; capture.mkdir()
        source = ('import hashlib\nfrom pathlib import Path\nimport orientation_zoom\nCONFIG={"public":True}\n'
            'def pins():\n return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(__file__).parent.glob("*.py")}\n')
        for name in c.DEPENDENCIES:
            c.private_write(capture / name, source.encode() if name == 'evaluate_orientation_zoom.py' else b'MARKER="captured-public"\n')
        dependencies = {name: c.digest((capture / name).read_bytes()) for name in c.DEPENDENCIES}
        live = sys.modules.get('orientation_zoom')
        current = SimpleNamespace(MARKER='current-public'); sys.modules['orientation_zoom'] = current
        try:
            loaded = c.load_execution(self.parent, {'dependencies': dependencies, 'configuration': {'public': True}})
            self.assertEqual(loaded.orientation_zoom.MARKER, 'captured-public')
            self.assertIs(sys.modules['orientation_zoom'], current)
            self.assertFalse((capture / '__pycache__').exists())
            (capture / 'orientation_zoom.py').write_bytes(b'MARKER="changed-public"\n')
            with self.assertRaises(c.ContinuationError):
                c.load_execution(self.parent, {'dependencies': dependencies, 'configuration': {'public': True}})
        finally:
            if live is None:
                sys.modules.pop('orientation_zoom', None)
            else:
                sys.modules['orientation_zoom'] = live

    def test_strict_json_rejects_duplicate_and_nonfinite_metadata(self):
        for raw in (b'{"x":1,"x":2}', b'{"x":NaN}'):
            with self.assertRaises(c.ContinuationError):
                c.strict_json(raw)

    def test_preparation_copies_frozen_inputs_and_sources_without_overwriting(self):
        workspace = Path(c.__file__).resolve().parents[1] / '.build' / 'evaluation'
        with tempfile.TemporaryDirectory(dir=workspace) as path:
            root = Path(path)
            parent = root / 'parent'; parent.mkdir(mode=0o700)
            capture = parent / 'source-capture'; capture.mkdir(mode=0o700)
            dependencies = {}
            for name in c.DEPENDENCIES:
                raw = b'PUBLIC_SYNTHETIC_CAPTURE = True\n'
                c.private_write(capture / name, raw); dependencies[name] = c.digest(raw)
            protocol = root / 'public-protocol.py'; c.private_write(protocol, b'PUBLIC_PROTOCOL = True\n')
            inputs, scorer = b'{"cases":[]}', b'{"cases":[]}'
            declaration = {'dependencies': dependencies, 'inputs_sha256': c.digest(inputs), 'scorer_sha256': c.digest(scorer),
                'source_sha256': '0' * 64, 'official_protocol_sha256': c.digest(protocol.read_bytes()),
                'configuration': {key: 10 for key in ('maximum_http_calls', 'maximum_generation_calls',
                    'maximum_observed_input_tokens', 'maximum_observed_output_tokens')}}
            c.private_write(parent / 'inputs.json', inputs); c.private_write(parent / 'scorer.json', scorer)
            c.private_write(parent / 'declaration.json', c.canonical(declaration))
            report = {'status': 'terminal', 'operations': {}, 'declaration_sha256': c.digest(c.canonical(declaration))}
            c.private_write(parent / 'report.json', c.canonical(report))
            validated, declared = c.validate_parent(parent, c.digest(c.canonical(report)))
            output = root / 'continued'
            provenance = c.prepare(parent, output, protocol, validated, declared, fill_unreceived=True)
            self.assertEqual((output / 'inputs.json').read_bytes(), inputs)
            self.assertEqual((output / 'declaration.json').read_bytes(), c.canonical(declaration))
            self.assertEqual((output / 'continuation-provenance.json').read_bytes(), c.canonical(provenance))
            self.assertTrue(provenance['fill_unreceived_authorized'])
            self.assertFalse(provenance['execute_authorized'])
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600 for path in output.rglob('*') if path.is_file()))
            with self.assertRaises(c.ContinuationError):
                c.prepare(parent, output, protocol, validated, declared)
            self.assertEqual((parent / 'report.json').read_bytes(), c.canonical(report))


if __name__ == '__main__':
    unittest.main()
