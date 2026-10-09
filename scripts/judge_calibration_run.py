#!/usr/bin/env python3
"""P4 judge-calibration runner for four judges over a frozen blinded calibration set.

Judges: ``vertex-opus`` and ``vertex-sonnet`` (Vertex AI through ``vertex_anthropic.py``),
``jevk5`` (the local JevK5 MCP slot, through the connection code of ``jevk5_saved_qa.py``) and
``qwen-local`` (the selected Qwen model on the loopback mlx-serve endpoint).

Each item gets two tasks per replicate, rendered from blinded item fields only: pack sufficiency
(new prompt, without the answer) and answer verdict (the unchanged hash-pinned upstream LongMemEval
QA prompt). The key file of the set is never opened.

Vertex declarations of version 2 constrain both replies with structured outputs
(``output_config.format``, schemas in ``judge_calibration.REPLY_SCHEMAS``, hash pinned separately
from the prompts) and declare thinking per model: Sonnet 5.5 sends ``thinking: between_tools``
(thinking off), Opus 5.5 sends ``output_config.effort`` and a larger output cap. Version 3
declarations keep those thinking controls but send no ``output_config.format`` (structured outputs
are blocked by an organization policy on the llm-train project); instead each request carries one
fixed reply-format system line (``judge_calibration.REPLY_INSTRUCTIONS``, prompt set v3) and the
reply is parsed strictly as the same JSON shape. Version 1 declarations keep the earlier
unconstrained bodies and bare-text parsing so their runs can be resumed and verified unchanged.

Two gates protect every dispatch:

1. ``judge_calibration.py check-declaration`` must report no problem for the filled declaration.
2. Nothing is dispatched without ``--execute``. Without it, the command is a dry run: it validates
   the set and the declaration, renders every request in memory, writes nothing, and prints counts
   only. A dry run makes no network, token-count, model-server or MCP call of any kind.

Privacy contract: stdout carries counts, identifiers, hashes and fixed codes only. Request and
response bodies are written only to private captures (0600 files in 0700 directories) under the
Git-ignored ``.build`` directory.
"""
from __future__ import annotations

import argparse
from collections import Counter
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import judge_calibration as jc  # noqa: E402
import vertex_anthropic as vertex  # noqa: E402

VERSION = "judge-calibration-run-v1"
RUN_FORMAT = "boros-judge-calibration-run-v1"
REPORT_FORMAT = "boros-judge-calibration-run-report-v1"
VERTEX_JUDGES = dict(jc.DECLARATION_MODELS)
JUDGES = tuple(VERTEX_JUDGES) + jc.LOCAL_JUDGES
MAXIMUM_REQUEST_BYTES = 2 * 1024 * 1024
MAXIMUM_RESPONSE_BYTES = 2 * 1024 * 1024
TERMINAL = ("completed", "parse_failed", "response_invalid", "not_dispatched_over_character_bound")
IDENTITY_FAILURES = ("model_identity_mismatch", "jev_model_mismatch")
NAME = re.compile(r"[A-Za-z0-9_-]+\Z")

CalibrationError = jc.CalibrationError
require = jc.require
sha256_bytes = jc.sha256_bytes
canonical = jc.canonical


class Halt(Exception):
    """Stops the session with a fixed code; captures already written remain valid."""


class Infrastructure(Exception):
    """No usable response: transport failure or an HTTP status. Fixed codes only."""


class ResponseInvalid(Exception):
    """A response arrived but failed provider-shape validation. Fixed codes only."""


# --------------------------------------------------------------------------- inputs


def load_set(set_dir: Path):
    """Items verified against the manifest hash. The key file is never opened."""
    manifest = jc.load_json(set_dir / "manifest.json")
    raw = (set_dir / "items.json").read_bytes()
    require(sha256_bytes(raw) == manifest.get("items_sha256"), "items_hash_mismatch")
    document = json.loads(raw)
    require(document.get("format") == jc.ITEMS_FORMAT and document.get("set_id") == manifest.get("set_id"),
            "items_document_invalid")
    items = document.get("items")
    require(isinstance(items, list) and len(items) == manifest.get("item_count"), "item_count_mismatch")
    for item in items:
        require(isinstance(item, dict) and set(item) == jc.ITEM_KEYS
                and re.fullmatch(r"item-\d{3}", item["item_id"]), "item_shape_invalid")
        for entry in item["evidence"]:
            require(isinstance(entry, dict) and set(entry) == jc.EVIDENCE_KEYS, "item_shape_invalid")
    require(len({item["item_id"] for item in items}) == len(items), "item_ids_not_unique")
    return manifest, sorted(items, key=lambda item: item["item_id"])


def load_declaration(path: Path):
    document = json.loads(Path(path).read_bytes())
    require(isinstance(document, dict), "declaration_invalid")
    return document, sha256_bytes(canonical(document))


def prompt_hashes(declaration=None):
    """Prompt hashes recorded in run records, labels and reports. Unchanged for v1, v2 and local
    declarations; a v3 Vertex declaration records prompt set v3 and the reply-instruction hash."""
    vertex_declaration = declaration is not None and declaration.get("judge") in VERTEX_JUDGES
    fields = jc.prompts_declaration(declaration if vertex_declaration else None)
    hashes = {"version": fields["version"], "prompt_set_sha256": fields["sha256"],
              "verdict_sha256": fields["verdict_sha256"], "sufficiency_sha256": fields["sufficiency_sha256"],
              "upstream_protocol_sha256": fields["upstream_protocol_sha256"]}
    if "reply_instructions_sha256" in fields:
        hashes["reply_instructions_sha256"] = fields["reply_instructions_sha256"]
    return hashes


