#!/usr/bin/env python3
"""Vertex AI adapter for Claude models in the GCP llm-train project, for evaluation tooling only.

Authentication uses Google Application Default Credentials through the gcloud
CLI. No API key is stored, read or passed, and the short-lived access token
lives only in memory. The project ID is explicit on every request because the
workstation's default gcloud project is a different one. Errors carry fixed
codes; response and error bodies are never printed. The Boros application
does not import this module and still processes text only through local
model servers.

The model is chosen per run from MODELS. Every function that depends on the
model takes a `model` keyword whose default is MODEL (Opus), so existing callers
keep their Opus behavior unchanged.
"""
from __future__ import annotations

from decimal import Decimal, InvalidOperation, ROUND_CEILING
import hashlib
import json
import re
import subprocess
import threading
import time
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

PROJECT_ID = "llm-train-482420"  # display name "llm-train"
LOCATION = "global"
MODEL = "claude-opus-5-5"  # default for existing callers
# Models a run may select. By default both are treated alike: no sampling
# parameter and no `thinking` field. Omitting `thinking` runs adaptive thinking on
# both models, and its tokens count against `max_tokens` (observed October 9, 2026
# on Sonnet 5.5 through usage.output_tokens_details.thinking_tokens). The adapter
# never sends `temperature`, `top_p` or `top_k`.
MODELS = ("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5")
# Opt-in generation controls (see payload). The defaults send none of them, so
# existing callers keep their request bodies byte for byte.
EFFORTS = ("low", "medium", "high", "xhigh", "max")
# `between_tools` turns thinking off on Sonnet 5.5 only. It takes no other field
# and is accepted only at effort `high` or below (Sonnet's default effort is high).
# Opus 5.5 thinking cannot be disabled (`disabled` and `budget_tokens` return
# HTTP 400); its depth is controlled by `output_config.effort` alone.
BETWEEN_TOOLS = {"type": "between_tools"}
BETWEEN_TOOLS_MODELS = ("claude-sonnet-5-5",)
BETWEEN_TOOLS_EFFORTS = ("low", "medium", "high")
# `disabled` turns thinking off on Haiku 5.5 only, also at effort `high` or below
# (Haiku's default effort is medium). Haiku is a reader candidate in the reader
# comparison (docs/READER-COMPARISON.md), not a judge.
DISABLED = {"type": "disabled"}
DISABLED_MODELS = ("claude-haiku-5-5",)
ANTHROPIC_VERSION = "vertex-2023-10-16"
# Opus 5.5 rejects `temperature` (HTTP 400, "deprecated for this model"; observed
# October 8, 2026), so sampling is the provider default and replies are not pinned.
SAMPLING = "provider-default"
MAXIMUM_RESPONSE_BYTES = 2 * 1024 * 1024
TOKEN_REFRESH_SECONDS = 15 * 60
REQUEST_TIMEOUT_SECONDS = 120


def model_echo(model=MODEL):
    """Accepted response `model` values: the exact ID, optionally with a version or date suffix."""
    require_model(model)
    return re.compile(re.escape(model) + r"(?:@[0-9A-Za-z._-]+|-[0-9]{8})?\Z")


class VertexError(Exception):
    """Carries only fixed host-authored reason codes."""


def require(condition, code):
    if not condition:
        raise VertexError(code)


def require_model(model):
    require(type(model) is str and model in MODELS, "model_not_supported")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def host(location=LOCATION):
    return "aiplatform.googleapis.com" if location == "global" else location + "-aiplatform.googleapis.com"


def generation_url(location=LOCATION, model=MODEL, project=PROJECT_ID):
    require_model(model)
    return (f"https://{host(location)}/v1/projects/{project}/locations/{location}"
            f"/publishers/anthropic/models/{model}:rawPredict")


def count_url(location=LOCATION, project=PROJECT_ID):
    return (f"https://{host(location)}/v1/projects/{project}/locations/{location}"
            f"/publishers/anthropic/models/count-tokens:rawPredict")


