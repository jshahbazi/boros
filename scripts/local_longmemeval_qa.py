#!/usr/bin/env python3
"""Review draft: private local QA grading with unchanged pinned upstream prompts.

Nothing executes on import. CLI requires explicit --execute; QA additionally
requires a successful hash-pinned synthetic controls report. No remote endpoint,
credential, dependency import, answering-store interface, or official-score claim.
"""
from __future__ import annotations

import argparse
import ast
from dataclasses import dataclass
from datetime import datetime
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

PROTOCOL_SHA256 = "ecce9c4c79dc89d99534ac17b383a5cbb5b9f0c69ee98adaf0684742e3d95251"
SOURCE_SHA256 = "d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442"
SOURCE_BYTES = 277383467
SOURCE_REVISION = "98d7416c24c778c2fee6e6f3006e7a073259d48f"
SOURCE_NAME = "longmemeval_s_cleaned.json"
CASE_IDS = ("01493427", "00ca467f", "0e5e2d1a", "06878be2", "001be529", "08f4fc43", "031748ae_abs")
CASE_TYPES = ("knowledge-update", "multi-session", "single-session-assistant", "single-session-preference",
              "single-session-user", "temporal-reasoning", "knowledge-update")
STRATEGIES = ("recent_only", "hybrid")
MODEL = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
ANSWER_CONFIGURATION = {"endpoint": "http://localhost:11234/v1/", "model": MODEL,
    "system": "Be helpful, concise, and accurate.", "temperature": 0.0, "seed": 104202601,
    "thinking": False, "maximum_output": 512, "context_limit": 32768, "safety_tokens": 256}
SHA = re.compile(r"[0-9a-f]{64}\Z")
MAX_SMALL = 32 * 1024 * 1024


