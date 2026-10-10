#!/usr/bin/env python3
"""Vertex AI adapter for Gemini models in the GCP llm-train project, for evaluation tooling only.

The Gemini counterpart of ``vertex_anthropic.py``, with the same discipline: Google Application
Default Credentials through the gcloud CLI (``vertex_anthropic.AccessTokens``), no API key, the
project ID explicit on every request, pinned endpoints, fixed error codes, and response or error
bodies never printed. The Boros application does not import this module and still processes text
only through local model servers.

Gemini 3.8 Flash cannot turn thinking off: ``thinkingLevel`` "minimal" returns HTTP 400 and
``thinkingBudget`` 0 still produced thought tokens (both observed October 10, 2026). The lowest
level, "low", is the only one this adapter sends. Thought tokens are billed as output and count
against ``maxOutputTokens``. No sampling parameter is sent, so sampling is the provider default.
"""
from __future__ import annotations

import json
import re
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler

import vertex_anthropic as va

PROJECT_ID = va.PROJECT_ID
LOCATION = "global"
MODELS = ("gemini-3.8-flash",)
THINKING_LEVELS = ("low",)
SAMPLING = "provider-default"
MAXIMUM_RESPONSE_BYTES = va.MAXIMUM_RESPONSE_BYTES
REQUEST_TIMEOUT_SECONDS = 180
# Finish reasons a receipt may carry; anything else is recorded as "other".
FINISH_REASONS = ("STOP", "MAX_TOKENS", "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
                  "MALFORMED_FUNCTION_CALL", "OTHER", "FINISH_REASON_UNSPECIFIED")

VertexError = va.VertexError
require = va.require
canonical = va.canonical
digest = va.digest


def require_model(model):
    require(type(model) is str and model in MODELS, "model_not_supported")


def _base(model, project=PROJECT_ID):
    require_model(model)
    return (f"https://{va.host(LOCATION)}/v1/projects/{project}/locations/{LOCATION}"
            f"/publishers/google/models/{model}")


def generation_url(model, project=PROJECT_ID):
    return _base(model, project) + ":generateContent"


def count_url(model, project=PROJECT_ID):
    return _base(model, project) + ":countTokens"


def is_vertex_url(url):
    return url in {generation_url(model) for model in MODELS} | {count_url(model) for model in MODELS}


def configuration(model, thinking_level):
    require_model(model)
    require(thinking_level in THINKING_LEVELS, "thinking_invalid")
    return {"provider": "vertex-ai", "publisher": "google", "project_id": PROJECT_ID, "location": LOCATION,
            "model": model, "sampling": SAMPLING, "thinking_level": thinking_level,
            "authentication": "google-application-default-credentials", "api_key": False}


def post(url, body, token):
    """POST JSON to a pinned Gemini endpoint. Returns raw bytes; fixed error codes only."""
    require(is_vertex_url(url), "endpoint_refused")
    require(isinstance(token, str) and token, "adc_token_unavailable")
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
    opener = build_opener(ProxyHandler({}), va._NoRedirect())
    try:
        with opener.open(Request(url, data=canonical(body), headers=headers), timeout=REQUEST_TIMEOUT_SECONDS) as response:
            raw = response.read(MAXIMUM_RESPONSE_BYTES + 1)
    except HTTPError as error:
        raise VertexError("http_status_" + str(error.code)) from None
    except VertexError:
        raise
    except Exception:
        raise VertexError("transport_failed") from None
    require(len(raw) <= MAXIMUM_RESPONSE_BYTES, "response_bound_exceeded")
    require(token.encode() not in raw, "credential_echo_refused")
    return raw


def _split(messages):
    """OpenAI-style role messages to a Gemini system instruction and alternating user/model contents."""
    system, turns = va._split(messages)
    contents = [{"role": "model" if turn["role"] == "assistant" else "user",
                 "parts": [{"text": block["text"]} for block in turn["content"]]} for turn in turns]
    return system, contents


