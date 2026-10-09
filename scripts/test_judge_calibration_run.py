#!/usr/bin/env python3
"""Synthetic contracts for the P4 judge-calibration runner.

Fake transports only: no network, gcloud, MCP process, model server or private data.
"""
from __future__ import annotations

from collections import Counter
import copy
from decimal import Decimal
import hashlib
import io
import json
import os
from pathlib import Path
import socket
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import judge_calibration as jc  # noqa: E402
import judge_calibration_run as run  # noqa: E402
import jevk5_saved_qa as jev  # noqa: E402
import local_longmemeval_qa as qa  # noqa: E402
import vertex_anthropic as vertex  # noqa: E402

TEMPLATES = jc.ROOT / "scripts" / "judge_calibration_declarations"
PROMPT_SET_SHA256 = "1cce15660c8a730df03f5654926356715842e5c5bdbb64709a4a1c6cd1990221"
VERDICT_SHA256 = "85fa445ad2cda3f103a89828f126834795beffafce991bf676b90531ffc2b40c"
SUFFICIENCY_SHA256 = "c604485853f65670fa54599aceb06f5d152a8798b03dc518cca6de73ec76b857"
REPLY_SCHEMA_SHA256 = "089f6abbd4ee62321396ed07e5929cfe30394cfe04f6c44e9512f60bc3fca549"
PROMPT_SET_V3_SHA256 = "b6bcccc27ac4d16fc9d5cb550d3201c3f56f44a251190087af740180fafd317c"
REPLY_INSTRUCTIONS_SHA256 = "8ecc9d7d83ede598616631604f3ef92f89c609c507a59c5ea9f1c2097252cbcb"
VERDICT_LINE = 'Reply with only a JSON object, either {"answer": "yes"} or {"answer": "no"}, and no other text.'
SUFFICIENCY_LINE = ('Reply with only a JSON object, either {"sufficiency": "sufficient"} or '
                    '{"sufficiency": "insufficient"}, and no other text.')
KEY_SENTINELS = ("RUNSENTINEL", "ARMSENTINEL", "qwen-local-qa", "sol-qa", "gpt-6.1-sol", jc.QWEN_MODEL,
                 "q00000a1", "q00000a2_abs", "accepted", "abstention_stratum")
EXECUTABLE_SHA = "e" * 64


def fake_prompt(task, question, answer, response, abstention=False):
    """Same signature as the upstream get_anscheck_prompt; synthetic text only."""
    return f"UPSTREAM[{task}] Q={question} REF={answer} RESP={response} ABS={abstention}. Answer yes or no only."


def synthetic_candidates():
    out = []
    specs = (("q00000a1", False, "multi-session", jc.QWEN_MODEL), ("q00000a2_abs", True, "single-session-user",
                                                                     jc.SOL_MODEL),
             ("q00000a3", False, "temporal-reasoning", jc.QWEN_MODEL))
    for index, (question_id, abstention, question_type, model) in enumerate(specs):
        answer = f"Synthetic answer {index} ANSWERTOKEN{index}"
        candidate = jc.new_candidate(run="RUNSENTINEL", run_family="synthetic", arm="ARMSENTINEL",
                                     question_id=question_id, question_type=question_type, abstention=abstention,
                                     answer_model=model, operational_complete=True,
                                     answer_sha256=hashlib.sha256(answer.encode()).hexdigest())
        candidate.update(answer_text=answer, answer_verified=True, question=f"Synthetic question {index}?",
                         question_date="2023/05/01", reference=f"Synthetic reference {index}.",
                         reference_check=True,
                         evidence=[{"source_id": f"{question_id}-s0001-m0002", "order": (1, 2),
                                    "date": "2023/04/01", "role": "user", "text": f"Synthetic evidence {index}.",
                                    "partial": index == 2}],
                         evidence_retention="text", evidence_verified=True,
                         all_annotated_delivered=None if abstention else True,
                         prior_labels={"qwen-local-qa": {"verdict": "accept"}, "sol-qa": {"verdict": "reject"}})
        candidate["scrub_ids"].update({question_id, f"{question_id}-s0001-m0002"})
        candidate["eligible"] = jc.eligibility(candidate) is None
        candidate["stratum"] = jc.stratum_of(candidate)
        out.append(candidate)
    return out


def fill(judge, manifest, *, replicates=3, template=None, **overrides):
    document = json.loads((TEMPLATES / (template or f"{judge}.template.json")).read_text())
    document["authorization"].update(authorized_by="Synthetic Tester", authorized_on="2026-10-08")
    document["calibration_set"] = {"set_id": manifest["set_id"], "items_sha256": manifest["items_sha256"],
                                   "item_count": manifest["item_count"]}
    document["execution"]["replicates"] = replicates
    document["outputs"]["labels_path"] = f".build/judge-calibration/labels-{judge}.json"
    planned = jc.planned_requests(manifest["item_count"], replicates)
    if judge in run.VERTEX_JUDGES:
        document["pricing"].update(input_usd_per_million_tokens="5", output_usd_per_million_tokens="25",
                                   source="synthetic test value", verified_on="2026-10-08")
        document["budget"] = {"spending_cap_usd": "10", "max_generation_requests": planned,
                              "max_count_requests": manifest["item_count"] * 2}
    else:
        document["request_limits"]["max_requests"] = planned
    if judge == "jevk5":
        document["provider"]["executable_sha256"] = EXECUTABLE_SHA
    for path, value in overrides.items():
        target = document
        keys = path.split(".")
        for key in keys[:-1]:
            target = target[key]
        target[keys[-1]] = value
    return document


def vertex_reply(text, model="claude-opus-5-5", input_tokens=100, output_tokens=2, stop_reason="end_turn",
                 content=None, thinking_tokens=None):
    usage = {"input_tokens": input_tokens, "output_tokens": output_tokens}
    if thinking_tokens is not None:
        usage["output_tokens_details"] = {"thinking_tokens": thinking_tokens}
    return vertex.canonical({"id": "msg_synthetic", "type": "message", "role": "assistant", "model": model,
                             "content": content if content is not None else [{"type": "text", "text": text}],
                             "stop_reason": stop_reason, "usage": usage})


class FakeVertex:
    """Replies with bare text to v1 bodies and with schema-shaped JSON to bodies carrying output_config.format
    or the v3 verdict reply-format line."""

    def __init__(self, model="claude-opus-5-5", verdict=None, sufficiency='{"sufficiency": "sufficient"}',
                 fail_at=None, count=100, echo_model=None, structured_verdict='{"answer": "yes"}',
                 instructed_verdict='{"answer": "yes"}'):
        self.model, self.verdict, self.sufficiency = model, verdict, sufficiency
        self.structured_verdict, self.instructed_verdict = structured_verdict, instructed_verdict
        self.fail_at, self.count_value, self.echo_model = fail_at, count, echo_model or model
        self.bodies, self.urls, self.generations, self.generation_bodies = [], [], 0, []

    def __call__(self, url, body, token):
        assert token == "synthetic-token"
        self.urls.append(url)
        self.bodies.append(copy.deepcopy(body))
        if url == vertex.count_url():
            return vertex.canonical({"input_tokens": self.count_value})
        assert url == vertex.generation_url(model=self.model)
        if body == {}:
            raise vertex.VertexError("http_status_400")
        self.generations += 1
        self.generation_bodies.append(copy.deepcopy(body))
        if self.fail_at is not None and self.generations == self.fail_at:
            raise vertex.VertexError("http_status_429")
        if body.get("system") == VERDICT_LINE:
            text = self.instructed_verdict
        elif "system" in body:
            text = self.sufficiency
        elif self.verdict is not None:
            text = self.verdict
        else:
            text = self.structured_verdict if "output_config" in body else "Yes."
        return vertex_reply(text, self.echo_model, thinking_tokens=0 if "output_config" in body else None)


class FakeQwen:
    def __init__(self, verdict="no", sufficiency='{"sufficiency": "insufficient"}', model=None):
        self.verdict, self.sufficiency, self.model = verdict, sufficiency, model or jc.QWEN_MODEL
        self.bodies = []

    def __call__(self, url, raw):
        assert url == jc.QWEN_ENDPOINT
        body = json.loads(raw)
        self.bodies.append(body)
        text = self.sufficiency if body["messages"][0]["role"] == "system" else self.verdict
        return json.dumps({"model": self.model, "choices": [{"index": 0, "finish_reason": "stop",
                                                             "message": {"role": "assistant", "content": text}}],
                           "usage": {"prompt_tokens": 50, "completion_tokens": 3, "total_tokens": 53}}).encode()