# --------------------------------------------------------------------------- rendering (offline)


def output_tokens(declaration):
    if declaration["judge"] in VERTEX_JUDGES:
        return declaration["execution"]["max_output_tokens_per_request"]
    return (declaration.get("request_limits") or {}).get("max_output_tokens_per_request")


def render(judge, item, stage, prompt_function, declaration):
    """Exact transport body for one request, its model-visible character count and, for Vertex, the count body."""
    controls = jc.vertex_request_controls(declaration) if judge in VERTEX_JUDGES else None
    instructed = controls is not None and controls["instructed"]
    messages = jc.judge_messages(item, stage, prompt_function, reply_instruction=instructed)
    characters = sum(len(message["content"]) for message in messages)
    count_body = None
    if judge in VERTEX_JUDGES:
        model = VERTEX_JUDGES[judge]
        try:
            if controls is None:  # version 1 declaration: body unchanged, no reply constraint
                body = vertex.payload(messages, output_tokens(declaration))
                count_body = vertex.count_payload(messages, model=model)
            elif instructed:  # version 3: reply-format system line, no output_config.format
                body = vertex.payload(messages, output_tokens(declaration), model=model,
                                      thinking=controls["thinking"], effort=controls["effort"])
                count_body = vertex.count_payload(messages, model=model)
            else:
                schema = jc.REPLY_SCHEMAS[stage]["schema"]
                body = vertex.payload(messages, output_tokens(declaration), model=model, schema=schema,
                                      thinking=controls["thinking"], effort=controls["effort"])
                count_body = vertex.count_payload(messages, model=model, schema=schema)
        except vertex.VertexError as error:
            raise CalibrationError("render_" + str(error)) from None
    elif judge == "qwen-local":
        body = {"model": jc.QWEN_MODEL, "messages": messages, "temperature": 0, "n": 1,
                "max_tokens": output_tokens(declaration), "enable_thinking": False}
    else:
        spec = jc.JUDGE_PROMPTS[stage]["jevk5"]
        prompt = messages[0]["content"] if stage == "verdict" else (
            messages[0]["content"] + "\n\n" + messages[1]["content"])
        body = {"state": {spec["state_field"]: prompt},
                "question": {"type": "choice", "instructions": spec["instructions"],
                             "criteria": list(spec["criteria"])}}
        characters = len(prompt) + len(spec["instructions"])
    require(len(canonical(body)) <= MAXIMUM_REQUEST_BYTES, "request_bound_exceeded")
    return body, characters, count_body


def build_plan(items, declaration, prompt_function):
    """Deterministic order: replicate, then item ID, then stage (sufficiency before verdict). A
    verdict-only declaration (``stages_per_item: ["verdict"]``) plans no sufficiency request."""
    judge = declaration["judge"]
    stages = jc.declared_stages(declaration)
    rendered = {}
    for item in items:
        for stage in stages:
            rendered[(item["item_id"], stage)] = render(judge, item, stage, prompt_function, declaration)
    plan = []
    for replicate in range(1, declaration["execution"]["replicates"] + 1):
        for item in items:
            for stage in stages:
                body, characters, count_body = rendered[(item["item_id"], stage)]
                plan.append({"request_id": f"{item['item_id']}-{stage}-r{replicate}", "item_id": item["item_id"],
                             "stage": stage, "replicate": replicate, "body": body,
                             "body_sha256": sha256_bytes(canonical(body)), "characters": characters,
                             "body_bytes": len(canonical(body)), "count_body": count_body})
    return plan


def _controls(declaration):
    return jc.vertex_request_controls(declaration) if declaration["judge"] in VERTEX_JUDGES else None


def reply_constraint(declaration):
    """The pinned reply-schema block for a v2 Vertex declaration, else None (no structured outputs)."""
    controls = _controls(declaration)
    return jc.reply_schemas_declaration() if controls is not None and controls["structured"] else None


def reply_format(declaration):
    """The pinned reply-format block for a v3 Vertex declaration (instructed JSON), else None."""
    controls = _controls(declaration)
    return jc.reply_format_declaration() if controls is not None and controls["instructed"] else None


def reply_mode(declaration):
    """(structured, instructed) parsing flags for a Vertex transport, from the declaration."""
    controls = _controls(declaration)
    return (bool(controls and controls["structured"]), bool(controls and controls["instructed"]))


def request_fields(plan):
    """Field names of the rendered bodies (no values except the fixed thinking object)."""
    shapes = {}
    for entry in plan:
        if entry["stage"] in shapes:
            continue
        body, count = entry["body"], entry.get("count_body")
        shapes[entry["stage"]] = {
            "generation": sorted(body),
            "output_config": sorted(body["output_config"]) if isinstance(body.get("output_config"), dict) else None,
            "thinking": body.get("thinking") if isinstance(body.get("thinking"), dict) and set(body["thinking"]) == {
                "type"} else None,
            "count": sorted(count) if count is not None else None}
    return shapes


def plan_sha256(plan):
    return sha256_bytes(canonical([[entry["request_id"], entry["body_sha256"]] for entry in plan]))