def payload(messages, max_output_tokens, *, thinking_level):
    """Generation body: system instruction, contents, output limit and thinking level; no sampling field."""
    require(type(max_output_tokens) is int and max_output_tokens > 0, "output_limit_invalid")
    require(thinking_level in THINKING_LEVELS, "thinking_invalid")
    system, contents = _split(messages)
    body = {"contents": contents,
            "generationConfig": {"maxOutputTokens": max_output_tokens,
                                 "thinkingConfig": {"thinkingLevel": thinking_level}}}
    if system:
        body["systemInstruction"] = {"parts": [{"text": system}]}
    return body


def count_payload(messages):
    system, contents = _split(messages)
    body = {"contents": contents}
    if system:
        body["systemInstruction"] = {"parts": [{"text": system}]}
    return body


def parse_count(raw):
    value = va._strict_json(raw)
    require(isinstance(value, dict) and type(value.get("totalTokens")) is int and value["totalTokens"] > 0,
            "count_invalid")
    return value["totalTokens"]


def model_echo(model):
    require_model(model)
    return re.compile(re.escape(model) + r"(?:@[0-9A-Za-z._-]+|-[0-9]{3,8})?\Z")


def parse_usage(value):
    """Normalized usage in the shape vertex_anthropic.parse_usage returns, with thought tokens as reasoning."""
    require(isinstance(value, dict), "response_shape_invalid")
    usage = value.get("usageMetadata")
    require(isinstance(usage, dict), "usage_missing")
    prompt = usage.get("promptTokenCount")
    visible = usage.get("candidatesTokenCount") or 0
    thoughts = usage.get("thoughtsTokenCount") or 0
    cached = usage.get("cachedContentTokenCount") or 0
    require(all(type(n) is int and n >= 0 for n in (prompt, visible, thoughts, cached)), "usage_invalid")
    return {"input_tokens": prompt, "output_tokens": visible + thoughts, "reasoning_tokens": thoughts,
            "nonreasoning_output_upper_bound": visible, "cached_input_tokens": cached,
            "total_tokens": prompt + visible + thoughts}


def response_metadata(raw):
    """Finish reason and thought-token count, or None values. Never raises, never text."""
    empty = {"stop_reason": None, "thinking_tokens": None}
    try:
        value = va._strict_json(raw)
    except VertexError:
        return empty
    candidates = value.get("candidates") if isinstance(value, dict) else None
    reason = candidates[0].get("finishReason") if isinstance(candidates, list) and candidates \
        and isinstance(candidates[0], dict) else None
    usage = value.get("usageMetadata") if isinstance(value, dict) and isinstance(value.get("usageMetadata"), dict) else {}
    thoughts = usage.get("thoughtsTokenCount")
    return {"stop_reason": reason if reason in FINISH_REASONS else ("other" if reason is not None else None),
            "thinking_tokens": thoughts if type(thoughts) is int and thoughts >= 0 else None}


def parse_response(raw, model):
    """Accept only one complete candidate from `model`; returns (text, usage). Thought parts are skipped."""
    echo = model_echo(model)
    require(type(raw) is bytes and len(raw) <= MAXIMUM_RESPONSE_BYTES, "response_bound_exceeded")
    value = va._strict_json(raw)
    require(isinstance(value, dict) and isinstance(value.get("candidates"), list) and len(value["candidates"]) == 1,
            "response_shape_invalid")
    require(isinstance(value.get("modelVersion"), str) and echo.match(value["modelVersion"]), "model_identity_mismatch")
    usage = parse_usage(value)
    candidate = value["candidates"][0]
    require(isinstance(candidate, dict), "response_shape_invalid")
    reason = candidate.get("finishReason")
    require(reason not in ("SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"), "refusal_or_output_invalid")
    require(reason == "STOP", "response_incomplete")
    content = candidate.get("content")
    require(isinstance(content, dict) and content.get("role") == "model" and isinstance(content.get("parts"), list),
            "output_invalid")
    parts = []
    for part in content["parts"]:
        require(isinstance(part, dict), "output_invalid")
        if part.get("thought") is True:
            continue
        require(isinstance(part.get("text"), str), "refusal_or_output_invalid")
        parts.append(part["text"])
    text = "".join(parts)
    require(text.strip(), "empty_answer")
    return text, usage


Pricing = va.Pricing
