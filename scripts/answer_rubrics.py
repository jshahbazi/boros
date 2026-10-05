#!/usr/bin/env python3
"""Frozen, exact-response diagnostic rubrics; never emit source or answer text."""
from __future__ import annotations

import json

RUBRIC_VERSION = "boros-public-exact-answer-v1"
KINDS = frozenset({"exact_quote", "cross_message_quotes", "correction", "absence"})
MAX_RESPONSE_BYTES = 1024 * 1024
ORACLE_KEYS = frozenset({"rubric_version", "kind", "expected_answers", "required_source_ids",
                         "forbidden_answers", "answerable"})
RESPONSE_KEYS = frozenset({"answer", "citations", "abstain"})
RESPONSE_DIAGNOSTIC_VERSION = "boros-response-diagnostic-v1"
RESPONSE_ERROR_CODES = frozenset({"response_size", "response_utf8", "response_type",
    "response_json_syntax", "response_duplicate_key", "response_nonfinite", "response_top_level",
    "response_keys", "response_abstain_shape", "response_citations_shape",
    "response_answer_shape_string", "response_answer_shape_array"})


class RubricError(ValueError):
    """A fixed host-authored validation error, containing no supplied material."""


def _valid_text(value, *, nonempty=False):
    if type(value) is not str or (nonempty and not value):
        return False
    try:
        return len(value.encode("utf-8")) <= MAX_RESPONSE_BYTES
    except UnicodeError:
        return False


def _text_array(value, *, nonempty=False):
    return (type(value) is list and all(_valid_text(item, nonempty=nonempty) for item in value)
            and len(value) <= 4096)


def validate_oracle(oracle):
    """Validate scorer-only gold. No oracle field belongs in provider input."""
    valid = (type(oracle) is dict and set(oracle) == ORACLE_KEYS
             and oracle.get("rubric_version") == RUBRIC_VERSION
             and type(oracle.get("kind")) is str and oracle["kind"] in KINDS
             and type(oracle.get("answerable")) is bool
             and _text_array(oracle.get("expected_answers"), nonempty=True)
             and _text_array(oracle.get("required_source_ids"), nonempty=True)
             and _text_array(oracle.get("forbidden_answers"), nonempty=True))
    if not valid:
        raise RubricError("invalid_oracle")
    expected = oracle["expected_answers"]
    required = oracle["required_source_ids"]
    forbidden = oracle["forbidden_answers"]
    if len(set(required)) != len(required) or len(set(forbidden)) != len(forbidden):
        raise RubricError("invalid_oracle")
    if oracle["kind"] == "absence":
        valid = not oracle["answerable"] and not expected and not required and not forbidden
    elif oracle["kind"] == "cross_message_quotes":
        valid = oracle["answerable"] and len(expected) >= 2 and len(required) >= 2 and not forbidden
    elif oracle["kind"] == "correction":
        valid = (oracle["answerable"] and len(expected) == 1 and bool(required) and bool(forbidden)
                 and not any(old in expected[0] for old in forbidden))
    else:
        valid = oracle["answerable"] and len(expected) == 1 and bool(required) and not forbidden
    if not valid:
        raise RubricError("invalid_oracle")
    return oracle


def _parse_response(response):
    if type(response) is bytes:
        if len(response) > MAX_RESPONSE_BYTES:
            raise RubricError("response_size")
        try:
            response = response.decode("utf-8")
        except UnicodeError:
            raise RubricError("response_utf8") from None
    if type(response) is not str:
        raise RubricError("response_type")
    try:
        response_bytes = response.encode("utf-8")
    except UnicodeError:
        raise RubricError("response_utf8") from None
    if len(response_bytes) > MAX_RESPONSE_BYTES:
        raise RubricError("response_size")

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise RubricError("response_duplicate_key")
            result[key] = value
        return result

    def nonfinite(_):
        raise RubricError("response_nonfinite")

    try:
        parsed = json.loads(response, object_pairs_hook=pairs, parse_constant=nonfinite)
    except RubricError:
        raise
    except json.JSONDecodeError:
        raise RubricError("response_json_syntax") from None
    except (ValueError, TypeError, RecursionError):
        raise RubricError("response_type") from None
    if type(parsed) is not dict:
        raise RubricError("response_top_level")
    if set(parsed) != RESPONSE_KEYS:
        raise RubricError("response_keys")
    if type(parsed["abstain"]) is not bool:
        raise RubricError("response_abstain_shape")
    if not _text_array(parsed["citations"], nonempty=True):
        raise RubricError("response_citations_shape")
    return parsed


def score_response(response, oracle, *, operational_complete: bool, delivered_source_ids: set[str]):
    """Return only fixed codes, booleans and counts, including failed-attempt zeros.

    The caller validates delivered source/range digests against the frozen corpus.
    IDs in delivered_source_ids attest source delivery, not semantic sufficiency.
    """
    oracle = validate_oracle(oracle)
    if (type(operational_complete) is not bool
            or type(delivered_source_ids) not in (set, frozenset)
            or not all(_valid_text(value, nonempty=True) for value in delivered_source_ids)):
        raise RubricError("invalid_host_evidence")
    result = {"rubric_version": RUBRIC_VERSION, "kind": oracle["kind"], "score": 0,
              "operational_complete": operational_complete, "response_valid": False,
              "answer_correct": False, "citation_correct": False, "abstention_correct": False,
              "required_source_count": len(oracle["required_source_ids"]),
              "delivered_required_source_count": len(set(oracle["required_source_ids"]) & delivered_source_ids),
              "citation_count": 0, "failure_code": None,
              "response_diagnostic_version": RESPONSE_DIAGNOSTIC_VERSION,
              "response_error_code": None}
    if not operational_complete:
        result["failure_code"] = "invocation_incomplete"
        return result
    try:
        parsed = _parse_response(response)
        if oracle["kind"] == "cross_message_quotes":
            if not _text_array(parsed["answer"]):
                raise RubricError("response_answer_shape_array")
        elif not _valid_text(parsed["answer"]):
            raise RubricError("response_answer_shape_string")
    except RubricError as error:
        result["failure_code"] = "response_invalid"
        result["response_error_code"] = error.args[0] if error.args and error.args[0] in RESPONSE_ERROR_CODES else "response_type"
        return result
    result["response_valid"] = True
    result["citation_count"] = len(parsed["citations"])
    result["abstention_correct"] = parsed["abstain"] == (not oracle["answerable"])
    if oracle["kind"] == "absence":
        result["answer_correct"] = parsed["answer"] == ""
    elif oracle["kind"] == "cross_message_quotes":
        result["answer_correct"] = parsed["answer"] == oracle["expected_answers"]
    else:
        result["answer_correct"] = (parsed["answer"] == oracle["expected_answers"][0]
                                    and not any(old in parsed["answer"] for old in oracle["forbidden_answers"]))
    required = set(oracle["required_source_ids"])
    citations = parsed["citations"]
    result["citation_correct"] = (len(citations) == len(set(citations)) and set(citations) == required
                                  and required <= delivered_source_ids)
    result["score"] = int(result["answer_correct"] and result["citation_correct"]
                          and result["abstention_correct"])
    if not result["abstention_correct"]:
        result["failure_code"] = "abstention_mismatch"
    elif not result["answer_correct"]:
        result["failure_code"] = "answer_mismatch"
    elif not result["citation_correct"]:
        result["failure_code"] = "citation_mismatch"
    return result