def median_low(values):
    ordered = sorted(values)
    return ordered[(len(ordered) - 1) // 2] if ordered else None


# --------------------------------------------------------------------------- transports


class VertexTransport:
    kind = "vertex"

    def __init__(self, model, http_fn=None, token_fn=None, structured=False, instructed=False):
        vertex.require_model(model)
        require(not (structured and instructed), "reply_mode_invalid")
        self.model = model
        self.http = http_fn or vertex.post
        self.tokens = token_fn or vertex.AccessTokens()
        # structured: v2 declaration (output_config.format); instructed: v3 declaration (reply-format
        # system line). execute() sets both from the declaration.
        self.structured = structured
        self.instructed = instructed

    def open(self, capture_dir):
        return None

    def close(self):
        return None

    def send(self, kind, body, name):
        url = vertex.count_url() if kind == "count" else vertex.generation_url(model=self.model)
        try:
            token = self.tokens()
            raw = self.http(url, body, token)
        except vertex.VertexError as error:
            raise Infrastructure(str(error)) from None
        except Exception:
            raise Infrastructure("transport_failed") from None
        if type(raw) is not bytes or len(raw) > MAXIMUM_RESPONSE_BYTES:
            raise Infrastructure("response_bound_exceeded")
        if token.encode() in raw:
            raise Infrastructure("credential_echo_refused")
        return raw

    def probe(self):
        """Unbilled access probe: an empty generation body must be refused with HTTP 400, not 404."""
        try:
            self.send("generation", {}, "probe")
        except Infrastructure as error:
            if str(error) == "http_status_400":
                return "reachable"
            if str(error) == "http_status_404":
                raise Halt("model_access_denied") from None
            raise Halt("probe_" + str(error)) from None
        raise Halt("probe_unexpected_success")

    @staticmethod
    def count(raw):
        try:
            return vertex.parse_count(raw)
        except vertex.VertexError:
            raise Halt("count_invalid") from None

    @staticmethod
    def usage(raw):
        try:
            return vertex.parse_usage(vertex._strict_json(raw))
        except vertex.VertexError:
            return None

    def text(self, raw):
        try:
            text, _usage = vertex.parse_response(raw, model=self.model)
        except vertex.VertexError as error:
            raise ResponseInvalid(str(error)) from None
        return text

    @staticmethod
    def metadata(raw):
        return vertex.response_metadata(raw)

    def _json_label(self, raw, stage, parser):
        try:
            text, _usage = vertex.parse_response(raw, model=self.model)
        except vertex.VertexError as error:
            code = str(error)
            if code == "refusal_or_output_invalid" and vertex.response_metadata(raw)["stop_reason"] == "refusal":
                code = "refusal"
            return "response_invalid", None, code
        label = parser(text, stage)
        if label is None:
            return "parse_failed", None, "output_off_schema"
        return "completed", label, None

    def structured_label(self, raw, stage):
        """(status, label, failure) for a structured reply. Strict: a refusal, a truncated reply or
        anything off schema is a recorded failure with a fixed code, never a label."""
        return self._json_label(raw, stage, jc.parse_structured_reply)

    def instructed_label(self, raw, stage):
        """(status, label, failure) for an instructed JSON reply (v3). The same fixed codes as
        structured_label; the parser also tolerates one surrounding Markdown code fence."""
        return self._json_label(raw, stage, jc.parse_instructed_reply)

    def reply_wrapper(self, raw, stage):
        """Wrapper of a completed instructed reply, bare or fenced, else None. Metadata only, no text."""
        try:
            text, _usage = vertex.parse_response(raw, model=self.model)
        except vertex.VertexError:
            return None
        return jc.parse_instructed_reply_detail(text, stage)[1]


class QwenTransport:
    kind = "qwen"

    def __init__(self, http_fn=None):
        self.http = http_fn or qwen_post

    def open(self, capture_dir):
        return None

    def close(self):
        return None

    def send(self, kind, body, name):
        try:
            raw = self.http(jc.QWEN_ENDPOINT, canonical(body))
        except Infrastructure:
            raise
        except Exception:
            raise Infrastructure("transport_failed") from None
        if type(raw) is not bytes or len(raw) > MAXIMUM_RESPONSE_BYTES:
            raise Infrastructure("response_bound_exceeded")
        return raw

    @staticmethod
    def usage(raw):
        try:
            usage = json.loads(raw).get("usage")
        except (ValueError, AttributeError):
            return None
        if isinstance(usage, dict) and all(type(usage.get(key)) is int and usage[key] >= 0
                                           for key in ("prompt_tokens", "completion_tokens")):
            return {"input_tokens": usage["prompt_tokens"], "output_tokens": usage["completion_tokens"]}
        return None

    @staticmethod
    def text(raw):
        try:
            value = vertex._strict_json(raw)
        except vertex.VertexError:
            raise ResponseInvalid("json_invalid") from None
        if not isinstance(value, dict) or value.get("model") != jc.QWEN_MODEL:
            raise ResponseInvalid("model_identity_mismatch")
        choices = value.get("choices")
        if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
            raise ResponseInvalid("output_invalid")
        message = choices[0].get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant" or not isinstance(
                message.get("content"), str):
            raise ResponseInvalid("output_invalid")
        if choices[0].get("finish_reason") != "stop":
            raise ResponseInvalid("response_incomplete")
        return message["content"]


def qwen_post(url, raw_body):
    """Loopback only, no proxy, no redirect; HTTP errors keep the status only."""
    import local_longmemeval_qa as qa
    from urllib.error import HTTPError
    require(url == jc.QWEN_ENDPOINT, "endpoint_refused")
    settings = qa.local_settings(url.rsplit("/chat/completions", 1)[0])
    require(settings["endpoint"] == jc.QWEN_ENDPOINT, "endpoint_refused")
    try:
        return qa.call_local(settings, raw_body, timeout=120)
    except HTTPError as error:
        raise Infrastructure("http_status_" + str(error.code)) from None
    except Exception:
        raise Infrastructure("transport_failed") from None


