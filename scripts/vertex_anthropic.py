#!/usr/bin/env python3
"""Vertex AI adapter for Claude Opus in the GCP llm-train project, for evaluation tooling only.

Authentication uses Google Application Default Credentials through the gcloud
CLI. No API key is stored, read or passed, and the short-lived access token
lives only in memory. The project ID is explicit on every request because the
workstation's default gcloud project is a different one. Errors carry fixed
codes; response and error bodies are never printed. The Boros application
does not import this module and still processes text only through local
model servers.
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
MODEL = "claude-opus-5-5"
ANTHROPIC_VERSION = "vertex-2023-10-16"
TEMPERATURE = 0
MAXIMUM_RESPONSE_BYTES = 2 * 1024 * 1024
TOKEN_REFRESH_SECONDS = 15 * 60
REQUEST_TIMEOUT_SECONDS = 120
_MODEL_ECHO = re.compile(re.escape(MODEL) + r"(?:@[0-9A-Za-z._-]+|-[0-9]{8})?\Z")


class VertexError(Exception):
    """Carries only fixed host-authored reason codes."""


def require(condition, code):
    if not condition:
        raise VertexError(code)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def host(location=LOCATION):
    return "aiplatform.googleapis.com" if location == "global" else location + "-aiplatform.googleapis.com"


def generation_url(location=LOCATION, model=MODEL, project=PROJECT_ID):
    return (f"https://{host(location)}/v1/projects/{project}/locations/{location}"
            f"/publishers/anthropic/models/{model}:rawPredict")


def count_url(location=LOCATION, project=PROJECT_ID):
    return (f"https://{host(location)}/v1/projects/{project}/locations/{location}"
            f"/publishers/anthropic/models/count-tokens:rawPredict")


def is_vertex_url(url):
    return url in (generation_url(), count_url())


def configuration():
    """Declaration fields that pin the remote route for a run."""
    return {"provider": "vertex-ai", "project_id": PROJECT_ID, "location": LOCATION, "model": MODEL,
            "anthropic_version": ANTHROPIC_VERSION, "temperature": TEMPERATURE,
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


def payload(messages, max_tokens):
    """Generation body. The model is in the URL; no extended thinking is requested."""
    require(type(max_tokens) is int and max_tokens > 0, "output_limit_invalid")
    system, turns = _split(messages)
    body = {"anthropic_version": ANTHROPIC_VERSION, "messages": turns, "max_tokens": max_tokens,
            "temperature": TEMPERATURE}
    if system:
        body["system"] = system
    return body


def count_payload(messages):
    """Token-count body for exactly the input a generation payload would send."""
    system, turns = _split(messages)
    body = {"anthropic_version": ANTHROPIC_VERSION, "model": MODEL, "messages": turns}
    if system:
        body["system"] = system
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


def parse_response(raw):
    """Accept only a complete assistant message; returns (text, usage)."""
    require(type(raw) is bytes and len(raw) <= MAXIMUM_RESPONSE_BYTES, "response_bound_exceeded")
    value = _strict_json(raw)
    require(isinstance(value, dict) and value.get("type") == "message" and value.get("role") == "assistant",
            "response_shape_invalid")
    require(isinstance(value.get("model"), str) and _MODEL_ECHO.match(value["model"]), "model_identity_mismatch")
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