def is_vertex_url(url):
    return url == count_url() or url in {generation_url(model=model) for model in MODELS}


def configuration(model=MODEL):
    """Declaration fields that pin the remote route for a run."""
    require_model(model)
    return {"provider": "vertex-ai", "project_id": PROJECT_ID, "location": LOCATION, "model": model,
            "anthropic_version": ANTHROPIC_VERSION, "sampling": SAMPLING,
            "authentication": "google-application-default-credentials", "api_key": False}


class AccessTokens:
    """Application Default Credentials access tokens from gcloud, refreshed in memory."""

    def __init__(self, command=None, clock=time.monotonic):
        self.command = command or ["gcloud", "auth", "application-default", "print-access-token"]
        self.clock = clock
        self.lock = threading.Lock()
        self.value, self.fetched = None, None

    def __call__(self):
        with self.lock:
            if self.value is None or self.clock() - self.fetched >= TOKEN_REFRESH_SECONDS:
                try:
                    process = subprocess.run(self.command, capture_output=True, timeout=60)
                except Exception:
                    raise VertexError("adc_token_unavailable") from None
                token = process.stdout.decode(errors="replace").strip() if process.returncode == 0 else ""
                require(token and "\n" not in token and "\r" not in token and " " not in token, "adc_token_unavailable")
                self.value, self.fetched = token, self.clock()
            return self.value


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise VertexError("redirect_refused")


def post(url, body, token):
    """POST JSON to a pinned Vertex endpoint. Returns raw bytes; fixed error codes only."""
    require(is_vertex_url(url), "endpoint_refused")
    require(isinstance(token, str) and token, "adc_token_unavailable")
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
    opener = build_opener(ProxyHandler({}), _NoRedirect())
    try:
        with opener.open(Request(url, data=canonical(body), headers=headers), timeout=REQUEST_TIMEOUT_SECONDS) as response:
            raw = response.read(MAXIMUM_RESPONSE_BYTES + 1)
    except HTTPError as error:
        # Error bodies can quote request material; keep the status only.
        raise VertexError("http_status_" + str(error.code)) from None
    except VertexError:
        raise
    except Exception:
        raise VertexError("transport_failed") from None
    require(len(raw) <= MAXIMUM_RESPONSE_BYTES, "response_bound_exceeded")
    require(token.encode() not in raw, "credential_echo_refused")
    return raw


def _split(messages):
    """OpenAI-style role messages to an Anthropic system string and alternating turns."""
    require(isinstance(messages, list) and messages, "messages_invalid")
    system, turns = [], []
    for message in messages:
        require(isinstance(message, dict) and set(message) == {"role", "content"}
                and message["role"] in ("system", "user", "assistant") and isinstance(message["content"], str),
                "messages_invalid")
        if message["role"] == "system":
            require(not turns, "system_after_turns")
            system.append(message["content"])
            continue
        block = {"type": "text", "text": message["content"]}
        if turns and turns[-1]["role"] == message["role"]:
            turns[-1]["content"].append(block)
        else:
            turns.append({"role": message["role"], "content": [block]})
    require(turns and turns[0]["role"] == "user", "first_turn_must_be_user")
    return "\n\n".join(system), turns


def _require_schema(schema):
    """A JSON schema for structured outputs: every object closed with additionalProperties false."""
    def walk(value, depth=0):
        require(depth < 32, "output_schema_invalid")
        if isinstance(value, dict):
            if value.get("type") == "object":
                require(value.get("additionalProperties") is False and isinstance(value.get("properties"), dict)
                        and isinstance(value.get("required"), list), "output_schema_invalid")
            for child in value.values():
                walk(child, depth + 1)
        elif isinstance(value, list):
            for child in value:
                walk(child, depth + 1)
        else:
            require(value is None or isinstance(value, (str, int, float, bool)), "output_schema_invalid")
    require(isinstance(schema, dict) and schema.get("type") == "object", "output_schema_invalid")
    walk(schema)