class JevTransport:
    kind = "jevk5"

    def __init__(self, executable_sha256, client_factory=None, executable_digest=None):
        import jevk5_saved_qa as jev
        self.jev = jev
        self.expected_executable = executable_sha256
        self.factory = client_factory or (lambda directory: jev.StdioMCP(directory))
        self.executable_digest = executable_digest or (
            lambda: jev.digest(jev.read_file(Path(jev.COMMAND[0]), 1024 * 1024 * 1024)))
        self.client = None
        self.cache_hits = 0

    def open(self, capture_dir):
        try:
            observed = self.executable_digest()
        except Exception:
            raise Halt("executable_unreadable") from None
        if observed != self.expected_executable:
            raise Halt("executable_changed")
        try:
            self.client = self.factory(capture_dir)
            self.client.connect()
        except self.jev.SavedQAError as error:
            raise Halt("mcp_" + str(error) if not str(error).startswith(("mcp_", "jev_")) else str(error)) from None
        except Exception:
            raise Halt("mcp_connect_failed") from None

    def close(self):
        if self.client is not None:
            self.client.close()

    def send(self, kind, body, name):
        try:
            result = self.client.call("tools/call", {"name": "jevk5_decide", "arguments": body}, name)
        except self.jev.SavedQAError as error:
            raise Infrastructure(str(error)) from None
        except Exception:
            raise Infrastructure("mcp_call_failed") from None
        return canonical(result)

    @staticmethod
    def usage(raw):
        return None

    def decision(self, raw):
        try:
            return self.jev.validate_decision(self.jev.strict_json(raw))
        except self.jev.SavedQAError as error:
            raise ResponseInvalid(str(error)) from None


def label_from(transport, raw, stage):
    """(status, label, failure) for one response. Unparseable output is recorded, never coerced."""
    if isinstance(transport, JevTransport):
        try:
            decision = transport.decision(raw)
        except ResponseInvalid as error:
            return "response_invalid", None, str(error)
        mapping = jc.JUDGE_PROMPTS[stage]["jevk5"]["mapping"]
        return "completed", mapping[decision["choice"]], None
    if isinstance(transport, VertexTransport) and transport.instructed:
        return transport.instructed_label(raw, stage)
    if isinstance(transport, VertexTransport) and transport.structured:
        return transport.structured_label(raw, stage)
    try:
        text = transport.text(raw)
    except ResponseInvalid as error:
        return "response_invalid", None, str(error)
    label = jc.parse_verdict_text(text) if stage == "verdict" else jc.parse_sufficiency_text(text)
    if label is None:
        return "parse_failed", None, "output_unparseable"
    return "completed", label, None


def make_transport(declaration, *, vertex_http=None, vertex_tokens=None, qwen_http=None, jev_factory=None,
                   jev_executable_digest=None):
    judge = declaration["judge"]
    if judge in VERTEX_JUDGES:
        structured, instructed = reply_mode(declaration)
        return VertexTransport(VERTEX_JUDGES[judge], vertex_http, vertex_tokens, structured=structured,
                               instructed=instructed)
    if judge == "qwen-local":
        return QwenTransport(qwen_http)
    return JevTransport(declaration["provider"]["executable_sha256"], jev_factory, jev_executable_digest)


# --------------------------------------------------------------------------- private captures


def write_json(path: Path, value):
    return jc.write_private_json(path, value)


class Captures:
    """No-clobber private files. Attempt N of request R uses the stem ``R-aN``."""

    def __init__(self, directory: Path):
        self.directory = directory

    def path(self, stem, suffix):
        require(NAME.fullmatch(stem), "capture_name_invalid")
        return self.directory / f"{stem}-{suffix}.json"

    def attempts(self, request_id):
        found = []
        pattern = re.compile(re.escape(request_id) + r"-a(\d+)-intent\.json\Z")
        for path in self.directory.iterdir():
            match = pattern.match(path.name)
            if match:
                found.append(int(match.group(1)))
        return sorted(found)

    def read(self, stem, suffix):
        path = self.path(stem, suffix)
        return path.read_bytes() if path.exists() else None


def authenticate_attempt(captures, transport, entry, attempt, kind="generation"):
    """Re-derive a prior attempt from its captures; any mismatch refuses the resume."""
    stem = f"{entry['request_id'] if kind == 'generation' else entry['count_stem']}-a{attempt}"
    intent = json.loads(captures.read(stem, "intent"))
    request = captures.read(stem, "request")
    require(intent.get("request_sha256") == entry["count_sha256" if kind == "count" else "body_sha256"]
            and request is not None and sha256_bytes(request) == intent["request_sha256"], "resume_capture_mismatch")
    receipt_raw = captures.read(stem, "receipt")
    if receipt_raw is None:
        return {"attempt": attempt, "status": "interrupted", "intent": intent}
    receipt = json.loads(receipt_raw)
    require(receipt.get("request_sha256") == intent["request_sha256"] and receipt.get("attempt") == attempt,
            "resume_capture_mismatch")
    if receipt.get("response_sha256") is not None:
        response = captures.read(stem, "response")
        require(response is not None and sha256_bytes(response) == receipt["response_sha256"],
                "resume_capture_mismatch")
        if kind == "count":
            require(transport.count(response) == receipt.get("input_tokens"), "resume_capture_mismatch")
        else:
            status, label, failure = label_from(transport, response, entry["stage"])
            require((status, label, failure) == (receipt.get("status"), receipt.get("label"), receipt.get("failure")),
                    "resume_capture_mismatch")
    else:
        require(receipt.get("status") in ("infrastructure_failed", "not_dispatched_over_character_bound"),
                "resume_capture_mismatch")
    return {**receipt, "intent": intent}


