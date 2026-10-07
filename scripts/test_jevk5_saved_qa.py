#!/usr/bin/env python3
"""Public synthetic saved-answer/MCP contracts; no real server calls."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import jevk5_saved_qa as j


def payload(choice="yes"):
    probs = {"yes": 0.8 if choice == "yes" else 0.2, "no": 0.2 if choice == "yes" else 0.8}
    return {"answer": {"type": "choice", "choice": choice, "probabilities": probs,
            "confidence": 0.8, "input_tokens": 12}, "input_tokens": 12, "model": dict(j.MODEL),
            "latency_ms": 5, "engine_ms": 4, "cache": {"hit": False, "policy": "identical-consecutive"}}


def tool(value):
    return {"structuredContent": value, "content": [{"type": "text", "text": json.dumps(value)}]}


def saved_response(text="Public answer"):
    return j.canonical({"model": "gpt-6.1-sol", "status": "completed", "error": None,
        "output": [{"type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": text}]}]})


FAKE_SERVER = """
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    if request['method'] == 'initialize':
        result = {'protocolVersion':'2025-11-25','capabilities':{'tools':{}}}
    elif request['method'] == 'tools/list':
        result = {'tools':[{'name':'jevk5_status'},{'name':'jevk5_decide'}]}
    else:
        result = {'content':[{'type':'text','text':'public fixture'}]}
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}), flush=True)
"""


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_qa_adapter_contains_only_exact_rubric_and_fixed_choice(self):
        request = j.qa_request("Public unchanged rubric\nCandidate fixture")
        self.assertEqual(request["state"], {"evaluation_prompt": "Public unchanged rubric\nCandidate fixture"})
        self.assertEqual(set(request), {"state", "question"})
        self.assertEqual(request["question"]["criteria"], ["yes", "no"])
        self.assertEqual(request["question"]["instructions"], j.CHOICE_INSTRUCTIONS)
        for invalid in ("", 1, None):
            with self.assertRaises(j.SavedQAError):
                j.qa_request(invalid)

    def test_controls_cover_known_correct_wrong_partial_update_and_abstention(self):
        calls = []
        def prompt(*args):
            calls.append(args)
            return [{"content": "Public unchanged rubric " + str(len(calls))}]
        controls = j.controls(SimpleNamespace(official_qa_messages=prompt), self.root / "protocol")
        self.assertEqual(len(calls), 6)
        self.assertEqual([r["expected"] for r in controls], ["yes", "no", "no", "no", "yes", "no"])
        self.assertEqual([r["name"] for r in controls], ["correct", "wrong", "partial", "knowledge_update", "valid_abstention", "invalid_abstention"])
        self.assertEqual(calls[3][0], "knowledge-update")
        self.assertTrue(calls[4][4]); self.assertTrue(calls[5][4])

    def test_duplicate_keys_nonfinite_and_private_file_no_clobber(self):
        for raw in ('{"a":1,"a":2}', '{"a":NaN}'):
            with self.assertRaises(j.SavedQAError):
                j.strict_json(raw)
        path = self.root / "capture"
        j.private_write(path, b"Public fixture")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(j.SavedQAError):
            j.private_write(path, b"Replacement")
        self.assertEqual(path.read_bytes(), b"Public fixture")

    def test_read_refuses_symlink_and_oversized_file(self):
        original = self.root / "original"; original.write_bytes(b"public")
        link = self.root / "link"; link.symlink_to(original)
        with self.assertRaises(j.SavedQAError):
            j.read_file(link)
        with self.assertRaises(j.SavedQAError):
            j.read_file(original, 1)

    def test_saved_response_preserves_exact_text_and_rejects_incomplete(self):
        self.assertEqual(j.response_text(saved_response("Public café\nsecond line")), "Public café\nsecond line")
        for field, value in (("status", "incomplete"), ("model", "other-model"), ("error", {})):
            response = j.strict_json(saved_response()); response[field] = value
            with self.assertRaises(j.SavedQAError):
                j.response_text(j.canonical(response))

    def test_saved_operation_authenticates_request_response_and_receipt(self):
        name = "public-stage"
        request = j.canonical({"input": "Public request"})
        response = saved_response()
        receipt = {"name": name, "kind": "generation", "dispatched": True, "received": True,
                   "request_sha256": j.digest(request), "response_sha256": j.digest(response)}
        for suffix, raw in (("request", request), ("response", response), ("operation", j.canonical(receipt))):
            j.private_write(self.root / f"{name}-{suffix}.json", raw)
        report = {"operations": {name: receipt}}
        self.assertEqual(j.authenticate_operation(self.root, report, name)[0], "Public answer")
        (self.root / f"{name}-response.json").write_bytes(saved_response("Changed"))
        with self.assertRaisesRegex(j.SavedQAError, "saved_response_mismatch"):
            j.authenticate_operation(self.root, report, name)

    def test_matching_structured_and_text_payload_required(self):
        self.assertEqual(j.tool_payload(tool(payload())), payload())
        bad = tool(payload()); bad["content"][0]["text"] = json.dumps(payload("no"))
        with self.assertRaisesRegex(j.SavedQAError, "mcp_payload_mismatch"):
            j.tool_payload(bad)
        with self.assertRaisesRegex(j.SavedQAError, "mcp_tool_failed"):
            j.tool_payload({"isError": True, "content": []})

    def test_decision_keeps_full_probabilities_and_metadata(self):
        result = j.validate_decision(tool(payload()))
        self.assertEqual(result["probabilities"], {"yes": 0.8, "no": 0.2})
        self.assertEqual(result["model"], j.MODEL)
        self.assertEqual(result["confidence"], 0.8)
        self.assertEqual(result["input_tokens"], 12)

    def test_decision_rejects_wrong_model_distribution_confidence_or_truncation(self):
        edits = (
            lambda p: p["model"].update(sha256="0" * 64),
            lambda p: p["answer"].update(probabilities={"yes": 0.7, "no": 0.2}),
            lambda p: p["answer"].update(probabilities={"yes": float("nan"), "no": 0.2}),
            lambda p: p["answer"].update(confidence=0.9),
            lambda p: p["answer"].update(choice="no"),
            lambda p: p["answer"].update(input_tokens=8192),
            lambda p: p.update(input_tokens=True),
            lambda p: p.update(engine_ms=-1),
            lambda p: p["cache"].update(hit="false"))
        for edit in edits:
            value = payload(); edit(value)
            with self.assertRaises(j.SavedQAError):
                j.validate_decision({"structuredContent": value})

    def test_status_requires_ready_unpaused_pinned_model(self):
        value = {"model": dict(j.MODEL), "ready": True, "paused": False}
        self.assertEqual(j.validate_status(tool(value))["model"], j.MODEL)
        value["paused"] = True
        with self.assertRaisesRegex(j.SavedQAError, "jev_not_ready"):
            j.validate_status(tool(value))

    def start_fake(self, script):
        process = subprocess.Popen([sys.executable, "-u", "-c", script], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        client = j.StdioMCP(self.root, process=process, timeout=1)
        self.addCleanup(client.close)
        return client

    def test_stdio_newline_roundtrip_and_private_receipts(self):
        client = self.start_fake(FAKE_SERVER)
        response = client.call("initialize", {"public": "fixture"}, "public-init")
        self.assertEqual(response["protocolVersion"], "2025-11-25")
        request = j.strict_json((self.root / "public-init-request.json").read_bytes())
        self.assertEqual(request["id"], 1)
        receipt = j.strict_json((self.root / "public-init-operation.json").read_bytes())
        self.assertTrue(receipt["dispatched"]); self.assertTrue(receipt["received"])
        self.assertEqual(receipt["response_sha256"], j.digest((self.root / "public-init-response.json").read_bytes()))

    def test_stdio_wrong_id_is_captured_and_halts_without_retry(self):
        client = self.start_fake("import json,sys\nr=json.loads(sys.stdin.readline());print(json.dumps({'jsonrpc':'2.0','id':999,'result':{}}),flush=True)")
        with self.assertRaisesRegex(j.SavedQAError, "mcp_response_identity_invalid"):
            client.call("tools/list", {}, "public-wrong-id")
        self.assertEqual(len(client.operations), 1)
        self.assertTrue(client.operations[0]["received"])

    def test_stdio_rejects_oversized_frame_and_deadline(self):
        client = self.start_fake("import sys,time\nsys.stdin.readline();print('x'*1000,flush=True);time.sleep(2)")
        with patch.object(j, "MAX_FRAME", 100), self.assertRaisesRegex(j.SavedQAError, "mcp_frame_bound_exceeded"):
            client.call("tools/list", {}, "public-big")

    def execution_fixture(self):
        rows = [{"ordinal": index, "case": f"public-{index // 3}", "arm": j.ARMS[index % 3],
                 "sol_qa": "yes" if index < 39 else "unknown", "answer_available": index < 43,
                 "contaminated_abstention": index < 15, "jev_qa": "unknown",
                 "status": "prepared" if index < 43 else "no_saved_answer"} for index in range(90)]
        request = j.qa_request("Public saved rubric")
        requests = [{"name": f"saved-{index:03d}", "ordinal": index, "arguments": copy.deepcopy(request)} for index in range(43)]
        for row in rows[:43]:
            row["arguments_sha256"] = j.digest(j.canonical(request))
        controls = [{"name": f"public-{index}", "expected": "yes", "arguments": j.qa_request("Public control rubric")} for index in range(6)]
        declaration = {"execute_authorized": True, "maximum_decision_calls": 49, "executable_sha256": j.digest(b"public exe"),
            "requests_sha256": j.digest(j.canonical(requests)), "rows_sha256": j.digest(j.canonical(rows)),
            "controls_sha256": j.digest(j.canonical(controls))}
        for name, value in (("declaration", declaration), ("prepared-requests", requests), ("prepared-rows", rows), ("controls", controls)):
            j.private_write(self.root / (name + ".json"), j.canonical(value))
        return declaration, rows, requests, controls

    def run_fixture(self, *, wrong_control=False, fail_grade=False):
        declaration, rows, requests, controls = self.execution_fixture()
        class FakeClient:
            def __init__(self, output):
                self.calls = []; self.operations = []; self.closed = False
            def connect(self):
                return {"ready": True}
            def decide(self, arguments, name):
                self.calls.append(name)
                if fail_grade and name.startswith("saved"):
                    raise j.SavedQAError("mcp_deadline")
                return j.validate_decision(tool(payload("no" if wrong_control and name == "control-public-0" else "yes")))
            def close(self):
                self.closed = True
        created = []
        def factory(output):
            client = FakeClient(output); created.append(client); return client
        original_read = j.read_file
        def read(path, limit=j.MAX_FILE):
            return b"public exe" if path == Path(j.COMMAND[0]) else original_read(path, limit)
        with patch.object(j, "read_file", side_effect=read), patch.object(j, "frozen_execution"):
            result = j.execute(self.root, declaration, rows, requests, controls, factory)
        return result, created[0]

    def test_six_controls_gate_every_saved_grade(self):
        result, client = self.run_fixture(wrong_control=True)
        self.assertEqual(len(client.calls), 6)
        self.assertFalse(result["controls_passed"])
        self.assertEqual(result["completed_grades"], 0)
        self.assertEqual(result["halt_reason"], "public_controls_failed")
        self.assertEqual(result["original_attempts"], 90)
        self.assertTrue(client.closed)

    def test_success_has_exactly_49_decisions_and_preserves_denominators(self):
        result, client = self.run_fixture()
        self.assertEqual(len(client.calls), 49)
        self.assertEqual(result["completed_grades"], 43)
        self.assertEqual(result["original_attempts"], 90)
        self.assertEqual(result["matched_sol_jev_triples"]["histories"], 13)
        self.assertEqual(result["matched_answerable_triples"]["histories"], 8)
        self.assertEqual(sum(s["sol_comparable"] for s in result["summaries"].values()), 39)
        self.assertEqual(sum(s["jev_unknown"] for s in result["summaries"].values()), 47)
        self.assertFalse(result["representative_accuracy_established"])
        self.assertFalse(result["abstention_cue_contamination_repaired"])

    def test_first_failed_saved_call_halts_and_is_never_retried(self):
        result, client = self.run_fixture(fail_grade=True)
        self.assertEqual(len(client.calls), 7)
        self.assertEqual(result["completed_grades"], 0)
        self.assertEqual(result["halt_reason"], "mcp_deadline")
        self.assertTrue(client.closed)

    def test_offline_declaration_cannot_execute(self):
        declaration, rows, requests, controls = self.execution_fixture()
        declaration["execute_authorized"] = False
        with self.assertRaisesRegex(j.SavedQAError, "execute_not_authorized"):
            j.execute(self.root, declaration, rows, requests, controls, lambda _: self.fail("process started"))

    def test_in_memory_request_tampering_refused_before_process(self):
        declaration, rows, requests, controls = self.execution_fixture()
        requests[0]["arguments"]["state"]["evaluation_prompt"] = "Changed public rubric"
        with self.assertRaisesRegex(j.SavedQAError, "prepared_artifacts_changed"):
            j.execute(self.root, declaration, rows, requests, controls, lambda _: self.fail("process started"))

    def test_frozen_source_protocol_dependency_and_contract_guard(self):
        capture = self.root / "source-capture"; capture.mkdir()
        controller = j.read_file(Path(j.__file__).resolve())
        j.private_write(capture / "jevk5_saved_qa.py", controller)
        protocol = b"Public protocol source"
        j.private_write(self.root / "qa-protocol.py", protocol)
        dependencies = {}
        for name in j.DEPENDENCIES:
            raw = b"Public dependency source"
            dependencies[name] = j.digest(raw)
            j.private_write(capture / name, raw)
        declaration = {"version": j.VERSION, "command": list(j.COMMAND), "model": dict(j.MODEL),
            "controller_sha256": j.digest(controller), "protocol_sha256": j.digest(protocol),
            "original_dependencies": dependencies}
        with patch.object(j, "PROTOCOL_SHA256", j.digest(protocol)):
            j.frozen_execution(self.root, declaration)
            declaration["command"] = ["different-command"]
            with self.assertRaisesRegex(j.SavedQAError, "execution_contract_changed"):
                j.frozen_execution(self.root, declaration)
            declaration["command"] = list(j.COMMAND)
            (capture / "orientation_zoom.py").write_bytes(b"Changed dependency")
            with self.assertRaisesRegex(j.SavedQAError, "execution_dependency_changed"):
                j.frozen_execution(self.root, declaration)


if __name__ == "__main__":
    unittest.main()