def output_format(schema):
    """`output_config.format` value that constrains the response text to `schema` (structured outputs)."""
    _require_schema(schema)
    return {"type": "json_schema", "schema": schema}


def generation_controls(model=MODEL, *, thinking=None, effort=None):
    """Validated opt-in `thinking` and `output_config.effort` for `model`; fixed codes on refusal.

    `thinking` is None (field omitted: adaptive thinking), exactly {"type": "between_tools"}
    (Sonnet 5.5 only, at effort high or below) or exactly {"type": "disabled"} (Haiku 5.5 only, at
    effort high or below). `enabled`, `adaptive` with options and `budget_tokens` are refused, and so
    is each off switch on the other models. `effort` is None (provider default) or one of EFFORTS.
    """
    require_model(model)
    require(effort is None or effort in EFFORTS, "effort_invalid")
    if thinking is not None:
        require(isinstance(thinking, dict) and thinking in (BETWEEN_TOOLS, DISABLED), "thinking_invalid")
        if thinking == BETWEEN_TOOLS:
            require(model in BETWEEN_TOOLS_MODELS, "thinking_unsupported_for_model")
        else:
            # Keeps the earlier code for `disabled` on Opus and Sonnet, which reject it.
            require(model in DISABLED_MODELS, "thinking_invalid")
        require(effort is None or effort in BETWEEN_TOOLS_EFFORTS, "effort_invalid_with_between_tools")
    return {"thinking": dict(thinking) if thinking is not None else None, "effort": effort}


def payload(messages, max_tokens, *, model=MODEL, schema=None, thinking=None, effort=None):
    """Generation body. The model is in the URL; no sampling parameter is ever sent.

    Without the keyword options the body is unchanged from earlier versions: no `thinking` and
    no `output_config` field. The options are opt-in: `schema` adds `output_config.format`
    (structured outputs); `thinking` and `effort` are validated for `model` by generation_controls.
    """
    require(type(max_tokens) is int and max_tokens > 0, "output_limit_invalid")
    system, turns = _split(messages)
    body = {"anthropic_version": ANTHROPIC_VERSION, "messages": turns, "max_tokens": max_tokens}
    if system:
        body["system"] = system
    if schema is None and thinking is None and effort is None:
        return body
    controls = generation_controls(model, thinking=thinking, effort=effort)
    output_config = {}
    if controls["effort"] is not None:
        output_config["effort"] = controls["effort"]
    if schema is not None:
        output_config["format"] = output_format(schema)
    if output_config:
        body["output_config"] = output_config
    if controls["thinking"] is not None:
        body["thinking"] = controls["thinking"]
    return body


def count_payload(messages, model=MODEL, *, schema=None):
    """Token-count body for the input a generation payload would send.

    With `schema`, the same `output_config.format` is included, because structured outputs add
    input tokens. Thinking and effort do not change the input and are not sent to the count endpoint.
    """
    require_model(model)
    system, turns = _split(messages)
    body = {"anthropic_version": ANTHROPIC_VERSION, "model": model, "messages": turns}
    if system:
        body["system"] = system
    if schema is not None:
        body["output_config"] = {"format": output_format(schema)}
    return body


def _strict_json(raw):
    def pairs(items):
        keys = [key for key, _ in items]
        require(len(keys) == len(set(keys)), "duplicate_json_key")
        return dict(items)
    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except VertexError:
        raise
    except Exception:
        raise VertexError("json_invalid") from None


def parse_count(raw):
    value = _strict_json(raw)
    require(isinstance(value, dict) and set(value) <= {"input_tokens"} and type(value.get("input_tokens")) is int
            and value["input_tokens"] > 0, "count_invalid")
    return value["input_tokens"]