# --------------------------------------------------------------------------- execution


class Session:
    def __init__(self, declaration, plan, transport, captures, prior):
        self.declaration, self.plan, self.transport, self.captures = declaration, plan, transport, captures
        self.judge = declaration["judge"]
        self.vertex = self.judge in VERTEX_JUDGES
        execution = declaration["execution"]
        self.retries = execution["automatic_retries"]
        self.stop = execution["stop_on_first_infrastructure_failure"]
        if self.vertex:
            budget = declaration["budget"]
            self.max_generations = budget["max_generation_requests"]
            self.max_counts = budget["max_count_requests"]
            self.cap = int((Decimal(str(budget["spending_cap_usd"])) * 1000000).to_integral_value())
            pricing = declaration["pricing"]
            self.pricing = vertex.Pricing(pricing["input_usd_per_million_tokens"],
                                          pricing["output_usd_per_million_tokens"])
            self.max_characters = None
        else:
            limits = declaration["request_limits"]
            self.max_generations = limits["max_requests"]
            self.max_counts = 0
            self.cap = None
            self.pricing = None
            self.max_characters = limits["max_prompt_characters"]
        self.latest = prior["latest"]
        self.counts = prior["counts"]
        self.generation_intents = prior["generation_intents"]
        self.count_intents = prior["count_intents"]
        self.reserved = prior["reserved_microusd"]
        self.observed = {"input_tokens": 0, "output_tokens": 0, "microusd": 0, "thinking_tokens": 0}
        self.stop_reasons = Counter()
        self.reply_wrappers = Counter()
        self.calls = Counter()
        self.probe_result = None

    # ---- dispatch with capture

    def _dispatch(self, kind, stem, body, intent_extra):
        raw_request = canonical(body)
        jc.write_private(self.captures.path(stem, "request"), raw_request)
        intent = {"attempt": int(stem.rsplit("-a", 1)[1]), "kind": kind, "request_sha256": sha256_bytes(raw_request),
                  **intent_extra}
        write_json(self.captures.path(stem, "intent"), intent)
        self.calls[kind] += 1
        started = time.monotonic()
        try:
            raw = self.transport.send(kind, body, stem)
        except Infrastructure as error:
            return None, str(error), time.monotonic() - started
        jc.write_private(self.captures.path(stem, "response"), raw)
        return raw, None, time.monotonic() - started

    def _record(self, stem, request_id, result):
        write_json(self.captures.path(stem, "receipt"), result)
        self.latest[request_id] = result

    def count(self, entry):
        key = entry["count_sha256"]
        if key in self.counts:
            return self.counts[key]
        if self.count_intents >= self.max_counts:
            raise Halt("count_limit_reached")
        attempt = len(self.captures.attempts(entry["count_stem"])) + 1
        stem = f"{entry['count_stem']}-a{attempt}"
        self.count_intents += 1
        raw, failure, elapsed = self._dispatch("count", stem, entry["count_body"], {})
        receipt = {"attempt": attempt, "kind": "count", "request_sha256": entry["count_sha256"],
                   "elapsed_seconds": round(elapsed, 6)}
        if raw is None:
            write_json(self.captures.path(stem, "receipt"), {**receipt, "status": "infrastructure_failed",
                                                              "failure": failure})
            raise Halt(failure)
        counted = self.transport.count(raw)
        write_json(self.captures.path(stem, "receipt"), {**receipt, "status": "completed", "input_tokens": counted,
                                                          "response_sha256": sha256_bytes(raw)})
        self.counts[key] = counted
        return counted

    def generate(self, entry, session_attempts):
        rid = entry["request_id"]
        attempt = len(self.captures.attempts(rid)) + 1
        stem = f"{rid}-a{attempt}"
        receipt = {"request_id": rid, "attempt": attempt, "request_sha256": entry["body_sha256"],
                   "stage": entry["stage"], "replicate": entry["replicate"]}
        if self.max_characters is not None and entry["characters"] > self.max_characters:
            jc.write_private(self.captures.path(stem, "request"), canonical(entry["body"]))
            write_json(self.captures.path(stem, "intent"), {"attempt": attempt, "kind": "generation",
                                                            "request_sha256": entry["body_sha256"],
                                                            "dispatched": False})
            result = {**receipt, "status": "not_dispatched_over_character_bound", "label": None,
                      "failure": "prompt_characters_over_declared_bound"}
            self._record(stem, rid, result)
            return result
        if self.generation_intents >= self.max_generations:
            raise Halt("request_limit_reached")
        extra = {}
        if self.vertex:
            counted = self.count(entry)
            reserve = self.pricing.microusd(counted, entry["body"]["max_tokens"])
            if self.reserved + reserve > self.cap:
                raise Halt("cost_cap_exceeded")
            self.reserved += reserve
            extra = {"counted_input_tokens": counted, "reserved_microusd": reserve}
        self.generation_intents += 1
        session_attempts[rid] += 1
        raw, failure, elapsed = self._dispatch("generation", stem, entry["body"], extra)
        receipt["elapsed_seconds"] = round(elapsed, 6)
        if raw is None:
            result = {**receipt, "status": "infrastructure_failed", "label": None, "failure": failure}
            self._record(stem, rid, result)
            return result
        usage = self.transport.usage(raw)
        if usage is not None:
            self.observed["input_tokens"] += usage["input_tokens"]
            self.observed["output_tokens"] += usage["output_tokens"]
            if self.vertex:
                self.observed["microusd"] += self.pricing.microusd(usage["input_tokens"], usage["output_tokens"])
        status, label, parse_failure = label_from(self.transport, raw, entry["stage"])
        if isinstance(self.transport, JevTransport) and status == "completed":
            self.transport.cache_hits += self.transport.decision(raw)["cache"]["hit"] is True
        result = {**receipt, "status": status, "label": label, "failure": parse_failure,
                  "response_sha256": sha256_bytes(raw), "usage": usage}
        if self.vertex:
            metadata = self.transport.metadata(raw)  # stop reason and thinking tokens; no text
            result.update(metadata)
            if self.transport.instructed:
                wrapper = self.transport.reply_wrapper(raw, entry["stage"]) if status == "completed" else None
                result["reply_wrapper"] = wrapper
                if wrapper is not None:
                    self.reply_wrappers[wrapper] += 1
            self.stop_reasons[metadata["stop_reason"] or "unknown"] += 1
            self.observed["thinking_tokens"] += metadata["thinking_tokens"] or 0
        self._record(stem, rid, result)
        if parse_failure in IDENTITY_FAILURES:
            raise Halt(parse_failure)
        return result

    # ---- session

    def pending(self):
        return [entry for entry in self.plan
                if (self.latest.get(entry["request_id"]) or {}).get("status") not in TERMINAL]

    def run(self):
        pending = self.pending()
        if not pending:
            return
        if self.vertex:
            if self.declaration["execution"].get("unbilled_access_probe_before_first_generation"):
                self.calls["probe"] += 1
                self.probe_result = self.transport.probe()
            # Free counting pass, then refuse the whole session when its worst case exceeds the cap.
            projected = self.reserved
            for entry in pending:
                projected += self.pricing.microusd(self.count(entry), entry["body"]["max_tokens"])
            if projected > self.cap:
                raise Halt("projected_cost_exceeds_cap")
        session_attempts = Counter()
        for entry in pending:
            while True:
                result = self.generate(entry, session_attempts)
                if result["status"] != "infrastructure_failed":
                    break
                if session_attempts[entry["request_id"]] <= self.retries:
                    continue
                if self.stop:
                    raise Halt(result["failure"])
                break


