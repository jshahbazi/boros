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


def fill(judge, manifest, *, replicates=3, **overrides):
    document = json.loads((TEMPLATES / f"{judge}.template.json").read_text())
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


def vertex_reply(text, model="claude-opus-5-5", input_tokens=100, output_tokens=2):
    return vertex.canonical({"id": "msg_synthetic", "type": "message", "role": "assistant", "model": model,
                             "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                             "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens}})


class FakeVertex:
    def __init__(self, model="claude-opus-5-5", verdict="Yes.", sufficiency='{"sufficiency": "sufficient"}',
                 fail_at=None, count=100, echo_model=None):
        self.model, self.verdict, self.sufficiency = model, verdict, sufficiency
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
        text = self.sufficiency if "system" in body else self.verdict
        return vertex_reply(text, self.echo_model)


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
                self.assertTrue({"temperature", "top_p", "top_k", "thinking", "seed"}.isdisjoint(body)
                                or judge == "qwen-local", judge)

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
            # 18 generations at 100 counted input tokens and 256 reserved output tokens: 18 x 6,900 micro-USD.
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
        self.assertEqual(Decimal(second["cost"]["reserved_usd_total"]) * 1000000, 19 * 6900)

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


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
                      "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