def parse_usage(value):
    """Normalized usage with the same fields the evaluation scripts already record.

    Anthropic usage does not separate thinking tokens; none are requested, so
    reasoning is reported as zero and visible output is bounded by all output.
    """
    require(isinstance(value, dict), "response_shape_invalid")
    usage = value.get("usage")
    require(isinstance(usage, dict), "usage_missing")
    fresh, completion = usage.get("input_tokens"), usage.get("output_tokens")
    created, read = usage.get("cache_creation_input_tokens") or 0, usage.get("cache_read_input_tokens") or 0
    require(all(type(n) is int and n >= 0 for n in (fresh, completion, created, read)), "usage_invalid")
    prompt = fresh + created + read
    return {"input_tokens": prompt, "output_tokens": completion, "reasoning_tokens": 0,
            "nonreasoning_output_upper_bound": completion, "cached_input_tokens": read,
            "total_tokens": prompt + completion}


def response_metadata(raw):
    """Stop reason and thinking-token count of a response, or None values. Never raises, never text.

    Thinking tokens come from usage.output_tokens_details.thinking_tokens when the provider reports
    them. parse_usage keeps reporting reasoning as zero, so existing callers' records are unchanged.
    """
    empty = {"stop_reason": None, "thinking_tokens": None}
    try:
        value = _strict_json(raw)
    except VertexError:
        return empty
    if not isinstance(value, dict):
        return empty
    stop = value.get("stop_reason")
    usage = value.get("usage") if isinstance(value.get("usage"), dict) else {}
    details = usage.get("output_tokens_details") if isinstance(usage.get("output_tokens_details"), dict) else {}
    thinking = details.get("thinking_tokens")
    return {"stop_reason": stop if stop in STOP_REASONS else ("other" if stop is not None else None),
            "thinking_tokens": thinking if type(thinking) is int and thinking >= 0 else None}


# Known stop reasons; any other value is recorded as "other" so receipts carry no provider text.
STOP_REASONS = ("end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal")


def parse_response(raw, model=MODEL):
    """Accept only a complete assistant message from `model`; returns (text, usage)."""
    echo = model_echo(model)
    require(type(raw) is bytes and len(raw) <= MAXIMUM_RESPONSE_BYTES, "response_bound_exceeded")
    value = _strict_json(raw)
    require(isinstance(value, dict) and value.get("type") == "message" and value.get("role") == "assistant",
            "response_shape_invalid")
    require(isinstance(value.get("model"), str) and echo.match(value["model"]), "model_identity_mismatch")
    usage = parse_usage(value)
    stop = value.get("stop_reason")
    require(stop != "refusal", "refusal_or_output_invalid")
    require(stop in ("end_turn", "stop_sequence"), "response_incomplete")
    require(isinstance(value.get("content"), list), "output_invalid")
    parts = []
    for block in value["content"]:
        require(isinstance(block, dict), "output_invalid")
        if block.get("type") in ("thinking", "redacted_thinking"):
            continue
        require(block.get("type") == "text" and isinstance(block.get("text"), str), "refusal_or_output_invalid")
        parts.append(block["text"])
    text = "".join(parts)
    require(text.strip(), "empty_answer")
    return text, usage


class Pricing:
    """Declared per-run USD rates per million tokens; never assumed by the code.

    One USD per million tokens is one micro-USD per token. Costs round up.
    """

    def __init__(self, input_usd_per_mtok, output_usd_per_mtok):
        self.input = self._rate(input_usd_per_mtok)
        self.output = self._rate(output_usd_per_mtok)

    @staticmethod
    def _rate(value):
        try:
            rate = Decimal(str(value))
        except (InvalidOperation, TypeError, ValueError):
            raise VertexError("pricing_invalid") from None
        require(rate.is_finite() and rate > 0, "pricing_invalid")
        return rate

    def microusd(self, input_tokens, output_tokens):
        amount = Decimal(input_tokens) * self.input + Decimal(output_tokens) * self.output
        return int(amount.to_integral_value(rounding=ROUND_CEILING))

    def declaration(self):
        return {"input_usd_per_million_tokens": str(self.input), "output_usd_per_million_tokens": str(self.output),
                "source": "declared at execution; verify against current Vertex AI pricing",
                "cached_input_discount_applied": False}