def prior_state(captures, transport, plan):
    """Authenticate every earlier attempt. Reservations of earlier sessions always count."""
    state = {"latest": {}, "counts": {}, "generation_intents": 0, "count_intents": 0, "reserved_microusd": 0,
             "prior_attempts": 0, "interrupted": 0}
    seen_counts = set()
    for entry in plan:
        for attempt in captures.attempts(entry["request_id"]):
            record = authenticate_attempt(captures, transport, entry, attempt)
            state["prior_attempts"] += 1
            if record["intent"].get("dispatched", True):
                state["generation_intents"] += 1
            state["reserved_microusd"] += record["intent"].get("reserved_microusd", 0)
            if record["status"] == "interrupted":
                state["interrupted"] += 1
            state["latest"][entry["request_id"]] = record
        if entry.get("count_body") is not None and entry["count_stem"] not in seen_counts:
            seen_counts.add(entry["count_stem"])
            for attempt in captures.attempts(entry["count_stem"]):
                record = authenticate_attempt(captures, transport, entry, attempt, kind="count")
                state["count_intents"] += 1
                if record.get("status") == "completed":
                    state["counts"][entry["count_sha256"]] = record["input_tokens"]
    return state


def labels_document(manifest, declaration, declaration_sha, plan, latest, complete):
    replicates = declaration["execution"]["replicates"]
    table = {}
    for entry in plan:
        record = latest.get(entry["request_id"]) or {}
        label = record.get("label") if record.get("status") == "completed" else None
        row = table.setdefault(entry["item_id"], [{"verdict": None, "sufficiency": None} for _ in range(replicates)])
        row[entry["replicate"] - 1][entry["stage"]] = label
    labels = {item_id: rows for item_id, rows in sorted(table.items())
              if any(value is not None for row in rows for value in row.values())}
    document = {"format": jc.LABELS_FORMAT, "set_id": manifest["set_id"], "items_sha256": manifest["items_sha256"],
                "judge": jc.JUDGE_SCORE_NAMES[declaration["judge"]], "runner_judge": declaration["judge"],
                "declaration_sha256": declaration_sha, "prompts": prompt_hashes(declaration),
                "replicates": replicates, "complete": complete, "labels": labels}
    if reply_constraint(declaration) is not None:
        document["reply_schemas"] = reply_constraint(declaration)
    if reply_format(declaration) is not None:
        document["reply_format"] = reply_format(declaration)
    return document


def summarize(plan, latest):
    by_status, by_stage, failures = Counter(), {stage: Counter() for stage in jc.STAGES}, Counter()
    for entry in plan:
        record = latest.get(entry["request_id"]) or {}
        status = record.get("status", "not_attempted")
        by_status[status] += 1
        by_stage[entry["stage"]][status] += 1
        if record.get("failure"):
            failures[record["failure"]] += 1
        if status == "completed":
            by_stage[entry["stage"]]["label:" + record["label"]] += 1
    return {"by_status": dict(by_status), "by_stage": {stage: dict(counts) for stage, counts in by_stage.items()},
            "failure_codes": dict(failures)}