class GradeError(Exception):
    """Fixed diagnostics only; never echo a source, response, path, or URL."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise GradeError("duplicate_json_fields")
            result[key] = value
        return result
    def invalid(_):
        raise GradeError("nonfinite_json_value")
    try:
        return json.loads(data.decode(), object_pairs_hook=pairs, parse_constant=invalid)
    except (ValueError, UnicodeError, RecursionError):
        raise GradeError("invalid_json") from None


def read_file(path, limit=MAX_SMALL):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
                raise GradeError("invalid_file")
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise GradeError("file_exceeds_bound")
        return data
    except OSError:
        raise GradeError("file_read_failed") from None


def private_write(path, data):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
    except OSError:
        raise GradeError("private_publication_failed") from None


def new_directory(path):
    path = Path(path)
    if not path.is_absolute():
        raise GradeError("absolute_new_directory_required")
    # Reject symlink ancestors; never create parents or replace a destination.
    for parent in (path.parent, *path.parent.parents):
        if parent.is_symlink():
            raise GradeError("symlink_directory_refused")
        if (parent / ".git").exists() and not path.is_relative_to(parent / ".build"):
            raise GradeError("runtime_destination_in_tracked_tree_refused")
    try:
        path.mkdir(mode=0o700)
    except OSError:
        raise GradeError("new_directory_required") from None
    return path


def load_prompt_function(path, expected_sha=PROTOCOL_SHA256):
    raw = read_file(path)
    if digest(raw) != expected_sha:
        raise GradeError("protocol_pin_mismatch")
    try:
        tree = ast.parse(raw)
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                     and node.name == "get_anscheck_prompt"]
        if len(functions) != 1:
            raise GradeError("protocol_function_missing")
        module = ast.Module(body=functions, type_ignores=[])
        # Only the SHA-pinned pure function executes. Imports and CLI stay absent.
        namespace = {"__builtins__": {"NotImplementedError": NotImplementedError}}
        exec(compile(module, "<pinned-grading-function>", "exec"), namespace)
        function = namespace["get_anscheck_prompt"]
        return function, raw
    except (SyntaxError, TypeError, KeyError):
        raise GradeError("protocol_function_invalid") from None


def local_settings(endpoint):
    try:
        parsed = urlsplit(endpoint)
        host = parsed.hostname
        if (parsed.scheme != "http" or parsed.username is not None or parsed.password is not None
                or parsed.query or parsed.fragment or parsed.path.rstrip("/") not in ("/v1", "/v1/chat/completions")
                or not parsed.port or host is None):
            raise GradeError("loopback_endpoint_required")
        if host == "localhost":
            host = "127.0.0.1"  # Avoid DNS or proxy routing of the local alias.
        if not ipaddress.ip_address(host).is_loopback:
            raise GradeError("loopback_endpoint_required")
        authority = ("[" + host + "]" if ":" in host else host) + ":" + str(parsed.port)
        return {"endpoint": urlunsplit(("http", authority, "/v1/chat/completions", "", "")),
                "model": MODEL, "temperature": 0, "n": 1, "max_tokens": 10, "enable_thinking": False}
    except (ValueError, TypeError):
        raise GradeError("loopback_endpoint_required") from None


def make_request(prompt_function, task, question, reference, hypothesis, abstention, settings):
    prompt = prompt_function(task, question, reference, hypothesis, abstention=abstention)
    return canonical({key: value for key, value in settings.items() if key != "endpoint"} | {
        "messages": [{"role": "user", "content": prompt}]})


# Public, manually specified synthetic truth. These are sanity controls, not a
# real benchmark calibration or an independent human review of generated answers.
# Pair labels remain outside the official prompt and provider request.
def control_specification():
    specifications = [
        ("single-session-user", False, "What material is the user's keepsake?", "The keepsake is cedar.",
         "The keepsake is made of cedar.", "The keepsake is made of glass."),
        ("single-session-assistant", False, "Which instrument did the assistant suggest?", "A viola.",
         "The assistant suggested a viola.", "The assistant suggested a trumpet."),
        ("multi-session", False, "Which two colors were chosen?", "Amber and indigo.",
         "The choices were amber and indigo.", "The only choice was amber."),
        ("single-session-preference", False, "Suggest a suitable lunch given the user's preference.",
         "The user avoids dairy; recommend a dairy-free lunch.",
         "Try a dairy-free vegetable and bean bowl.", "Have a bowl with extra cheese and cream."),
        ("temporal-reasoning", False, "How many weeks elapsed between the two events?", "Seven weeks.",
         "Seven weeks elapsed.", "Thirty weeks elapsed."),
        ("knowledge-update", False, "What is the current reservation size?", "The revised reservation is for six guests.",
         "It was originally four; the revised reservation is for six guests.", "The current reservation is for four guests."),
        ("knowledge-update", True, "What is the serial number of the user's device?", "The serial number was never supplied.",
         "The available information does not include that serial number.", "The device serial number is ZX-482."),
    ]
    rows = []
    for pair, (task, abstention, question, reference, correct, wrong) in enumerate(specifications):
        for expected, hypothesis in ((True, correct), (False, wrong)):
            rows.append({"pair": pair, "category": "abstention" if abstention else task,
                "task": task, "abstention": abstention, "question": question,
                "reference": reference, "hypothesis": hypothesis, "expected": expected})
    return rows


@dataclass(frozen=True)
class SourcePins:
    sha256: str = SOURCE_SHA256
    byte_count: int = SOURCE_BYTES
    record_count: int = 500
    revision: str = SOURCE_REVISION
    name: str = SOURCE_NAME
    case_ids: tuple = CASE_IDS
    case_types: tuple = CASE_TYPES


def source_time(literal, sha, locator):
    try:
        value = datetime.strptime(literal, "%Y/%m/%d (%a) %H:%M")
        if value.strftime("%Y/%m/%d (%a) %H:%M") != literal:
            raise GradeError("source_date_invalid")
        return {"value": value.strftime("%Y-%m-%dT%H:%M"), "precision": "minute", "timezone": "unspecified",
                "source_sha256": sha, "locator": locator, "original_value": literal}
    except (ValueError, TypeError):
        raise GradeError("source_date_invalid") from None


def project_cases(source_raw, pins=SourcePins()):
    if len(source_raw) != pins.byte_count or digest(source_raw) != pins.sha256:
        raise GradeError("source_pin_mismatch")
    rows = strict_json(source_raw)
    if not isinstance(rows, list) or len(rows) != pins.record_count:
        raise GradeError("source_inventory_mismatch")
    by_id = {}
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or not isinstance(row.get("question_id"), str) or row["question_id"] in by_id:
            raise GradeError("source_identity_mismatch")
        by_id[row["question_id"]] = (index, row)
    projected = []
    fields = {"question_id", "question_type", "question", "question_date", "answer", "answer_session_ids",
              "haystack_dates", "haystack_session_ids", "haystack_sessions"}
    for qid, task in zip(pins.case_ids, pins.case_types):
        if qid not in by_id:
            raise GradeError("source_case_missing")
        index, row = by_id[qid]
        if (set(row) != fields or row["question_type"] != task or type(row["answer"]) not in (str, int)
                or not isinstance(row["question"], str) or not row["question"]):
            raise GradeError("source_case_invalid")
        dates, ids, sessions, gold = (row[k] for k in ("haystack_dates", "haystack_session_ids", "haystack_sessions", "answer_session_ids"))
        if (not all(isinstance(v, list) for v in (dates, ids, sessions, gold)) or not sessions
                or len(dates) != len(ids) or len(ids) != len(sessions)
                or not all(isinstance(v, str) and v for v in ids + gold)
                or len(set(gold)) != len(gold) or not set(gold).issubset(ids)):
            raise GradeError("source_sessions_invalid")
        events, labels = [], []
        project = "longmemeval-" + qid
        for si, (literal, sid, turns) in enumerate(zip(dates, ids, sessions)):
            if not isinstance(turns, list) or not turns:
                raise GradeError("source_turns_invalid")
            time = source_time(literal, pins.sha256, f"/{index}/haystack_dates/{si}")
            for ti, turn in enumerate(turns):
                if (not isinstance(turn, dict) or not {"role", "content"}.issubset(turn)
                        or set(turn) - {"role", "content", "has_answer"} or turn["role"] not in ("user", "assistant")
                        or not isinstance(turn["content"], str) or ("has_answer" in turn and type(turn["has_answer"]) is not bool)):
                    raise GradeError("source_turns_invalid")
                eid = f"{qid}-s{si:04d}-m{ti:04d}"
                events.append({"id": eid, "project_id": project, "conversation_key": f"session-{si:04d}",
                    "role": turn["role"], "status": "complete", "text": turn["content"], "source_time": time})
                label = {"event_id": eid, "session_id": sid}
                if "has_answer" in turn:
                    label["has_answer"] = turn["has_answer"]
                labels.append(label)
        question_time = source_time(row["question_date"], pins.sha256, f"/{index}/question_date")
        oracle = {"source_labels": labels, "answer": row["answer"], "question_type": task,
                  "abstention": qid.endswith("_abs"), "answer_session_ids": gold}
        attempts = [{"probe_id": qid, "project_id": project, "conversation_key": f"session-{len(sessions)-1:04d}",
                     "prompt": row["question"], "question_time": question_time, "strategy": strategy, "replicate": 0}
                    for strategy in STRATEGIES]
        projected.append({"id": qid, "row": row, "events": events, "attempts": attempts,
                          "oracle_sha256": digest(canonical(oracle))})
    return projected


def case_annotation(case, version, configuration):
    document = {"version": version, "split": "development", "history_id": case["id"],
                "events": case["events"], "attempts": case["attempts"], "configuration": configuration}
    public = {k: v for k, v in document.items() if k != "configuration"}
    return {"question_id": case["id"], "question_type": case["row"]["question_type"],
        "abstention": case["id"].endswith("_abs"), "source_count": len(case["events"]),
        "source_bytes": sum(len(event["text"].encode()) for event in case["events"]),
        "runner_input_sha256": digest(canonical(document)), "public_projection_sha256": digest(canonical(public)),
        "scorer_annotations_sha256": case["oracle_sha256"]}


@dataclass(frozen=True)
class Bundle:
    attempts: tuple
    pins: dict
    raw_source: bytes
    raw_hypotheses: tuple
    raw_report: bytes


def validate_bundle(report_path, expected_report_sha, export_directory, source_path, pins=SourcePins(), configuration=None):
    configuration = dict(ANSWER_CONFIGURATION if configuration is None else configuration)
    report_raw = read_file(report_path)
    if not isinstance(expected_report_sha, str) or not SHA.fullmatch(expected_report_sha) or digest(report_raw) != expected_report_sha:
        raise GradeError("answer_report_pin_mismatch")
    report = strict_json(report_raw)
    if not isinstance(report, dict):
        raise GradeError("answer_report_contract_invalid")
    version = report.get("runner_document_version")
    if type(version) is not int or version not in (4, 5):
        raise GradeError("answer_document_version_invalid")
    if (type(report.get("longmemeval_evaluation_version")) is not int or report.get("longmemeval_evaluation_version") != 1
            or report.get("split") != "development"
            or report.get("registration_status") != "unregistered_development_subset"):
        raise GradeError("answer_report_contract_invalid")
    declaration = report.get("declaration")
    if not isinstance(declaration, dict) or digest(canonical(declaration) + b"\n") != report.get("declaration_sha256"):
        raise GradeError("answer_declaration_pin_mismatch")
    export_declaration_raw = read_file(Path(export_directory) / "declaration.json")
    if (digest(export_declaration_raw) != report["declaration_sha256"]
            or strict_json(export_declaration_raw) != declaration):
        raise GradeError("export_declaration_pin_mismatch")
    normalized = {k: int(v) if type(v) is float and v.is_integer() else v for k, v in configuration.items()}
    if (declaration.get("declared_attempts") != 14 or declaration.get("case_ids") != list(pins.case_ids)
            or declaration.get("source_revision") != pins.revision or declaration.get("source_sha256") != pins.sha256
            or declaration.get("configuration_sha256") != digest(canonical(configuration))
            or declaration.get("native_configuration_sha256") != digest(canonical(normalized))
            or declaration.get("system_sha256") != digest(configuration["system"].encode())
            or report.get("configuration") != {k: v for k, v in configuration.items() if k != "system"}
            or (version == 5 and declaration.get("runner_document_version") != 5)
            or declaration.get("protocol_hashes", {}).get("src/evaluation/evaluate_qa.py") != PROTOCOL_SHA256):
        raise GradeError("answer_declaration_contract_invalid")
    source = report.get("source", {})
    if not isinstance(source, dict):
        raise GradeError("answer_source_pin_mismatch")
    if any(source.get(k) != v for k, v in {"sha256": pins.sha256, "bytes": pins.byte_count,
                                         "revision": pins.revision, "path": pins.name}.items()):
        raise GradeError("answer_source_pin_mismatch")
    source_raw = read_file(source_path, pins.byte_count)
    cases = project_cases(source_raw, pins)
    annotations = [case_annotation(case, version, configuration) for case in cases]
    if declaration.get("cases") != annotations:
        raise GradeError("case_oracle_projection_pin_mismatch")
    histories = report.get("histories")
    if not isinstance(histories, list) or len(histories) != 7:
        raise GradeError("answer_case_inventory_invalid")
    for case, history in zip(annotations, histories):
        if not isinstance(history, dict) or history.get("case") != case:
            raise GradeError("answer_case_linkage_invalid")
    exports = report.get("private_hypothesis_exports")
    if not isinstance(exports, dict) or set(exports) != set(STRATEGIES):
        raise GradeError("hypothesis_export_inventory_invalid")
    by_strategy, raw_hypotheses = {}, []
    for strategy in STRATEGIES:
        raw = read_file(Path(export_directory) / (strategy + ".jsonl"))
        if exports[strategy] != {"records": 7, "bytes": len(raw), "sha256": digest(raw)}:
            raise GradeError("hypothesis_export_pin_mismatch")
        rows = [strict_json(line) for line in raw.splitlines()]
        if (len(rows) != 7 or any(not isinstance(row, dict) or set(row) != {"question_id", "hypothesis"}
                or not isinstance(row["hypothesis"], str) for row in rows)
                or [row["question_id"] for row in rows] != list(pins.case_ids)):
            raise GradeError("hypothesis_case_inventory_invalid")
        by_strategy[strategy] = rows
        raw_hypotheses.append(raw)
    attempts = []
    for case, history in zip(cases, histories):
        native_attempts = history.get("attempts")
        if not isinstance(native_attempts, list) or len(native_attempts) != 2:
            raise GradeError("answer_attempt_inventory_invalid")
        for ordinal, (strategy, native) in enumerate(zip(STRATEGIES, native_attempts)):
            if (not isinstance(native, dict) or native.get("question_id") != case["id"] or native.get("strategy") != strategy
                    or type(native.get("ordinal")) is not int or native.get("ordinal") != ordinal
                    or type(native.get("replicate")) is not int or native.get("replicate") != 0
                    or type(native.get("operational_complete")) is not bool
                    or native.get("question_type") != case["row"]["question_type"]
                    or native.get("abstention") is not case["id"].endswith("_abs")):
                raise GradeError("answer_attempt_linkage_invalid")
            hypothesis = by_strategy[strategy][pins.case_ids.index(case["id"])]["hypothesis"]
            if native["operational_complete"]:
                if native.get("answer_bytes") != len(hypothesis.encode()) or native.get("answer_sha256") != digest(hypothesis.encode()):
                    raise GradeError("hypothesis_answer_pin_mismatch")
            elif hypothesis:
                raise GradeError("incomplete_answer_export_must_be_empty")
            attempts.append({"category": "abstention" if case["id"].endswith("_abs") else case["row"]["question_type"],
                "task": case["row"]["question_type"], "abstention": case["id"].endswith("_abs"),
                "question": case["row"]["question"], "reference": case["row"]["answer"], "hypothesis": hypothesis,
                "strategy": strategy, "case_sha256": digest(case["id"].encode()),
                "native_operational_complete": native["operational_complete"]})
    return Bundle(tuple(attempts), {"answer_report_sha256": expected_report_sha,
        "answer_declaration_sha256": report["declaration_sha256"], "source_sha256": pins.sha256,
        "hypothesis_export_sha256": [digest(raw) for raw in raw_hypotheses],
        "oracle_projection_sha256": [case["oracle_sha256"] for case in cases]}, source_raw, tuple(raw_hypotheses), report_raw)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise GradeError("redirect_refused")


def call_local(settings, request_bytes, timeout=30):
    # Environment proxy settings and redirects cannot move private judge inputs.
    opener = build_opener(ProxyHandler({}), NoRedirect())
    request = Request(settings["endpoint"], data=request_bytes, method="POST", headers={"Content-Type": "application/json"})
    with opener.open(request, timeout=timeout) as response:
        raw = response.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise GradeError("judge_response_exceeds_bound")
    return raw


def parse_judgment(raw, model=MODEL):
    result = {"terminal_status": "invalid_response", "scored": False, "upstream_yes_substring_label": None,
              "strict_yes_no_format_valid": False, "usage": None, "usage_status": "unknown", "raw_response_sha256": digest(raw)}
    try:
        value = strict_json(raw)
        if not isinstance(value, dict) or value.get("model") != model:
            result["terminal_status"] = "model_identity_mismatch"
            return result
        usage = value.get("usage")
        if (isinstance(usage, dict) and all(type(usage.get(k)) is int and usage[k] >= 0
            for k in ("prompt_tokens", "completion_tokens", "total_tokens"))
                and usage["prompt_tokens"] + usage["completion_tokens"] == usage["total_tokens"]):
            result["usage"] = {k: usage[k] for k in ("prompt_tokens", "completion_tokens", "total_tokens")}
            result["usage_status"] = "observed_provider_receipt"
        choices = value.get("choices")
        if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
            return result
        choice = choices[0]
        message = choice.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant" or not isinstance(message.get("content"), str):
            return result
        content = message["content"].strip().lower()
        result["upstream_yes_substring_label"] = "yes" in content
        result["strict_yes_no_format_valid"] = content in ("yes", "no")
        if choice.get("finish_reason") == "length":
            result["terminal_status"] = "output_truncated"
        elif choice.get("finish_reason") != "stop":
            result["terminal_status"] = "invalid_finish_reason"
        elif usage and result["usage"] is not None and result["usage"]["completion_tokens"] > 10:
            result["terminal_status"] = "output_limit_violation"
        elif not result["strict_yes_no_format_valid"]:
            result["terminal_status"] = "invalid_judgment_format"
        else:
            result.update(terminal_status="completed", scored=True)
        return result
    except GradeError:
        return result


def aggregate(rows):
    categories = sorted({row["category"] for row in rows})
    summary = {}
    for category in ["all", *categories]:
        selected = rows if category == "all" else [row for row in rows if row["category"] == category]
        scored = [row for row in selected if row["scored"]]
        positives = sum(row["upstream_yes_substring_label"] is True for row in scored)
        expected = [row for row in selected if "expected" in row]
        summary[category] = {"declared_attempts": len(selected), "scored_attempts": len(scored),
            "unscored_attempts": len(selected) - len(scored),
            "operational_failed_attempts": sum(row["terminal_status"] == "answer_attempt_incomplete" for row in selected),
            "unknown_judgment_attempts": sum(not row["scored"] and row["terminal_status"] != "answer_attempt_incomplete" for row in selected),
            "accepted_count": positives,
            "accepted_fraction_declared": positives / len(selected) if selected else None,
            "accepted_fraction_scored": positives / len(scored) if scored else None,
            "expected_control_attempts": len(expected),
            "false_accept_count": sum(row["scored"] and row["expected"] is False
                and row["upstream_yes_substring_label"] is True for row in expected) if expected else None,
            "false_reject_count": sum(row["scored"] and row["expected"] is True
                and row["upstream_yes_substring_label"] is False for row in expected) if expected else None,
            "usage_observed_attempts": sum(row["usage"] is not None for row in selected),
            "usage_unknown_attempts": sum(row["usage"] is None for row in selected),
            "observed_prompt_tokens": sum(row["usage"]["prompt_tokens"] for row in selected if row["usage"]),
            "observed_completion_tokens": sum(row["usage"]["completion_tokens"] for row in selected if row["usage"])}
    return summary


def fingerprints(settings, protocol_raw):
    return {"grader_sha256": digest(read_file(Path(__file__).resolve())), "protocol_sha256": digest(protocol_raw),
            "model_settings_sha256": digest(canonical(settings)), "control_spec_sha256": digest(canonical(control_specification()))}


def validate_controls(path, expected_sha, fingerprints_expected):
    raw = read_file(path)
    if digest(raw) != expected_sha:
        raise GradeError("control_report_pin_mismatch")
    report = strict_json(raw)
    if (not isinstance(report, dict) or report.get("local_qa_diagnostic_version") != 1 or report.get("mode") != "controls"
            or report.get("synthetic_controls_validated") is not True
            or report.get("fingerprints") != fingerprints_expected):
        raise GradeError("matching_validated_controls_required")
    rows = report.get("attempts")
    specification = control_specification()
    if not isinstance(rows, list) or len(rows) != len(specification):
        raise GradeError("control_inventory_invalid")
    for index, (row, spec) in enumerate(zip(rows, specification)):
        if (not isinstance(row, dict) or row.get("ordinal") != index or row.get("category") != spec["category"]
                or row.get("expected") is not spec["expected"] or row.get("scored") is not True
                or row.get("strict_yes_no_format_valid") is not True or row.get("terminal_status") != "completed"
                or row.get("upstream_yes_substring_label") is not spec["expected"]):
            raise GradeError("control_results_invalid")
    return digest(raw)


def run(mode, settings, prompt_function, protocol_raw, output_directory, attempts, input_pins,
        private_directory=None, controls_report=None, controls_sha=None, transport=call_local, timeout=30):
    if mode not in ("controls", "qa") or type(timeout) not in (int, float) or not 0 < timeout <= 60:
        raise GradeError("invalid_run_settings")
    # Defensive validation applies to callers as well as CLI.
    if settings != local_settings(settings["endpoint"]):
        raise GradeError("judge_settings_invalid")
    settings = dict(settings)
    attempts = tuple(dict(attempt) for attempt in attempts)
    input_pins = strict_json(canonical(input_pins))
    fp = fingerprints(settings, protocol_raw)
    control_pin = None
    if mode == "qa":
        if controls_report is None or controls_sha is None:
            raise GradeError("matching_validated_controls_required")
        control_pin = validate_controls(controls_report, controls_sha, fp)
        if len(attempts) != 14:
            raise GradeError("declared_qa_inventory_invalid")
    elif canonical(attempts) != canonical(control_specification()):
        raise GradeError("declared_control_inventory_invalid")
    # Materialize immutable request bytes for every declared attempt before calls.
    requests = tuple(make_request(prompt_function, row["task"], row["question"], row["reference"],
        row["hypothesis"], row["abstention"], settings) for row in attempts)
    declaration = {"local_qa_declaration_version": 1, "mode": mode, "declared_attempts": len(attempts),
        "fingerprints": fp, "input_pins": input_pins, "controls_report_sha256": control_pin,
        "request_sha256": [digest(raw) for raw in requests],
        "adaptations": ["local_loopback_qwen_routing", "thinking_disabled"],
        "real_judge_calibration_status": "unrun", "official_qa_score": None}
    output = new_directory(output_directory)
    private = new_directory(private_directory) if private_directory is not None else None
    private_write(output / "declaration.json", canonical(declaration) + b"\n")
    if private is not None:
        private_write(private / "requests.jsonl", b"".join(raw + b"\n" for raw in requests))
    results = []
    for index, (attempt, request_bytes) in enumerate(zip(attempts, requests)):
        result = {"terminal_status": "answer_attempt_incomplete", "scored": False,
                  "upstream_yes_substring_label": None, "strict_yes_no_format_valid": False,
                  "usage": None, "usage_status": "unknown", "raw_response_sha256": None}
        if attempt.get("native_operational_complete", True):
            try:
                if fingerprints(settings, protocol_raw) != fp:
                    raise GradeError("frozen_implementation_changed")
                raw = transport(dict(settings), request_bytes, timeout=timeout)
                if not isinstance(raw, bytes):
                    raise GradeError("invalid_transport_response")
                if private is not None:
                    private_write(private / f"judgment-{index:04d}.json", raw)
                result = parse_judgment(raw)
            except Exception:
                # Exception strings may contain request URLs or private content.
                result["terminal_status"] = "transport_or_capture_failed"
        result.update(ordinal=index, category=attempt["category"], request_sha256=digest(request_bytes))
        for key in ("strategy", "case_sha256", "expected"):
            if key in attempt:
                result[key] = attempt[key]
        results.append(result)
    controls_passed = mode == "controls" and all(row["scored"] and row["upstream_yes_substring_label"] is row["expected"] for row in results)
    report = {"local_qa_diagnostic_version": 1, "mode": mode, "fingerprints": fp,
        "declaration_sha256": digest(canonical(declaration) + b"\n"), "attempts": results, "summary": aggregate(results),
        "synthetic_controls_validated": controls_passed if mode == "controls" else True,
        "real_judge_calibration_status": "unrun", "performance_trust": "unvalidated_real_judge",
        "official_qa_score": None, "private_capture_enabled": private is not None,
        "private_capture_sha256": digest(canonical([row["raw_response_sha256"] for row in results])) if private else None}
    if mode == "qa":
        report["by_strategy"] = {strategy: aggregate([row for row in results if row.get("strategy") == strategy]) for strategy in STRATEGIES}
    private_write(output / "report.json", canonical(report) + b"\n")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description="Explicit local-only QA diagnostic; real judge calibration remains unrun.")
    parser.add_argument("mode", choices=("controls", "qa"))
    parser.add_argument("--protocol", required=True)
    parser.add_argument("--endpoint", default=ANSWER_CONFIGURATION["endpoint"])
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--private-directory")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--answer-report")
    parser.add_argument("--answer-report-sha256")
    parser.add_argument("--hypotheses-directory")
    parser.add_argument("--source")
    parser.add_argument("--controls-report")
    parser.add_argument("--controls-report-sha256")
    args = parser.parse_args(argv)
    try:
        if not args.execute:
            raise GradeError("explicit_execution_required")
        settings = local_settings(args.endpoint)
        prompt_function, protocol_raw = load_prompt_function(args.protocol)
        if args.mode == "controls":
            attempts, pins = control_specification(), {"control_spec_sha256": digest(canonical(control_specification()))}
        else:
            if not all((args.answer_report, args.answer_report_sha256, args.hypotheses_directory, args.source)):
                raise GradeError("qa_input_pins_required")
            bundle = validate_bundle(args.answer_report, args.answer_report_sha256, args.hypotheses_directory, args.source)
            attempts, pins = bundle.attempts, bundle.pins
        report = run(args.mode, settings, prompt_function, protocol_raw, args.output_directory, attempts, pins,
            private_directory=args.private_directory, controls_report=args.controls_report,
            controls_sha=args.controls_report_sha256, timeout=args.timeout)
        # Fixed shape, counts only; no arguments, private content, or raw errors.
        print(json.dumps({"declared_attempts": report["summary"]["all"]["declared_attempts"],
            "scored_attempts": report["summary"]["all"]["scored_attempts"],
            "synthetic_controls_validated": report["synthetic_controls_validated"], "official_qa_score": None}))
        return 0
    except (GradeError, OSError, ValueError, TypeError, KeyError):
        print("Local QA diagnostic failed validation.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