class FakeJevClient:
    instances = []

    def __init__(self, directory, choice="yes"):
        self.directory, self.choice, self.calls, self.closed = directory, choice, [], False
        FakeJevClient.instances.append(self)

    def connect(self):
        return {"ready": True, "model": dict(jev.MODEL)}

    def call(self, method, params, name):
        assert method == "tools/call" and params["name"] == "jevk5_decide"
        self.calls.append(copy.deepcopy(params["arguments"]))
        probabilities = {"yes": 0.8, "no": 0.2} if self.choice == "yes" else {"yes": 0.3, "no": 0.7}
        payload = {"model": dict(jev.MODEL), "input_tokens": 40, "latency_ms": 1.0, "engine_ms": 1.0,
                   "cache": {"hit": len(self.calls) > 2},
                   "answer": {"type": "choice", "choice": self.choice, "probabilities": probabilities,
                              "confidence": probabilities[self.choice], "input_tokens": 40}}
        return {"structuredContent": payload, "content": [{"type": "text", "text": json.dumps(payload)}]}

    def close(self):
        self.closed = True


def no_network():
    """Patches that make any network, gcloud, MCP or model-server attempt fail loudly."""
    def refuse(*_args, **_kwargs):
        raise AssertionError("network_or_model_call_attempted")
    return [patch.object(socket.socket, "connect", refuse), patch.object(socket, "create_connection", refuse),
            patch.object(vertex, "post", refuse), patch.object(vertex.AccessTokens, "__call__", refuse),
            patch.object(run, "qwen_post", refuse), patch.object(qa, "call_local", refuse),
            patch.object(jev.StdioMCP, "__init__", refuse), patch.object(run.QwenTransport, "send", refuse),
            patch.object(run.VertexTransport, "send", refuse), patch.object(run.JevTransport, "send", refuse)]


class Contracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        (self.root / ".build" / "judge-calibration").mkdir(parents=True)
        self.set_dir = self.root / ".build" / "judge-calibration" / "set"
        self.manifest = jc.assemble(synthetic_candidates(), "seed", self.set_dir, per_stratum=3, minimum=3)
        FakeJevClient.instances = []

    def tearDown(self):
        self.temporary.cleanup()

    def declaration(self, judge, **kwargs):
        path = self.root / f"declaration-{judge}-{len(list(self.root.glob('declaration-*')))}.json"
        path.write_text(json.dumps(fill(judge, self.manifest, **kwargs)))
        return path

    def transport(self, judge, fake=None, **kwargs):
        if judge in run.VERTEX_JUDGES:
            fake = fake or FakeVertex(model=run.VERTEX_JUDGES[judge])
            return run.VertexTransport(run.VERTEX_JUDGES[judge], fake, lambda: "synthetic-token"), fake
        if judge == "qwen-local":
            fake = fake or FakeQwen()
            return run.QwenTransport(fake), fake
        transport = run.JevTransport(EXECUTABLE_SHA, lambda directory: FakeJevClient(directory, **kwargs),
                                     lambda: EXECUTABLE_SHA)
        return transport, None

    def execute(self, judge, declaration, output="run", transport=None, resume=False):
        transport = transport or self.transport(judge)[0]
        return run.execute(self.set_dir, declaration, self.root / ".build" / "judge-calibration" / output,
                           fake_prompt, resume=resume, root=self.root, transport=transport, git_ignore=False)

    # ------------------------------------------------------------------ prompts

    def test_prompt_hashes_are_pinned_in_code_and_templates(self):
        self.assertEqual(jc.judge_prompt_sha256(), PROMPT_SET_SHA256)
        self.assertEqual(jc.verdict_prompt_sha256(), VERDICT_SHA256)
        self.assertEqual(jc.sufficiency_prompt_sha256(), SUFFICIENCY_SHA256)
        self.assertEqual(jc.UPSTREAM_QA_PROTOCOL_SHA256, qa.PROTOCOL_SHA256)
        self.assertEqual(jc.UPSTREAM_QA_PROTOCOL_SHA256, jev.PROTOCOL_SHA256)
        self.assertEqual(jc.JEVK5_VERDICT_INSTRUCTIONS, jev.CHOICE_INSTRUCTIONS)
        for judge in run.JUDGES:
            template = json.loads((TEMPLATES / f"{judge}.template.json").read_text())
            self.assertEqual((template["prompts"]["sha256"], template["prompts"]["verdict_sha256"],
                              template["prompts"]["sufficiency_sha256"]),
                             (PROMPT_SET_SHA256, VERDICT_SHA256, SUFFICIENCY_SHA256), judge)
        filled = fill("qwen-local", self.manifest)
        self.assertEqual(jc.check_declaration(filled, self.set_dir), [])
        with patch.dict(jc.SUFFICIENCY_PROMPT, system=jc.SUFFICIENCY_PROMPT["system"] + " Changed."):
            self.assertIn("prompt_hash", jc.check_declaration(filled, self.set_dir))
            with self.assertRaisesRegex(jc.CalibrationError, "declaration_incomplete"):
                self.execute("qwen-local", self.declaration("qwen-local"))

    def test_upstream_protocol_must_match_its_pin(self):
        path = self.root / "evaluate_qa.py"
        path.write_bytes(b"def get_anscheck_prompt(task, question, answer, response, abstention=False):\n"
                         b"    return 'x'\n")
        with self.assertRaisesRegex(jc.CalibrationError, "upstream_protocol_protocol_pin_mismatch"):
            jc.load_upstream_prompt_function(path)
        with self.assertRaisesRegex(jc.CalibrationError, "upstream_protocol_file_read_failed"):
            jc.load_upstream_prompt_function(self.root / "missing.py")

    def test_requests_render_from_blinded_item_fields_only(self):
        (self.set_dir / "key.json").unlink()  # the runner never needs the key
        for judge in run.JUDGES:
            transport, fake = self.transport(judge)
            report = self.execute(judge, self.declaration(judge, replicates=1), output=f"blind-{judge}",
                                  transport=transport)
            self.assertTrue(report["complete"], judge)
            bodies = fake.bodies if fake is not None else FakeJevClient.instances[-1].calls
            sent = json.dumps([{key: value for key, value in body.items() if key != "model"} for body in bodies])
            for sentinel in KEY_SENTINELS:
                self.assertNotIn(sentinel, sent, (judge, sentinel))
            self.assertNotIn("item-00", sent)
            if judge in run.VERTEX_JUDGES:
                bodies = fake.generation_bodies  # count and probe bodies were checked above
            sufficiency = [body for body in bodies if "UPSTREAM[" not in json.dumps(body)]
            self.assertEqual(len(sufficiency), len(bodies) // 2, judge)
            self.assertNotIn("ANSWERTOKEN", json.dumps(sufficiency), judge)
            self.assertIn("ANSWERTOKEN", sent)
            for body in bodies:
                self.assertTrue({"temperature", "top_p", "top_k", "seed"}.isdisjoint(body)
                                or judge == "qwen-local", judge)
                if judge == "vertex-opus" or judge == "jevk5":
                    self.assertNotIn("thinking", body, judge)

    def test_sufficiency_rendering_omits_answer_and_verdict_uses_upstream_prompt(self):
        item = json.loads((self.set_dir / "items.json").read_text())["items"][0]
        sufficiency = jc.judge_messages(item, "sufficiency")
        self.assertEqual(sufficiency[0], {"role": "system", "content": jc.SUFFICIENCY_PROMPT["system"]})
        self.assertNotIn(item["answer"], json.dumps(sufficiency))
        self.assertIn("[E1]", sufficiency[1]["content"])
        verdict = jc.judge_messages(item, "verdict", fake_prompt)
        self.assertEqual(verdict, [{"role": "user", "content": fake_prompt(
            item["question_type"], item["question"], item["reference"], item["answer"],
            abstention=item["abstention"])}])
        with self.assertRaisesRegex(jc.CalibrationError, "upstream_prompt_function_required"):
            jc.judge_messages(item, "verdict")

    # ------------------------------------------------------------------ gates

    def test_dry_run_makes_zero_network_calls_for_every_judge(self):
        patches = no_network()
        for patcher in patches:
            patcher.start()
        try:
            for judge in run.JUDGES:
                output = self.root / ".build" / "judge-calibration" / f"dry-{judge}"
                report = run.dry_run(self.set_dir, self.declaration(judge), output, fake_prompt, root=self.root,
                                     git_ignore=False)
                self.assertEqual((report["network_calls"], report["files_written"]), (0, 0))
                self.assertEqual(report["items"], 3)
                self.assertEqual(report["requests"], 3 * 2 * 3)
                self.assertEqual(report["unique_requests"], 6)
                self.assertTrue(report["declaration_complete"], report["declaration_problems"])
                self.assertEqual(report["destination"], "fresh")
                self.assertEqual(report["count_requests_needed"], 6 if judge in run.VERTEX_JUDGES else 0)
                self.assertFalse(output.exists())
                template = TEMPLATES / f"{judge}.template.json"
                unfilled = run.dry_run(self.set_dir, template, output, fake_prompt, root=self.root,
                                       git_ignore=False)
                self.assertFalse(unfilled["declaration_complete"])
                self.assertIn("unfilled:outputs.labels_path", unfilled["declaration_problems"])
        finally:
            for patcher in patches:
                patcher.stop()

    def test_cli_dry_run_and_execute_gate(self):
        protocol = self.root / "protocol.py"
        protocol.write_text("synthetic")
        output = jc.ROOT / ".build" / "judge-calibration" / f"test-cli-{os.getpid()}"
        patches = no_network() + [
            patch.object(jc, "load_upstream_prompt_function", lambda path: fake_prompt),
            patch.object(run, "make_transport", side_effect=AssertionError("transport_constructed")),
            patch.object(run, "execute", side_effect=AssertionError("execute_reached"))]
        for patcher in patches:
            patcher.start()
        try:
            for judge in run.JUDGES:
                stdout = io.StringIO()
                with patch("sys.stdout", stdout):
                    code = run.main(["--set", str(self.set_dir), "--declaration", str(TEMPLATES / f"{judge}.template.json"),
                                     "--output", str(output), "--protocol", str(protocol)])
                self.assertEqual(code, 0)
                printed = json.loads(stdout.getvalue())
                self.assertEqual((printed["mode"], printed["network_calls"]), ("dry-run", 0))
                stdout = io.StringIO()
                with patch("sys.stdout", stdout):
                    code = run.main(["--set", str(self.set_dir), "--declaration", str(TEMPLATES / f"{judge}.template.json"),
                                     "--output", str(output), "--protocol", str(protocol), "--execute"])
                self.assertEqual(code, 2)
                self.assertFalse(json.loads(stdout.getvalue())["executed"])
            stdout = io.StringIO()
            with patch("sys.stdout", stdout):
                code = run.main(["--set", str(self.set_dir), "--declaration", str(self.declaration("jevk5")),
                                 "--output", str(output), "--protocol", str(protocol), "--resume"])
            self.assertEqual((code, json.loads(stdout.getvalue())["error"]), (1, "resume_requires_execute"))
            self.assertFalse(output.exists())
        finally:
            for patcher in patches:
                patcher.stop()

    # ------------------------------------------------------------------ cost and stops

    def test_vertex_cost_cap_refuses_before_any_generation(self):
        for judge in run.VERTEX_JUDGES:
            transport, fake = self.transport(judge)
            # 18 generations at 100 counted input tokens and the declared output cap (512 or 2,048 tokens)
            # reserved: at least 18 x 13,300 micro-USD, above the 0.1 USD cap.
            report = self.execute(judge, self.declaration(judge, **{"budget.spending_cap_usd": "0.1"}),
                                  output=f"cap-{judge}", transport=transport)
            self.assertEqual(report["halt_reason"], "projected_cost_exceeds_cap")
            self.assertEqual(fake.generations, 0)
            self.assertEqual(report["session_calls"], {"probe": 1, "count": 6})
            self.assertFalse(report["complete"])
            self.assertFalse((self.root / f".build/judge-calibration/labels-{judge}.json").exists())

    def test_vertex_per_generation_cost_check(self):
        declaration = fill("vertex-opus", self.manifest)
        transport, fake = self.transport("vertex-opus")
        manifest, items = run.load_set(self.set_dir)
        plan = run.build_plan(items, declaration, fake_prompt)
        for entry in plan:
            entry["count_sha256"] = jc.sha256_bytes(jc.canonical(entry["count_body"]))
            entry["count_stem"] = f"count-{entry['item_id']}-{entry['stage']}"
        captures_dir = self.root / ".build" / "captures"
        jc.make_private_directory(captures_dir, fresh=True)
        prior = {"latest": {}, "counts": {}, "generation_intents": 0, "count_intents": 0, "reserved_microusd": 0}
        session = run.Session(declaration, plan, transport, run.Captures(captures_dir), prior)
        session.reserved = session.cap - 1000
        with self.assertRaisesRegex(run.Halt, "cost_cap_exceeded"):
            session.generate(plan[0], Counter())
        self.assertEqual(fake.generations, 0)

    def test_stop_on_first_http_429_then_authenticated_resume(self):
        # An exactly sized request budget leaves no room to resend a failed request.
        tight = self.declaration("vertex-sonnet")
        transport, _ = self.transport("vertex-sonnet", FakeVertex(model="claude-sonnet-5-5", fail_at=4))
        self.execute("vertex-sonnet", tight, output="tight", transport=transport)
        transport, _ = self.transport("vertex-sonnet", FakeVertex(model="claude-sonnet-5-5"))
        tight_resume = self.execute("vertex-sonnet", tight, output="tight", transport=transport, resume=True)
        self.assertEqual(tight_resume["halt_reason"], "request_limit_reached")
        self.assertEqual(tight_resume["generation_requests_total"], 18)
        declaration = self.declaration("vertex-sonnet", **{"budget.max_generation_requests": 20})
        transport, fake = self.transport("vertex-sonnet", FakeVertex(model="claude-sonnet-5-5", fail_at=4))
        first = self.execute("vertex-sonnet", declaration, transport=transport)
        self.assertEqual(first["halt_reason"], "http_status_429")
        self.assertEqual(first["by_status"], {"completed": 3, "infrastructure_failed": 1, "not_attempted": 14})
        self.assertFalse(first["complete"])
        labels_path = self.root / ".build/judge-calibration/labels-vertex-sonnet.json"
        self.assertFalse(labels_path.exists())
        out = self.root / ".build" / "judge-calibration" / "run"
        self.assertTrue((out / "labels-session-01.json").exists())
        with self.assertRaisesRegex(jc.CalibrationError, "destination_exists"):
            self.execute("vertex-sonnet", declaration, transport=transport)
        transport, fake = self.transport("vertex-sonnet", FakeVertex(model="claude-sonnet-5-5"))
        second = self.execute("vertex-sonnet", declaration, transport=transport, resume=True)
        self.assertTrue(second["complete"])
        self.assertEqual(second["prior_attempts_reused"], 4)
        self.assertEqual(fake.generations, 15)  # the 3 completed requests are not sent again
        self.assertEqual(second["session_calls"].get("count", 0), 0)  # authenticated counts are reused
        self.assertEqual(second["generation_requests_total"], 19)
        self.assertEqual(second["by_status"], {"completed": 18})
        self.assertTrue(labels_path.exists())
        # 100 counted input tokens at 5 USD and the declared 512-token output cap at 25 USD per million.
        self.assertEqual(Decimal(second["cost"]["reserved_usd_total"]) * 1000000, 19 * (100 * 5 + 512 * 25))

    def test_resume_refuses_tampered_captures_and_other_declarations(self):
        declaration = self.declaration("qwen-local")
        calls = {"n": 0}
        fake = FakeQwen()

        def failing(url, raw):
            calls["n"] += 1
            if calls["n"] == 5:
                raise run.Infrastructure("http_status_503")
            return fake(url, raw)
        first = self.execute("qwen-local", declaration, transport=run.QwenTransport(failing))
        self.assertEqual(first["halt_reason"], "http_status_503")
        captures = self.root / ".build" / "judge-calibration" / "run" / "captures"
        other = self.declaration("qwen-local", replicates=2)
        with self.assertRaisesRegex(jc.CalibrationError, "resume_declaration_mismatch"):
            self.execute("qwen-local", other, transport=run.QwenTransport(FakeQwen()), resume=True)
        response = captures / "item-001-sufficiency-r1-a1-response.json"
        os.chmod(response, 0o600)
        response.write_bytes(response.read_bytes().replace(b"insufficient", b"sufficient"))
        with self.assertRaisesRegex(jc.CalibrationError, "resume_capture_mismatch"):
            self.execute("qwen-local", declaration, transport=run.QwenTransport(FakeQwen()), resume=True)

    # ------------------------------------------------------------------ parsing and labels

    def test_parse_failures_are_recorded_not_coerced(self):
        self.assertEqual([jc.parse_verdict_text(text) for text in ("yes", " No. ", "YES", "yes!", "Yes, it is.",
                                                                     "yesno", "", None)],
                         ["accept", "reject", "accept", None, None, None, None, None])
        self.assertEqual([jc.parse_sufficiency_text(text) for text in (
            '{"sufficiency": "sufficient"}', ' {"sufficiency":"insufficient"}\n', '```json\n{"sufficiency": '
            '"sufficient"}\n```', '{"sufficiency": "sufficient", "x": 1}', '{"sufficiency": "unsure"}',
            '{"sufficiency": "sufficient", "sufficiency": "insufficient"}', "sufficient", None)],
            ["sufficient", "insufficient", None, None, None, None, None, None])
        fake = FakeQwen(verdict="Probably yes", sufficiency='```json\n{"sufficiency": "sufficient"}\n```')
        report = self.execute("qwen-local", self.declaration("qwen-local", replicates=1),
                              transport=run.QwenTransport(fake))
        self.assertTrue(report["complete"])
        self.assertEqual(report["by_status"], {"parse_failed": 6})
        self.assertEqual(report["failure_codes"], {"output_unparseable": 6})
        labels = json.loads((self.root / ".build/judge-calibration/labels-qwen-local.json").read_text())
        self.assertEqual(labels["labels"], {})
        receipts = list((self.root / ".build/judge-calibration/run/captures").glob("*-receipt.json"))
        self.assertTrue(all(json.loads(path.read_text())["label"] is None for path in receipts))

    def test_identity_mismatch_halts(self):
        report = self.execute("qwen-local", self.declaration("qwen-local"),
                              transport=run.QwenTransport(FakeQwen(model="other-model")))
        self.assertEqual(report["halt_reason"], "model_identity_mismatch")
        self.assertEqual(report["by_status"]["response_invalid"], 1)
        transport, fake = self.transport("vertex-opus", FakeVertex(echo_model="claude-sonnet-5-5"))
        report = self.execute("vertex-opus", self.declaration("vertex-opus"), output="opus", transport=transport)
        self.assertEqual((report["halt_reason"], fake.generations), ("model_identity_mismatch", 1))

    def test_replicates_order_and_score_compatibility(self):
        for judge, replicates in (("jevk5", 2), ("qwen-local", 3), ("vertex-opus", 1)):
            transport, fake = self.transport(judge)
            report = self.execute(judge, self.declaration(judge, replicates=replicates), output=f"rep-{judge}",
                                  transport=transport)
            self.assertTrue(report["complete"], judge)
            self.assertEqual(report["planned_requests"], 3 * 2 * replicates)
            labels_path = self.root / f".build/judge-calibration/labels-{judge}.json"
            labels = json.loads(labels_path.read_text())
            self.assertEqual(labels["judge"], jc.JUDGE_SCORE_NAMES[judge])
            self.assertEqual(sorted(labels["labels"]), ["item-001", "item-002", "item-003"])
            for rows in labels["labels"].values():
                self.assertEqual(len(rows), replicates)
                for row in rows:
                    self.assertEqual(set(row), {"verdict", "sufficiency"})
                    self.assertIn(row["verdict"], ("accept", "reject"))
                    self.assertIn(row["sufficiency"], ("sufficient", "insufficient"))
            receipts = sorted((self.root / f".build/judge-calibration/rep-{judge}/captures").glob("item-*-receipt.json"))
            self.assertEqual(len(receipts), 3 * 2 * replicates)
            order = [json.loads(path.read_text()) for path in receipts]
            self.assertEqual({(r["replicate"], r["stage"]) for r in order},
                             {(rep, stage) for rep in range(1, replicates + 1) for stage in jc.STAGES})
            plan = run.build_plan(run.load_set(self.set_dir)[1], fill(judge, self.manifest, replicates=replicates),
                                  fake_prompt)
            self.assertEqual([entry["request_id"] for entry in plan][:4],
                             ["item-001-sufficiency-r1", "item-001-verdict-r1", "item-002-sufficiency-r1",
                              "item-002-verdict-r1"])
            key = json.loads((self.set_dir / "key.json").read_text())
            adjudications = {"format": jc.ADJUDICATION_FORMAT, "set_id": self.manifest["set_id"],
                             "items_sha256": self.manifest["items_sha256"],
                             "decisions": {entry["item_id"]: {"verdict": "accept", "sufficiency": "sufficient"}
                                           for entry in key["items"]}}
            adjudication_path = self.root / f"adjudications-{judge}.json"
            adjudication_path.write_text(json.dumps(adjudications))
            scored = jc.score(self.set_dir, adjudication_path, [(jc.JUDGE_SCORE_NAMES[judge], str(labels_path))])
            column = {entry["judge"]: entry for entry in scored["candidate_judges"]}[jc.JUDGE_SCORE_NAMES[judge]]
            self.assertEqual(column["labelled_items"], 3)
            self.assertEqual(column["grounded"]["overall"]["compared"], 3)
            if judge == "jevk5":
                self.assertEqual(report["cache_hits_session"], 10)  # the fake reports a hit after two calls
                self.assertTrue(FakeJevClient.instances[-1].closed)

    def test_local_character_bound_records_without_dispatch(self):
        report = self.execute("jevk5", self.declaration("jevk5", **{"request_limits.max_prompt_characters": 10}))
        self.assertTrue(report["complete"])
        self.assertEqual(report["by_status"], {"not_dispatched_over_character_bound": 18})
        self.assertEqual(FakeJevClient.instances[-1].calls, [])

    def test_jevk5_executable_pin_halts_before_connect(self):
        transport = run.JevTransport(EXECUTABLE_SHA, lambda directory: FakeJevClient(directory), lambda: "0" * 64)
        report = self.execute("jevk5", self.declaration("jevk5"), transport=transport)
        self.assertEqual(report["halt_reason"], "executable_changed")
        self.assertEqual(FakeJevClient.instances, [])

    def test_request_limit_and_private_modes(self):
        declaration = fill("qwen-local", self.manifest)
        declaration["request_limits"]["max_requests"] = 5
        self.assertIn("request_limit_below_plan", jc.check_declaration(declaration, self.set_dir))
        report = self.execute("qwen-local", self.declaration("qwen-local"))
        out = self.root / ".build" / "judge-calibration" / "run"
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(out / "captures").st_mode), 0o700)
        for path in out.rglob("*"):
            if path.is_file():
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600, path.name)
        self.assertTrue(report["complete"])
        printed = json.dumps(report)
        for text in ("Synthetic question", "Synthetic reference", "Synthetic evidence", "ANSWERTOKEN"):
            self.assertNotIn(text, printed)

    def test_local_declaration_checks(self):
        for judge in ("jevk5", "qwen-local"):
            filled = fill(judge, self.manifest)
            self.assertEqual(jc.check_declaration(filled, self.set_dir), [], judge)
            for mutate, code in ((lambda d: d["provider"].update(remote=True), "provider_pin"),
                                 (lambda d: d["provider"].update(temperature=0), "forbidden_field:provider.temperature"),
                                 (lambda d: d["execution"].update(replicates=0), "replicates"),
                                 (lambda d: d["execution"].update(automatic_retries=-1), "execution_contract"),
                                 (lambda d: d["outputs"].update(labels_path="docs/labels.json"), "labels_path"),
                                 (lambda d: d.update(format=jc.DECLARATION_FORMAT), "format"),
                                 (lambda d: d["calibration_set"].update(item_count=4), "calibration_set_mismatch")):
                bad = copy.deepcopy(filled)
                mutate(bad)
                self.assertIn(code, jc.check_declaration(bad, self.set_dir), (judge, code))
        bad = fill("jevk5", self.manifest)
        bad["provider"]["executable_sha256"] = "short"
        self.assertIn("executable_sha256", jc.check_declaration(bad))
        vertex_filled = fill("vertex-opus", self.manifest)
        vertex_filled["budget"]["max_count_requests"] = 5
        self.assertIn("count_limit_below_plan", jc.check_declaration(vertex_filled, self.set_dir))
        vertex_filled["execution"]["automatic_retries"] = 1
        self.assertIn("execution_contract", jc.check_declaration(vertex_filled, self.set_dir))

    # ------------------------------------------------------------------ structured replies (declaration v2)

    def test_reply_schema_hash_is_pinned_and_separate_from_prompts(self):
        self.assertEqual(jc.reply_schema_sha256(), REPLY_SCHEMA_SHA256)
        self.assertEqual(jc.judge_prompt_sha256(), PROMPT_SET_SHA256)  # prompts unchanged by the schemas
        for judge in run.VERTEX_JUDGES:
            template = json.loads((TEMPLATES / f"{judge}.template.json").read_text())
            self.assertEqual(template["format"], jc.DECLARATION_FORMAT_V2)
            self.assertEqual(template["reply_schemas"], {"version": "boros-judge-calibration-reply-schemas-v1",
                                                         "sha256": REPLY_SCHEMA_SHA256,
                                                         "transport": "output_config.format, type json_schema"})
            old = json.loads((TEMPLATES / f"{judge}.v1.template.json").read_text())
            self.assertEqual(old["format"], jc.DECLARATION_FORMAT)
            self.assertNotIn("reply_schemas", old)
        filled = fill("vertex-sonnet", self.manifest)
        self.assertEqual(jc.check_declaration(filled, self.set_dir), [])
        with patch.dict(jc.REPLY_SCHEMAS["verdict"], field="verdict"):
            self.assertIn("reply_schema_hash", jc.check_declaration(filled, self.set_dir))
            self.assertEqual(jc.check_declaration(filled, self.set_dir), ["reply_schema_hash"])

    def test_vertex_request_bodies_per_model(self):
        items = run.load_set(self.set_dir)[1]
        expected = {"vertex-sonnet": ({"type": "between_tools"}, ["format"], 512),
                    "vertex-opus": (None, ["effort", "format"], 2048)}
        for judge, (thinking, config_keys, cap) in expected.items():
            plan = run.build_plan(items, fill(judge, self.manifest, replicates=1), fake_prompt)
            for entry in plan:
                body, count = entry["body"], entry["count_body"]
                schema = jc.REPLY_SCHEMAS[entry["stage"]]["schema"]
                keys = {"anthropic_version", "messages", "max_tokens", "output_config"}
                keys |= {"system"} if entry["stage"] == "sufficiency" else set()
                keys |= {"thinking"} if thinking else set()
                self.assertEqual(set(body), keys, judge)
                self.assertEqual(sorted(body["output_config"]), config_keys, judge)
                self.assertEqual(body["output_config"]["format"], {"type": "json_schema", "schema": schema})
                self.assertEqual(body.get("thinking"), thinking, judge)
                self.assertEqual(body["max_tokens"], cap)
                if judge == "vertex-opus":
                    self.assertEqual(body["output_config"]["effort"], "low")
                self.assertNotIn("output_format", body)
                self.assertTrue({"temperature", "top_p", "top_k", "seed"}.isdisjoint(body))
                self.assertTrue({"temperature", "top_p", "top_k", "thinking"}.isdisjoint(body["output_config"]))
                # Counting includes the format (it adds input tokens) and nothing else beyond the input.
                self.assertEqual(set(count), (keys - {"max_tokens", "thinking"}) | {"model"})
                self.assertEqual(count["output_config"], {"format": body["output_config"]["format"]})
                self.assertEqual(count["model"], run.VERTEX_JUDGES[judge])
            dry = run.dry_run(self.set_dir, self.declaration(judge), self.root / ".build/judge-calibration/d",
                              fake_prompt, root=self.root, git_ignore=False)
            self.assertEqual(dry["reply_schemas"]["sha256"], REPLY_SCHEMA_SHA256)
            self.assertEqual(dry["request_fields"]["verdict"]["output_config"], config_keys)
            self.assertEqual(dry["request_fields"]["verdict"]["thinking"], thinking)
            # Version 1 declarations keep the earlier body: no thinking field and no output_config.
            old = run.build_plan(items, fill(judge, self.manifest, replicates=1, template=f"{judge}.v1.template.json"),
                                 fake_prompt)
            for entry in old:
                self.assertEqual(set(entry["body"]) - {"system"}, {"anthropic_version", "messages", "max_tokens"})
                self.assertEqual(set(entry["count_body"]) - {"system"}, {"anthropic_version", "model", "messages"})
                self.assertEqual(entry["body"]["max_tokens"], 256)

    def test_structured_replies_parse_strictly_with_fixed_failure_codes(self):
        self.assertEqual([jc.parse_structured_reply(text, "verdict") for text in (
            '{"answer": "yes"}', ' {"answer":"no"}\n', '{"answer": "Yes"}', '{"answer": "yes", "x": 1}',
            '{"answer": "yes", "answer": "no"}', '{"verdict": "yes"}', "yes", '```json\n{"answer": "yes"}\n```',
            '{"answer": true}', None)],
            ["accept", "reject", None, None, None, None, None, None, None, None])
        self.assertEqual([jc.parse_structured_reply(text, "sufficiency") for text in (
            '{"sufficiency": "insufficient"}', '{"sufficiency": "unsure"}', "sufficient")],
            ["insufficient", None, None])
        sonnet = "claude-sonnet-5-5"
        transport = run.VertexTransport(sonnet, structured=True, token_fn=lambda: "t")
        cases = (
            (vertex_reply('{"answer": "no"}', sonnet), ("completed", "reject", None)),
            (vertex_reply("The answer is yes.", sonnet), ("parse_failed", None, "output_off_schema")),
            (vertex_reply('{"answer": "maybe"}', sonnet), ("parse_failed", None, "output_off_schema")),
            (vertex_reply("", sonnet, stop_reason="max_tokens", thinking_tokens=512,
                          content=[{"type": "thinking", "thinking": "", "signature": "s"}]),
             ("response_invalid", None, "response_incomplete")),
            (vertex_reply('{"answer": "y', sonnet, stop_reason="max_tokens"),
             ("response_invalid", None, "response_incomplete")),
            (vertex_reply("", sonnet, stop_reason="refusal", content=[]), ("response_invalid", None, "refusal")),
            (vertex_reply('{"answer": "yes"}', "claude-opus-5-5"),
             ("response_invalid", None, "model_identity_mismatch")),
            (vertex_reply('{"answer": "yes"}', sonnet, content=[
                {"type": "thinking", "thinking": "", "signature": "s"}, {"type": "text", "text": '{"answer": "yes"}'}]),
             ("completed", "accept", None)))
        for raw, expected in cases:
            self.assertEqual(run.label_from(transport, raw, "verdict"), expected)
        self.assertEqual(vertex.response_metadata(cases[3][0]), {"stop_reason": "max_tokens", "thinking_tokens": 512})
        # A full run: off-schema and truncated replies are recorded as failures, never labels.
        replies = iter([vertex_reply('{"sufficiency": "sufficient"}', sonnet, thinking_tokens=0),
                        vertex_reply("Yes", sonnet, thinking_tokens=0),
                        vertex_reply("", sonnet, stop_reason="max_tokens", thinking_tokens=512,
                                     content=[{"type": "thinking", "thinking": "", "signature": "s"}]),
                        vertex_reply("", sonnet, stop_reason="refusal", content=[], thinking_tokens=0),
                        vertex_reply('{"sufficiency": "insufficient"}', sonnet, thinking_tokens=3),
                        vertex_reply('{"answer": "no"}', sonnet, thinking_tokens=0)])

        def fake(url, body, token):
            if url == vertex.count_url():
                return vertex.canonical({"input_tokens": 100})
            if body == {}:  # the access probe
                raise vertex.VertexError("http_status_400")
            return next(replies)
        declaration = self.declaration("vertex-sonnet", replicates=1)
        report = self.execute("vertex-sonnet", declaration, output="strict",
                              transport=run.VertexTransport(sonnet, fake, lambda: "synthetic-token"))
        self.assertTrue(report["complete"])
        self.assertEqual(report["by_status"], {"completed": 3, "parse_failed": 1, "response_invalid": 2})
        self.assertEqual(report["failure_codes"], {"output_off_schema": 1, "response_incomplete": 1, "refusal": 1})
        self.assertEqual(report["replies_session"], {"stop_reasons": {"end_turn": 4, "max_tokens": 1, "refusal": 1},
                                                     "thinking_tokens": 515})
        self.assertEqual(report["reply_schemas"]["sha256"], REPLY_SCHEMA_SHA256)
        out = self.root / ".build/judge-calibration/strict"
        self.assertEqual(json.loads((out / "run.json").read_text())["reply_schemas"]["sha256"], REPLY_SCHEMA_SHA256)
        receipt = json.loads((out / "captures/item-002-sufficiency-r1-a1-receipt.json").read_text())
        self.assertEqual((receipt["status"], receipt["label"], receipt["failure"], receipt["stop_reason"],
                          receipt["thinking_tokens"]), ("response_invalid", None, "response_incomplete", "max_tokens", 512))
        labels = json.loads((self.root / ".build/judge-calibration/labels-vertex-sonnet.json").read_text())
        self.assertEqual(labels["labels"], {"item-001": [{"sufficiency": "sufficient", "verdict": None}],
                                            "item-003": [{"sufficiency": "insufficient", "verdict": "reject"}]})
        self.assertEqual(labels["reply_schemas"]["sha256"], REPLY_SCHEMA_SHA256)
        # The resume re-derives every label through the same strict structured parser.
        plan = run.prepare(self.set_dir, declaration, fake_prompt)[-1]
        captures = run.Captures(out / "captures")
        state = run.prior_state(captures, run.VertexTransport(sonnet, structured=True, token_fn=lambda: "t"), plan)
        self.assertEqual((state["prior_attempts"], len(state["latest"])), (6, 6))
        with self.assertRaisesRegex(jc.CalibrationError, "resume_capture_mismatch"):  # bare-text parsing differs
            run.prior_state(captures, run.VertexTransport(sonnet, structured=False, token_fn=lambda: "t"), plan)

    def test_version_1_declarations_keep_unconstrained_parsing_and_resume(self):
        for judge in run.VERTEX_JUDGES:
            model = run.VERTEX_JUDGES[judge]
            declaration = self.declaration(judge, template=f"{judge}.v1.template.json", replicates=1,
                                           **{"budget.max_generation_requests": 10})
            self.assertEqual(jc.check_declaration(json.loads(declaration.read_text()), self.set_dir), [])
            fake = FakeVertex(model=model, fail_at=3)
            first = self.execute(judge, declaration, output=f"v1-{judge}",
                                 transport=run.VertexTransport(model, fake, lambda: "synthetic-token", structured=True))
            self.assertEqual(first["halt_reason"], "http_status_429")
            self.assertIsNone(first["reply_schemas"])
            self.assertTrue(all("output_config" not in body and "thinking" not in body for body in fake.generation_bodies))
            out = self.root / f".build/judge-calibration/v1-{judge}"
            self.assertNotIn("reply_schemas", json.loads((out / "run.json").read_text()))
            second = self.execute(judge, declaration, output=f"v1-{judge}", resume=True,
                                  transport=run.VertexTransport(model, FakeVertex(model=model), lambda: "synthetic-token"))
            self.assertTrue(second["complete"])
            self.assertEqual(second["by_status"], {"completed": 6})  # bare "Yes." still parses under v1

    def test_vertex_v2_declaration_refuses_forbidden_thinking_and_effort(self):
        sonnet, opus = fill("vertex-sonnet", self.manifest), fill("vertex-opus", self.manifest)
        self.assertEqual(jc.check_declaration(sonnet, self.set_dir), [])
        self.assertEqual(jc.check_declaration(opus, self.set_dir), [])
        cases = (
            (sonnet, lambda d: d["execution"].update(thinking={"type": "disabled"}), "thinking_forbidden"),
            (sonnet, lambda d: d["execution"].update(thinking={"type": "enabled", "budget_tokens": 1024}),
             "forbidden_field:execution.thinking.budget_tokens"),
            (sonnet, lambda d: d["execution"].update(thinking={"type": "between_tools", "display": "omitted"}),
             "thinking_contract"),
            (sonnet, lambda d: d["execution"].update(thinking="omitted-adaptive"), "thinking_contract"),
            (sonnet, lambda d: d["execution"].update(effort="xhigh"), "effort_above_high_with_between_tools"),
            (sonnet, lambda d: d["execution"].update(effort="max"), "effort_above_high_with_between_tools"),
            (sonnet, lambda d: d["execution"].update(max_output_tokens_per_request=8192), "output_limit"),
            (sonnet, lambda d: d["execution"].update(extended_thinking=False), "stale_field:execution.extended_thinking"),
            (sonnet, lambda d: d.pop("reply_schemas"), "reply_schema_hash"),
            (sonnet, lambda d: d["execution"].update(temperature=0), "forbidden_field:execution.temperature"),
            (opus, lambda d: d["execution"].update(thinking={"type": "disabled"}), "thinking_forbidden"),
            (opus, lambda d: d["execution"].update(thinking={"type": "between_tools"}), "thinking_contract"),
            (opus, lambda d: d["execution"].update(budget_tokens=2048), "forbidden_field:execution.budget_tokens"),
            (opus, lambda d: d["execution"].update(effort="provider-default"), "effort"),
            (opus, lambda d: d["execution"].update(max_output_tokens_per_request=256), "output_limit"),
            (opus, lambda d: d["execution"].update(max_output_tokens_per_request=16384), "output_limit"),
            (opus, lambda d: d.update(format="boros-judge-calibration-vertex-declaration-v4"), "format"))
        for base, mutate, code in cases:
            bad = copy.deepcopy(base)
            mutate(bad)
            self.assertIn(code, jc.check_declaration(bad, self.set_dir), code)
        for effort in ("low", "medium", "high", "provider-default"):
            ok = copy.deepcopy(sonnet)
            ok["execution"]["effort"] = effort
            self.assertEqual(jc.check_declaration(ok, self.set_dir), [], effort)
        # The adapter refuses the same combinations when a body is rendered.
        messages = [{"role": "user", "content": "x"}]
        for model, thinking, effort, code in (
                ("claude-sonnet-5-5", {"type": "disabled"}, None, "thinking_invalid"),
                ("claude-sonnet-5-5", {"type": "enabled", "budget_tokens": 1024}, None, "thinking_invalid"),
                ("claude-sonnet-5-5", {"type": "between_tools"}, "xhigh", "effort_invalid_with_between_tools"),
                ("claude-opus-5-5", {"type": "between_tools"}, "low", "thinking_unsupported_for_model"),
                ("claude-opus-5-5", None, "extreme", "effort_invalid")):
            with self.assertRaisesRegex(vertex.VertexError, code):
                vertex.payload(messages, 64, model=model, thinking=thinking, effort=effort)

    # ------------------------------------------------------------------ instructed JSON replies (declaration v3)

    def v3(self, judge, **kwargs):
        return fill(judge, self.manifest, template=f"{judge}.v3.template.json", **kwargs)

    def test_v3_prompt_set_hash_is_pinned_and_component_hashes_are_unchanged(self):
        self.assertEqual(jc.judge_prompt_v3_sha256(), PROMPT_SET_V3_SHA256)
        self.assertEqual(jc.reply_instructions_sha256(), REPLY_INSTRUCTIONS_SHA256)
        self.assertEqual((jc.judge_prompt_sha256(), jc.verdict_prompt_sha256(), jc.sufficiency_prompt_sha256(),
                          jc.reply_schema_sha256()),
                         (PROMPT_SET_SHA256, VERDICT_SHA256, SUFFICIENCY_SHA256, REPLY_SCHEMA_SHA256))
        self.assertEqual((jc.REPLY_INSTRUCTIONS["verdict"], jc.REPLY_INSTRUCTIONS["sufficiency"]),
                         (VERDICT_LINE, SUFFICIENCY_LINE))
        self.assertIs(jc.JUDGE_PROMPTS_V3["verdict"], jc.VERDICT_PROMPT)
        self.assertIs(jc.JUDGE_PROMPTS_V3["sufficiency"], jc.SUFFICIENCY_PROMPT)
        self.assertEqual(jc.JUDGE_PROMPTS_V3["base_version"], jc.JUDGE_PROMPTS["version"])
        # Each line names exactly the shape's objects, so a reply copying one parses.
        for stage, line in (("verdict", VERDICT_LINE), ("sufficiency", SUFFICIENCY_LINE)):
            shape = jc.REPLY_INSTRUCTIONS["shapes"][stage]
            self.assertEqual(shape["schema"], jc.REPLY_SCHEMAS[stage]["schema"])
            for value, label in shape["mapping"].items():
                literal = json.dumps({shape["field"]: value})
                self.assertIn(literal, line)
                self.assertEqual(jc.parse_instructed_reply(literal, stage), label)
        for judge in run.VERTEX_JUDGES:
            template = json.loads((TEMPLATES / f"{judge}.v3.template.json").read_text())
            self.assertEqual(template["format"], jc.DECLARATION_FORMAT_V3)
            self.assertEqual({key: template["prompts"][key] for key in template["prompts"] if key != "source"},
                             {"version": "boros-judge-calibration-prompts-v3", "sha256": PROMPT_SET_V3_SHA256,
                              "verdict_sha256": VERDICT_SHA256, "sufficiency_sha256": SUFFICIENCY_SHA256,
                              "upstream_protocol_sha256": jc.UPSTREAM_QA_PROTOCOL_SHA256,
                              "reply_instructions_sha256": REPLY_INSTRUCTIONS_SHA256})
            self.assertEqual(template["reply_format"], {
                "mode": "instructed-json", "structured_outputs": False,
                "version": "boros-judge-calibration-reply-instructions-v1", "sha256": REPLY_INSTRUCTIONS_SHA256,
                "parse_tolerance": ["surrounding_whitespace", "single_markdown_code_fence"]})
            self.assertNotIn("reply_schemas", template)
            self.assertEqual(json.loads((TEMPLATES / f"{judge}.template.json").read_text())["format"],
                             jc.DECLARATION_FORMAT_V2)
            self.assertEqual(jc.check_declaration(self.v3(judge), self.set_dir), [])
        v2 = fill("vertex-sonnet", self.manifest)
        with patch.dict(jc.REPLY_INSTRUCTIONS, verdict=VERDICT_LINE + " Changed."):
            self.assertEqual(jc.check_declaration(self.v3("vertex-sonnet"), self.set_dir),
                             ["prompt_hash", "reply_format_hash"])
            self.assertEqual(jc.check_declaration(v2, self.set_dir), [])  # v2 does not pin the line

    def test_v3_request_bodies_per_model(self):
        items = run.load_set(self.set_dir)[1]
        expected = {"vertex-sonnet": ({"type": "between_tools"}, None, 512),
                    "vertex-opus": (None, {"effort": "low"}, 2048)}
        for judge, (thinking, output_config, cap) in expected.items():
            plan = run.build_plan(items, self.v3(judge, replicates=1), fake_prompt)
            v2_plan = {entry["request_id"]: entry for entry in run.build_plan(
                items, fill(judge, self.manifest, replicates=1), fake_prompt)}
            for entry in plan:
                body, count, stage = entry["body"], entry["count_body"], entry["stage"]
                keys = {"anthropic_version", "messages", "max_tokens", "system"}
                keys |= {"thinking"} if thinking else {"output_config"}
                self.assertEqual(set(body), keys, judge)
                self.assertEqual(body.get("thinking"), thinking, judge)
                self.assertEqual(body.get("output_config"), output_config, judge)
                self.assertEqual(body["max_tokens"], cap)
                self.assertFalse(jc._carries_structured_outputs(body))
                self.assertTrue({"temperature", "top_p", "top_k", "seed", "output_format"}.isdisjoint(body))
                line = VERDICT_LINE if stage == "verdict" else SUFFICIENCY_LINE
                self.assertEqual(body["system"], line if stage == "verdict"
                                 else jc.SUFFICIENCY_PROMPT["system"] + "\n\n" + line)
                # The prompt texts are byte-identical to v2; only the separate system line is added.
                previous = v2_plan[entry["request_id"]]
                self.assertEqual(body["messages"], previous["body"]["messages"])
                self.assertEqual(entry["characters"], previous["characters"] + len(line))
                self.assertEqual(set(count), {"anthropic_version", "model", "messages", "system"})
                self.assertEqual((count["system"], count["messages"], count["model"]),
                                 (body["system"], body["messages"], run.VERTEX_JUDGES[judge]))
            patches = no_network()
            for patcher in patches:
                patcher.start()
            try:
                dry = run.dry_run(self.set_dir, self.declaration(judge, template=f"{judge}.v3.template.json"),
                                  self.root / ".build/judge-calibration/d3", fake_prompt, root=self.root,
                                  git_ignore=False)
            finally:
                for patcher in patches:
                    patcher.stop()
            self.assertEqual((dry["network_calls"], dry["files_written"]), (0, 0))
            self.assertTrue(dry["declaration_complete"], dry["declaration_problems"])
            self.assertIsNone(dry["reply_schemas"])
            self.assertEqual(dry["reply_format"]["sha256"], REPLY_INSTRUCTIONS_SHA256)
            self.assertEqual((dry["prompts"]["version"], dry["prompts"]["prompt_set_sha256"],
                              dry["prompts"]["reply_instructions_sha256"], dry["prompts"]["verdict_sha256"]),
                             ("boros-judge-calibration-prompts-v3", PROMPT_SET_V3_SHA256, REPLY_INSTRUCTIONS_SHA256,
                              VERDICT_SHA256))
            self.assertEqual(dry["request_fields"]["verdict"]["output_config"],
                             sorted(output_config) if output_config else None)
            self.assertEqual(dry["request_fields"]["verdict"]["thinking"], thinking)
            self.assertIn("system", dry["request_fields"]["verdict"]["generation"])
        # Local judges and earlier Vertex declarations never receive the line.
        self.assertNotIn("reply_instructions_sha256", run.prompt_hashes(fill("vertex-sonnet", self.manifest)))
        self.assertEqual(run.prompt_hashes(fill("qwen-local", self.manifest))["version"],
                         "boros-judge-calibration-prompts-v2")

    def test_instructed_replies_parse_strictly(self):
        verdict_cases = (
            ('{"answer": "yes"}', ("accept", "bare")), (' \n{"answer":"no"}\n ', ("reject", "bare")),
            ('```json\n{"answer": "yes"}\n```', ("accept", "fenced")), ('```\n{"answer": "no"}\n```', ("reject", "fenced")),
            ('  ```json\n  {"answer": "no"}  \n```  ', ("reject", "fenced")),
            ("The answer is yes.", (None, None)), ("Yes", (None, None)), ("yes", (None, None)),
            ('Answer: {"answer": "yes"}', (None, None)), ('{"answer": "yes"} I am confident.', (None, None)),
            ('```json\n{"answer": "yes"}\n```\nBecause the reference matches.', (None, None)),
            ('Here it is:\n```json\n{"answer": "yes"}\n```', (None, None)),
            ('```json\n{"answer": "yes"}\n```\n```json\n{"answer": "no"}\n```', (None, None)),
            ('{"answer": "yes"}\n{"answer": "no"}', (None, None)), ('```python\n{"answer": "yes"}\n```', (None, None)),
            ('```json {"answer": "yes"} ```', (None, None)), ('{"answer": "yes", "reason": "x"}', (None, None)),
            ('{"answer": "Yes"}', (None, None)), ('{"answer": "maybe"}', (None, None)), ('{"answer": true}', (None, None)),
            ('{"answer": "yes", "answer": "no"}', (None, None)), ('["yes"]', (None, None)),
            ('{"sufficiency": "sufficient"}', (None, None)), ("", (None, None)), (None, (None, None)))
        for text, expected in verdict_cases:
            self.assertEqual(jc.parse_instructed_reply_detail(text, "verdict"), expected, text)
        sufficiency_cases = (
            ('{"sufficiency": "insufficient"}', ("insufficient", "bare")),
            ('```json\n{"sufficiency": "sufficient"}\n```', ("sufficient", "fenced")),
            ('{"sufficiency": "unsure"}', (None, None)), ("sufficient", (None, None)), ('{"answer": "yes"}', (None, None)),
            ('{"sufficiency": "sufficient", "note": ""}', (None, None)))
        for text, expected in sufficiency_cases:
            self.assertEqual(jc.parse_instructed_reply_detail(text, "sufficiency"), expected, text)
        self.assertIsNone(jc.parse_structured_reply('```json\n{"answer": "yes"}\n```', "verdict"))  # v2 unchanged
        sonnet = "claude-sonnet-5-5"
        with self.assertRaisesRegex(jc.CalibrationError, "reply_mode_invalid"):
            run.VertexTransport(sonnet, structured=True, instructed=True, token_fn=lambda: "t")
        transport = run.VertexTransport(sonnet, instructed=True, token_fn=lambda: "t")
        for raw, expected in (
                (vertex_reply('```json\n{"answer": "no"}\n```', sonnet), ("completed", "reject", None)),
                (vertex_reply('The answer is yes. {"answer": "yes"}', sonnet), ("parse_failed", None, "output_off_schema")),
                (vertex_reply('{"answer": "y', sonnet, stop_reason="max_tokens"),
                 ("response_invalid", None, "response_incomplete")),
                (vertex_reply("", sonnet, stop_reason="refusal", content=[]), ("response_invalid", None, "refusal")),
                (vertex_reply('{"answer": "yes"}', "claude-opus-5-5"),
                 ("response_invalid", None, "model_identity_mismatch"))):
            self.assertEqual(run.label_from(transport, raw, "verdict"), expected)
        # A full run: prose, truncated and refused replies are recorded failures, never labels.
        replies = iter([vertex_reply('{"sufficiency": "sufficient"}', sonnet, thinking_tokens=0),
                        vertex_reply("Yes, the response matches the reference.", sonnet, thinking_tokens=0),
                        vertex_reply("", sonnet, stop_reason="max_tokens", thinking_tokens=512,
                                     content=[{"type": "thinking", "thinking": "", "signature": "s"}]),
                        vertex_reply("", sonnet, stop_reason="refusal", content=[], thinking_tokens=0),
                        vertex_reply('```json\n{"sufficiency": "insufficient"}\n```', sonnet, thinking_tokens=0),
                        vertex_reply('{"answer": "no"}', sonnet, thinking_tokens=0)])
        bodies = []

        def fake(url, body, token):
            if url == vertex.count_url():
                self.assertNotIn("output_config", body)
                return vertex.canonical({"input_tokens": 100})
            if body == {}:  # the access probe
                raise vertex.VertexError("http_status_400")
            bodies.append(body)
            return next(replies)
        path = self.declaration("vertex-sonnet", template="vertex-sonnet.v3.template.json", replicates=1)
        report = self.execute("vertex-sonnet", path, output="instructed",
                              transport=run.VertexTransport(sonnet, fake, lambda: "synthetic-token"))
        self.assertTrue(report["complete"])
        self.assertEqual(len(bodies), 6)
        self.assertTrue(all("output_config" not in body and body["thinking"] == {"type": "between_tools"}
                            and body["system"].endswith((VERDICT_LINE, SUFFICIENCY_LINE)) for body in bodies))
        self.assertEqual(report["by_status"], {"completed": 3, "parse_failed": 1, "response_invalid": 2})
        self.assertEqual(report["failure_codes"], {"output_off_schema": 1, "response_incomplete": 1, "refusal": 1})
        self.assertEqual(report["replies_session"], {"stop_reasons": {"end_turn": 4, "max_tokens": 1, "refusal": 1},
                                                     "thinking_tokens": 512, "wrappers": {"bare": 2, "fenced": 1}})
        self.assertIsNone(report["reply_schemas"])
        self.assertEqual(report["reply_format"]["sha256"], REPLY_INSTRUCTIONS_SHA256)
        self.assertEqual(report["prompts"]["prompt_set_sha256"], PROMPT_SET_V3_SHA256)
        out = self.root / ".build/judge-calibration/instructed"
        record = json.loads((out / "run.json").read_text())
        self.assertEqual((record["reply_format"]["sha256"], record["prompts"]["version"]),
                         (REPLY_INSTRUCTIONS_SHA256, "boros-judge-calibration-prompts-v3"))
        self.assertNotIn("reply_schemas", record)
        receipt = json.loads((out / "captures/item-003-sufficiency-r1-a1-receipt.json").read_text())
        self.assertEqual((receipt["status"], receipt["label"], receipt["reply_wrapper"]),
                         ("completed", "insufficient", "fenced"))
        receipt = json.loads((out / "captures/item-001-verdict-r1-a1-receipt.json").read_text())
        self.assertEqual((receipt["status"], receipt["failure"], receipt["reply_wrapper"]),
                         ("parse_failed", "output_off_schema", None))
        labels = json.loads((self.root / ".build/judge-calibration/labels-vertex-sonnet.json").read_text())
        self.assertEqual(labels["labels"], {"item-001": [{"sufficiency": "sufficient", "verdict": None}],
                                            "item-003": [{"sufficiency": "insufficient", "verdict": "reject"}]})
        self.assertEqual((labels["reply_format"]["sha256"], labels["prompts"]["version"]),
                         (REPLY_INSTRUCTIONS_SHA256, "boros-judge-calibration-prompts-v3"))
        self.assertNotIn("reply_schemas", labels)
        # The resume re-derives every label through the same instructed parser; the v2 parser differs.
        plan = run.prepare(self.set_dir, path, fake_prompt)[-1]
        captures = run.Captures(out / "captures")
        state = run.prior_state(captures, run.VertexTransport(sonnet, instructed=True, token_fn=lambda: "t"), plan)
        self.assertEqual((state["prior_attempts"], len(state["latest"])), (6, 6))
        with self.assertRaisesRegex(jc.CalibrationError, "resume_capture_mismatch"):
            run.prior_state(captures, run.VertexTransport(sonnet, structured=True, token_fn=lambda: "t"), plan)

    def test_verdict_only_declaration_plans_identical_verdict_requests_and_nothing_else(self):
        items = run.load_set(self.set_dir)[1]
        full = self.v3("vertex-sonnet")
        verdict_only = self.v3("vertex-sonnet", **{"execution.stages_per_item": ["verdict"],
                                                    "budget.max_generation_requests": 3 * 3,
                                                    "budget.max_count_requests": 3})
        self.assertEqual(jc.check_declaration(verdict_only, self.set_dir), [])
        self.assertEqual(jc.declared_stages(verdict_only), ("verdict",))
        self.assertEqual(jc.declared_stages(full), jc.STAGES)
        for template in ("vertex-sonnet.v3.template.json", "vertex-opus.v3.template.json", "jevk5.template.json",
                         "qwen-local.template.json"):
            self.assertEqual(json.loads((TEMPLATES / template).read_text())["execution"]["stages_per_item"],
                             list(jc.STAGES), template)
        # Only the two accepted plans pass; limits are checked against the verdict-only plan.
        for stages in (["sufficiency"], ["verdict", "sufficiency"], ["verdict", "verdict"], [], "verdict", None):
            bad = copy.deepcopy(verdict_only)
            bad["execution"]["stages_per_item"] = stages
            self.assertIn("stages" if stages is not None else "unfilled:execution.stages_per_item",
                          jc.check_declaration(bad, self.set_dir), stages)
        low = copy.deepcopy(verdict_only)
        low["budget"].update(max_generation_requests=8, max_count_requests=2)
        self.assertTrue({"generation_limit_below_plan", "count_limit_below_plan"}
                        <= set(jc.check_declaration(low, self.set_dir)))
        # The verdict requests are byte-identical to the verdict requests of the full plan.
        full_plan = run.build_plan(items, full, fake_prompt)
        plan = run.build_plan(items, verdict_only, fake_prompt)
        self.assertEqual({entry["stage"] for entry in plan}, {"verdict"})
        self.assertEqual([(entry["request_id"], entry["body_sha256"], entry["count_body"]) for entry in plan],
                         [(entry["request_id"], entry["body_sha256"], entry["count_body"]) for entry in full_plan
                          if entry["stage"] == "verdict"])
        self.assertEqual(plan[0]["body"]["system"], VERDICT_LINE)
        patches = no_network()
        for patcher in patches:
            patcher.start()
        try:
            dry = run.dry_run(self.set_dir, self.declaration("vertex-sonnet", template="vertex-sonnet.v3.template.json",
                                                             **{"execution.stages_per_item": ["verdict"]}),
                              self.root / ".build" / "judge-calibration" / "dry", fake_prompt, root=self.root,
                              git_ignore=False)
        finally:
            for patcher in patches:
                patcher.stop()
        self.assertEqual((dry["network_calls"], dry["files_written"]), (0, 0))
        self.assertEqual((dry["requests"], dry["unique_requests"], dry["count_requests_needed"], sorted(dry["by_stage"])),
                         (9, 3, 3, ["verdict"]))
        # A full fake run sends verdict requests only and leaves sufficiency unlabelled.
        path = self.declaration("vertex-sonnet", template="vertex-sonnet.v3.template.json",
                                **{"execution.stages_per_item": ["verdict"], "budget.max_generation_requests": 9,
                                   "budget.max_count_requests": 3})
        transport, fake = self.transport("vertex-sonnet")
        report = self.execute("vertex-sonnet", path, output="verdict-only", transport=transport)
        self.assertTrue(report["complete"])
        self.assertEqual((report["planned_requests"], report["generation_requests_total"],
                          report["count_requests_total"], report["access_probe"]), (9, 9, 3, "reachable"))
        self.assertTrue(all(body.get("system") == VERDICT_LINE for body in fake.generation_bodies))
        labels = json.loads((self.root / ".build/judge-calibration/labels-vertex-sonnet.json").read_text())
        self.assertEqual(labels["prompts"]["version"], "boros-judge-calibration-prompts-v3")
        for rows in labels["labels"].values():
            self.assertEqual([row["sufficiency"] for row in rows], [None, None, None])
            self.assertEqual([row["verdict"] for row in rows], ["accept"] * 3)

    def test_v3_declaration_checks(self):
        sonnet, opus = self.v3("vertex-sonnet"), self.v3("vertex-opus")
        v2_prompts = fill("vertex-sonnet", self.manifest)["prompts"]
        for document in (sonnet, opus, fill("vertex-sonnet", self.manifest), fill("vertex-opus", self.manifest),
                         fill("vertex-sonnet", self.manifest, template="vertex-sonnet.v1.template.json"),
                         fill("vertex-opus", self.manifest, template="vertex-opus.v1.template.json")):
            self.assertEqual(jc.check_declaration(document, self.set_dir), [], document["format"])
        format_value = {"type": "json_schema", "schema": jc.REPLY_SCHEMAS["verdict"]["schema"]}
        cases = (
            (sonnet, lambda d: d["execution"].update(output_config={"format": format_value}),
             "structured_outputs_forbidden"),
            (opus, lambda d: d["execution"].update(output_config={"effort": "low", "format": format_value}),
             "structured_outputs_forbidden"),
            (sonnet, lambda d: d.update(reply_schemas=jc.reply_schemas_declaration()), "structured_outputs_forbidden"),
            (opus, lambda d: d["provider"].update(output_format=format_value), "structured_outputs_forbidden"),
            (sonnet, lambda d: d.pop("reply_format"), "reply_format_hash"),
            (sonnet, lambda d: d["reply_format"].update(structured_outputs=True), "reply_format_hash"),
            (sonnet, lambda d: d["reply_format"].update(parse_tolerance=["surrounding_whitespace"]), "reply_format_hash"),
            (sonnet, lambda d: d["reply_format"].update(sha256="0" * 64), "reply_format_hash"),
            (sonnet, lambda d: d.update(prompts=copy.deepcopy(v2_prompts)), "prompt_hash"),
            (sonnet, lambda d: d["prompts"].pop("reply_instructions_sha256"), "prompt_hash"),
            (sonnet, lambda d: d["prompts"].update(verdict_sha256="0" * 64), "prompt_hash"),
            (sonnet, lambda d: d["execution"].update(thinking={"type": "disabled"}), "thinking_forbidden"),
            (sonnet, lambda d: d["execution"].update(thinking="omitted-adaptive"), "thinking_contract"),
            (sonnet, lambda d: d["execution"].update(effort="xhigh"), "effort_above_high_with_between_tools"),
            (sonnet, lambda d: d["execution"].update(max_output_tokens_per_request=8192), "output_limit"),
            (sonnet, lambda d: d["execution"].update(temperature=0), "forbidden_field:execution.temperature"),
            (opus, lambda d: d["execution"].update(thinking={"type": "between_tools"}), "thinking_contract"),
            (opus, lambda d: d["execution"].update(effort="provider-default"), "effort"),
            (opus, lambda d: d["execution"].update(max_output_tokens_per_request=512), "output_limit"),
            (opus, lambda d: d["execution"].update(extended_thinking=False), "stale_field:execution.extended_thinking"))
        for base, mutate, code in cases:
            bad = copy.deepcopy(base)
            mutate(bad)
            self.assertIn(code, jc.check_declaration(bad, self.set_dir), code)
        # A v2 declaration must not pin prompt set v3, and v3 prompts or reply format do not fit v2.
        v2 = fill("vertex-sonnet", self.manifest)
        v2["prompts"] = copy.deepcopy(sonnet["prompts"])
        self.assertIn("prompt_hash", jc.check_declaration(v2, self.set_dir))
        local = fill("qwen-local", self.manifest)
        local["format"] = jc.DECLARATION_FORMAT_V3
        self.assertIn("format", jc.check_declaration(local, self.set_dir))
        stdout = io.StringIO()
        path = self.declaration("vertex-opus", template="vertex-opus.v3.template.json")
        with patch("sys.stdout", stdout):
            code = jc.main(["check-declaration", str(path), "--set", str(self.set_dir)])
        self.assertEqual((code, json.loads(stdout.getvalue())), (0, {"complete": True, "problems": []}))


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