def destination_state(output: Path, declaration_sha):
    if not output.exists():
        return "fresh"
    run_path = output / "run.json"
    if run_path.exists() and jc.load_json(run_path).get("declaration_sha256") == declaration_sha:
        return "resumable"
    return "conflict"


def prepare(set_dir: Path, declaration_path: Path, prompt_function):
    manifest, items = load_set(set_dir)
    declaration, declaration_sha = load_declaration(declaration_path)
    problems = jc.check_declaration(declaration, set_dir)
    require(declaration.get("judge") in JUDGES, "judge_unknown")
    execution = declaration.get("execution") or {}
    require(type(execution.get("replicates")) is int and 0 < execution["replicates"] <= jc.MAX_REPLICATES,
            "replicates_invalid")
    if declaration["judge"] != "jevk5":
        limit = output_tokens(declaration)
        require(type(limit) is int and limit > 0, "output_limit_invalid")
    plan = build_plan(items, declaration, prompt_function)
    for entry in plan:
        if entry["count_body"] is not None:
            entry["count_sha256"] = sha256_bytes(canonical(entry["count_body"]))
            entry["count_stem"] = f"count-{entry['item_id']}-{entry['stage']}"
    return manifest, items, declaration, declaration_sha, problems, plan


def dry_run(set_dir: Path, declaration_path: Path, output: Path, prompt_function, root: Path = jc.ROOT,
            git_ignore: bool = True):
    """Validates and renders in memory; writes nothing and makes no network or model call."""
    manifest, items, declaration, declaration_sha, problems, plan = prepare(set_dir, declaration_path,
                                                                            prompt_function)
    output = jc.check_private_destination(output, root, git_ignore)
    unique = {(entry["item_id"], entry["stage"]): entry for entry in plan}
    by_stage = {}
    for stage in jc.declared_stages(declaration):
        characters = [entry["characters"] for entry in unique.values() if entry["stage"] == stage]
        by_stage[stage] = {"unique_requests": len(characters),
                           "requests": sum(1 for entry in plan if entry["stage"] == stage),
                           "characters_p50": median_low(characters), "characters_max": max(characters)}
    characters = [entry["characters"] for entry in unique.values()]
    bound = (declaration.get("request_limits") or {}).get("max_prompt_characters")
    over = None
    if type(bound) is int:
        over = {"unique_requests": sum(1 for entry in unique.values() if entry["characters"] > bound),
                "requests": sum(1 for entry in plan if entry["characters"] > bound), "bound": bound}
    return {"mode": "dry-run", "network_calls": 0, "files_written": 0, "judge": declaration["judge"],
            "set_id": manifest["set_id"], "items_sha256": manifest["items_sha256"], "items": len(items),
            "replicates": declaration["execution"]["replicates"], "requests": len(plan),
            "unique_requests": len(unique),
            "count_requests_needed": len(unique) if declaration["judge"] in VERTEX_JUDGES else 0,
            "by_stage": by_stage, "characters_p50": median_low(characters), "characters_max": max(characters),
            "request_body_bytes_max": max(entry["body_bytes"] for entry in plan),
            "over_declared_character_bound": over, "plan_sha256": plan_sha256(plan),
            "prompts": prompt_hashes(declaration), "reply_schemas": reply_constraint(declaration),
            "reply_format": reply_format(declaration),
            "max_output_tokens_per_request": output_tokens(declaration),
            "request_fields": request_fields(plan) if declaration["judge"] in VERTEX_JUDGES else None,
            "declaration_sha256": declaration_sha,
            "declaration_complete": not problems, "declaration_problems": problems,
            "destination": destination_state(output, declaration_sha)}


def execute(set_dir: Path, declaration_path: Path, output: Path, prompt_function, *, resume=False,
            root: Path = jc.ROOT, transport=None, git_ignore: bool = True):
    """Dispatches only after check-declaration passes. Returns a metadata-only report."""
    manifest, items, declaration, declaration_sha, problems, plan = prepare(set_dir, declaration_path,
                                                                            prompt_function)
    if problems:
        raise CalibrationError("declaration_incomplete")
    output = jc.check_private_destination(output, root, git_ignore)
    labels_path = jc.check_private_destination(root / declaration["outputs"]["labels_path"], root, git_ignore)
    require(not labels_path.exists(), "labels_path_exists")
    run_record = {"format": RUN_FORMAT, "version": VERSION, "judge": declaration["judge"],
                  "declaration_sha256": declaration_sha, "set_id": manifest["set_id"],
                  "items_sha256": manifest["items_sha256"], "prompts": prompt_hashes(declaration),
                  "plan_sha256": plan_sha256(plan), "planned_requests": len(plan),
                  "replicates": declaration["execution"]["replicates"]}
    if reply_constraint(declaration) is not None:  # absent for v1, so v1 run records still match on resume
        run_record["reply_schemas"] = reply_constraint(declaration)
    if reply_format(declaration) is not None:  # v3 only, so v1 and v2 run records are unchanged
        run_record["reply_format"] = reply_format(declaration)
    captures_dir = output / "captures"
    if resume:
        require(destination_state(output, declaration_sha) == "resumable", "resume_declaration_mismatch")
        stored = jc.load_json(output / "run.json")
        require(stored == run_record, "resume_plan_mismatch")
        require(sha256_bytes((output / "declaration.json").read_bytes()) == sha256_bytes(
            json.dumps(declaration, ensure_ascii=False, sort_keys=True, indent=1).encode() + b"\n"),
            "resume_declaration_mismatch")
    else:
        require(not output.exists(), "destination_exists")
        jc.make_private_directory(output, fresh=True)
        jc.write_private_json(output / "declaration.json", declaration)
        jc.write_private_json(output / "run.json", run_record)
        jc.make_private_directory(captures_dir, fresh=True)
    session_number = len(list(output.glob("report-session-*.json"))) + 1
    transport = transport or make_transport(declaration)
    if isinstance(transport, VertexTransport):  # the declaration decides how replies are parsed
        transport.structured, transport.instructed = reply_mode(declaration)
    captures = Captures(captures_dir)
    prior = prior_state(captures, transport, plan)
    session = Session(declaration, plan, transport, captures, prior)
    started = time.monotonic()
    halt = None
    mcp_dir = output / f"mcp-session-{session_number:02d}"
    try:
        if session.pending():
            if isinstance(transport, JevTransport):
                jc.make_private_directory(mcp_dir, fresh=True)
            transport.open(mcp_dir)
            session.run()
    except Halt as error:
        halt = str(error)
    except CalibrationError as error:
        halt = str(error)
    except KeyboardInterrupt:
        halt = "interrupted"
    finally:
        transport.close()
    complete = all((session.latest.get(entry["request_id"]) or {}).get("status") in TERMINAL for entry in plan)
    labels = labels_document(manifest, declaration, declaration_sha, plan, session.latest, complete)
    labels_sha = jc.write_private_json(output / f"labels-session-{session_number:02d}.json", labels)
    if complete:
        jc.write_private_json(labels_path, labels)
    report = {"format": REPORT_FORMAT, "version": VERSION, "judge": declaration["judge"],
              "score_name": jc.JUDGE_SCORE_NAMES[declaration["judge"]], "session": session_number,
              "set_id": manifest["set_id"], "items_sha256": manifest["items_sha256"],
              "declaration_sha256": declaration_sha, "prompts": prompt_hashes(declaration),
              "plan_sha256": plan_sha256(plan),
              "planned_requests": len(plan), "complete": complete, "halt_reason": halt,
              "prior_attempts_reused": prior["prior_attempts"], "prior_interrupted_attempts": prior["interrupted"],
              "session_calls": dict(session.calls), "generation_requests_total": session.generation_intents,
              "count_requests_total": session.count_intents, **summarize(plan, session.latest),
              "labelled_items": len(labels["labels"]), "labels_sha256": labels_sha,
              "labels_written_to_declared_path": complete, "elapsed_seconds": round(time.monotonic() - started, 3),
              "controller_sha256": sha256_bytes(Path(__file__).read_bytes())}
    if session.vertex:
        report["access_probe"] = session.probe_result
        report["reply_schemas"] = reply_constraint(declaration)
        report["reply_format"] = reply_format(declaration)
        report["request_fields"] = request_fields(plan)
        report["replies_session"] = {"stop_reasons": dict(session.stop_reasons),
                                     "thinking_tokens": session.observed["thinking_tokens"]}
        if transport.instructed:
            report["replies_session"]["wrappers"] = dict(session.reply_wrappers)
        report["cost"] = {"cap_usd": str(Decimal(session.cap) / 1000000),
                          "reserved_usd_total": str(Decimal(session.reserved) / 1000000),
                          "observed_usd_session": str(Decimal(session.observed["microusd"]) / 1000000),
                          "observed_input_tokens_session": session.observed["input_tokens"],
                          "observed_output_tokens_session": session.observed["output_tokens"],
                          "basis": "declared prices; counted input plus maximum output reserved before each "
                                   "generation; reservations never decrease"}
    elif declaration["judge"] == "qwen-local":
        report["usage_session"] = {"input_tokens": session.observed["input_tokens"],
                                   "output_tokens": session.observed["output_tokens"]}
    else:
        report["cache_hits_session"] = transport.cache_hits
    jc.write_private_json(output / f"report-session-{session_number:02d}.json", report)
    return report


# --------------------------------------------------------------------------- CLI


def main(argv=None, **transport_overrides):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--set", type=Path, required=True, help="private calibration set directory")
    parser.add_argument("--declaration", type=Path, required=True, help="filled run declaration (JSON)")
    parser.add_argument("--output", type=Path, required=True, help="private run directory under .build")
    parser.add_argument("--protocol", type=Path, default=jc.DEFAULT_PROTOCOL,
                        help="upstream LongMemEval src/evaluation/evaluate_qa.py (hash pinned)")
    parser.add_argument("--execute", action="store_true", help="dispatch requests; without it, dry run only")
    parser.add_argument("--resume", action="store_true", help="continue an existing run of the same declaration")
    args = parser.parse_args(argv)
    try:
        require(not args.resume or args.execute, "resume_requires_execute")
        prompt_function = jc.load_upstream_prompt_function(args.protocol)
        if not args.execute:
            print(json.dumps(dry_run(args.set, args.declaration, args.output, prompt_function), indent=1))
            return 0
        declaration, _ = load_declaration(args.declaration)
        problems = jc.check_declaration(declaration, args.set)
        if problems:
            print(json.dumps({"executed": False, "declaration_complete": False, "problems": problems}, indent=1))
            return 2
        transport = make_transport(declaration, **transport_overrides) if transport_overrides else None
        report = execute(args.set, args.declaration, args.output, prompt_function, resume=args.resume,
                         transport=transport)
        print(json.dumps(report, indent=1))
        return 0 if report["complete"] else 3
    except CalibrationError as error:
        print(json.dumps({"error": str(error)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
