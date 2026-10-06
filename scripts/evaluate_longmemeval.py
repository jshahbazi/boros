#!/usr/bin/env python3
"""Pinned LongMemEval development runner with private official-format exports."""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit, urlunsplit

import evaluate_answers as e
import longmemeval_cases as cases
from evaluation_fixtures import canonical_json

CONFIGURATION = {**e.DEFAULTS, "maximum_output": 512}
RUNNER_DOCUMENT_VERSION = 5
PROTOCOL_COMMIT = "9e0b455f4ef0e2ab8f2e582289761153549043fc"
PROTOCOL_HASHES = {
    "src/evaluation/evaluate_qa.py": "ecce9c4c79dc89d99534ac17b383a5cbb5b9f0c69ee98adaf0684742e3d95251",
    "src/evaluation/print_qa_metrics.py": "e9283933a0cefb7a0ded7365e436ae3d1be5aac41853325e6155d83bf07607f0",
    "src/evaluation/print_retrieval_metrics.py": "58b70c0b562ea57372a7774a554c347cd908e901b77ac0149fc90b097b6f1b8f",
    "src/retrieval/run_retrieval.py": "efd7fc5969a904717741fadca3c7dc73611ddbb2aaf3ef33117ebb6943b3e346",
    "src/retrieval/eval_utils.py": "c98b8d1096877a15aa755c9de44fe33c195298466a2eb6f3c0f9f6bde8c72349",
}
TYPES = {"single-session-user", "single-session-assistant", "single-session-preference",
         "multi-session", "temporal-reasoning", "knowledge-update"}


def native_configuration_sha256(configuration):
    # Foundation emits the pinned numeric zero as 0 rather than Python's 0.0.
    return e.digest(canonical_json({**configuration, "temperature": 0}))


def chat_endpoint(address):
    # Mirrors the accepted paths in EndpointRunner.LocalEndpoint.chatURL.
    parts = urlsplit(address.strip())
    if parts.path.strip("/") not in ("", "v1", "v1/chat/completions"):
        raise e.EvaluationError("invalid pinned chat endpoint")
    return urlunsplit((parts.scheme, parts.netloc, "/v1/chat/completions", "", ""))


def validate_history(history):
    events, labels, episodes = history.get("events"), history.get("source_labels"), history.get("episodes")
    if (not isinstance(events, list) or not events or not isinstance(labels, list)
            or len(events) != len(labels) or not isinstance(episodes, list) or len(episodes) != 1):
        raise e.EvaluationError("invalid benchmark source inventory")
    probe = episodes[0]
    if (not isinstance(probe, dict) or probe.get("question_type") not in TYPES
            or type(probe.get("abstention")) is not bool
            or probe["abstention"] != ("_abs" in probe.get("question_id", ""))
            or type(probe.get("answer")) not in (str, int)
            or not isinstance(probe.get("answer_session_ids"), list)
            or any(not isinstance(s, str) or not s for s in probe["answer_session_ids"])
            or len(set(probe["answer_session_ids"])) != len(probe["answer_session_ids"])):
        raise e.EvaluationError("invalid benchmark scorer annotations")
    ids, sessions, conversations = set(), set(), {}
    for event, label in zip(events, labels):
        if (not isinstance(event, dict) or not isinstance(event.get("id"), str)
                or event["id"] in ids or not isinstance(event.get("text"), str)
                or event.get("project_id") != probe.get("project_id")
                or event.get("role") not in ("user", "assistant") or event.get("status") != "complete"
                or not isinstance(label, dict) or set(label) - {"event_id", "session_id", "has_answer"}
                or label.get("event_id") != event["id"]
                or not isinstance(label.get("session_id"), str) or not label["session_id"]
                or ("has_answer" in label and type(label["has_answer"]) is not bool)):
            raise e.EvaluationError("invalid benchmark source labels")
        ids.add(event["id"]); sessions.add(label["session_id"])
        conversation = event.get("conversation_key")
        if not isinstance(conversation, str) or not conversation:
            raise e.EvaluationError("invalid benchmark conversation scope")
        if conversation in conversations and conversations[conversation] != label["session_id"]:
            raise e.EvaluationError("benchmark session scope mismatch")
        conversations[conversation] = label["session_id"]
    if (not set(probe["answer_session_ids"]).issubset(sessions)
            or probe.get("conversation_key") not in conversations):
        raise e.EvaluationError("benchmark scorer scope mismatch")
    return probe


def oracle_sha256(history):
    probe = validate_history(history)
    return e.digest(canonical_json({"source_labels": history["source_labels"],
        **{k: probe[k] for k in ("answer", "question_type", "abstention", "answer_session_ids")}}))


def validated_intervals(history, request, ranges, recent_ids):
    """Validate original UTF-8 boundaries, scope and every delivered digest."""
    if (not isinstance(ranges, list) or not isinstance(recent_ids, list)
            or any(not isinstance(s, str) for s in recent_ids) or len(set(recent_ids)) != len(recent_ids)):
        raise e.EvaluationError("invalid delivered source inventory")
    sources = {row["id"]: row for row in history["events"]}
    intervals = {}
    full_ranges = set()
    for row in ranges:
        if (not isinstance(row, dict) or set(row) != {"event_id", "offset", "byte_length", "sha256"}
                or not isinstance(row["event_id"], str) or row["event_id"] not in sources
                or type(row["offset"]) is not int or type(row["byte_length"]) is not int
                or not isinstance(row["sha256"], str) or not e.SHA.fullmatch(row["sha256"])):
            raise e.EvaluationError("invalid delivered range")
        source = sources[row["event_id"]]
        if source["project_id"] != request["project_id"]:
            raise e.EvaluationError("delivered source scope mismatch")
        data = source["text"].encode(); start = row["offset"]; end = start + row["byte_length"]
        if (start < 0 or row["byte_length"] < 0 or end > len(data)
                or (row["byte_length"] == 0 and data) or e.digest(data[start:end]) != row["sha256"]):
            raise e.EvaluationError("delivered range digest mismatch")
        try:
            data[:start].decode("utf-8"); data[start:end].decode("utf-8")
        except UnicodeError:
            raise e.EvaluationError("delivered range UTF-8 boundary mismatch") from None
        intervals.setdefault(row["event_id"], []).append((start, end))
        if start == 0 and end == len(data):
            full_ranges.add(row["event_id"])
    for source_id in recent_ids:
        if (source_id not in sources or source_id not in full_ranges
                or sources[source_id]["project_id"] != request["project_id"]
                or sources[source_id]["conversation_key"] != request["conversation_key"]):
            raise e.EvaluationError("delivered recent source proof mismatch")
    return intervals


def delivery_diagnostic(history, request, ranges, recent_ids):
    probe = validate_history(history)
    intervals = validated_intervals(history, request, ranges, recent_ids)
    sources = {row["id"]: row for row in history["events"]}
    delivered = {source_id for source_id, rows in intervals.items() if any(end > start for start, end in rows)}
    delivered_sessions = {label["session_id"] for label in history["source_labels"] if label["event_id"] in delivered}
    gold_sessions = set(probe["answer_session_ids"])
    positive = [label["event_id"] for label in history["source_labels"] if label.get("has_answer") is True]
    empty_positive = sum(not sources[source_id]["text"] for source_id in positive)
    covered = 0
    for source_id in positive:
        cursor = 0; length = len(sources[source_id]["text"].encode())
        for start, stop in sorted(intervals.get(source_id, [])):
            if start > cursor:
                break
            cursor = max(cursor, stop)
        covered += int(length > 0 and cursor >= length)
    eligible = not probe["abstention"]
    session_available = eligible and bool(gold_sessions)
    turn_available = eligible and bool(positive) and not empty_positive
    hits = len(gold_sessions & delivered_sessions)
    return {"diagnostic": "original-source-delivery-v1", "official_retrieval_score": None,
        "eligible_non_abstention": eligible, "validated_delivered_source_count": len(delivered),
        "gold_session_count": len(gold_sessions), "hit_gold_session_count": hits,
        "session_hit_fraction": hits / len(gold_sessions) if session_available else None,
        "all_gold_sessions_hit": hits == len(gold_sessions) if session_available else None,
        "gold_evidence_turn_count": len(positive), "empty_gold_evidence_turn_count": empty_positive,
        "fully_delivered_evidence_turn_count": covered,
        "full_evidence_turn_delivery_fraction": covered / len(positive) if turn_available else None,
        "all_evidence_turns_delivered": covered == len(positive) if turn_available else None,
        "sufficient_evidence_token_feasibility": None}


def _same_uuid(left, right):
    return isinstance(left, str) and isinstance(right, str) and e.UUID.fullmatch(left) and left.lower() == right.lower()


def validate_request_links(item, request, configuration):
    """Metadata consistency only; native journal checks establish body provenance."""
    preparation = item.get("preparation")
    if preparation is None:
        if item.get("invocation_started") is True or item.get("invocation_status") in ("complete", "partial"):
            raise e.EvaluationError("missing native request provenance")
        if item.get("delivered_ranges") or item.get("delivered_recent_source_ids"):
            raise e.EvaluationError("unlinked delivered source evidence")
        return
    if not isinstance(preparation, dict) or not isinstance(item.get("identifiers"), dict):
        raise e.EvaluationError("invalid native request provenance")
    identifiers = item["identifiers"]
    for key in ("episodeID", "invocationID", "humanEventID", "assistantEventID", "turnID"):
        if not isinstance(identifiers.get(key), str) or not e.UUID.fullmatch(identifiers[key]):
            raise e.EvaluationError("invalid native invocation identifiers")
    for key in ("request_sha256", "selection_sha256"):
        if not isinstance(preparation.get(key), str) or not e.SHA.fullmatch(preparation[key]):
            raise e.EvaluationError("invalid native request digest")
    for key in ("selection_work_id", "answer_work_id"):
        if not isinstance(preparation.get(key), str) or not e.UUID.fullmatch(preparation[key]):
            raise e.EvaluationError("invalid native request work linkage")
    admission, audit = preparation.get("admission_audit"), preparation.get("context_audit")
    receipt = preparation.get("admission")
    if not isinstance(admission, dict) or not isinstance(audit, dict) or not isinstance(receipt, dict):
        raise e.EvaluationError("invalid native admission metadata")
    if admission.get("receipt") != receipt:
        raise e.EvaluationError("native admission receipt mismatch")
    proof = receipt.get("componentProof") if isinstance(receipt, dict) else None
    if (not isinstance(receipt, dict) or not isinstance(proof, dict)
            or type(admission.get("version")) is not int or admission["version"] != 3
            or not isinstance(admission.get("inputProofWorkID"), str) or not e.UUID.fullmatch(admission["inputProofWorkID"])
            or not isinstance(admission.get("inputProofSHA256"), str) or not e.SHA.fullmatch(admission["inputProofSHA256"])
            or receipt.get("bodyDigest") != preparation["request_sha256"]
            or proof.get("bodyDigest") != preparation["request_sha256"]
            or proof.get("sourceSnapshotDigest") != preparation["selection_sha256"]
            or audit.get("source_snapshot_sha256") != preparation["selection_sha256"]
            or not _same_uuid(audit.get("selection_work_id"), preparation["selection_work_id"])
            or not _same_uuid(receipt.get("episodeID"), identifiers["episodeID"])
            or not _same_uuid(proof.get("episodeID"), identifiers["episodeID"])
            or proof.get("projectID") != "answer-evaluation-public:" + request["project_id"]
            or receipt.get("outputReserve") != configuration["maximum_output"]
            or proof.get("outputReserve") != configuration["maximum_output"]
            or receipt.get("endpoint") != chat_endpoint(configuration["endpoint"])
            or proof.get("endpoint") != receipt["endpoint"]
            or type(audit.get("recent_source_count")) is not int
            or audit["recent_source_count"] != len(item["delivered_recent_source_ids"])):
        raise e.EvaluationError("native request linkage mismatch")
    recent = item["delivered_recent_source_ids"]
    if audit.get("ordered_recent_source_ids_sha256") != e.digest(canonical_json(recent)):
        raise e.EvaluationError("native recent source linkage mismatch")
    try:
        context = e.strict_json(base64.b64decode(admission["context"], validate=True))
    except Exception:
        raise e.EvaluationError("invalid native admission context") from None
    if context != audit:
        raise e.EvaluationError("native admission context mismatch")
    historical = audit.get("historical_sources")
    if not isinstance(historical, list):
        raise e.EvaluationError("invalid native historical source inventory")
    expected = []
    for row in historical:
        if not isinstance(row, dict) or any(k not in row for k in ("event_id", "excerpt_offset", "excerpt_bytes", "excerpt_sha256")):
            raise e.EvaluationError("invalid native historical source row")
        expected.append({"event_id": row["event_id"], "offset": row["excerpt_offset"],
                         "byte_length": row["excerpt_bytes"], "sha256": row["excerpt_sha256"]})
    # Native report appends complete recent source rows after historical rows.
    ranges = item["delivered_ranges"]
    if ranges[:len(expected)] != expected or [row["event_id"] for row in ranges[len(expected):]] != recent:
        raise e.EvaluationError("native delivered source audit mismatch")


def _empty_attempt(history, request, ordinal, reason):
    probe = validate_history(history)
    delivery = delivery_diagnostic(history, request, [], [])
    # Missing or rejected native evidence is unknown, not measured zero recall.
    for key in ("validated_delivered_source_count", "hit_gold_session_count", "session_hit_fraction",
                "all_gold_sessions_hit", "fully_delivered_evidence_turn_count",
                "full_evidence_turn_delivery_fraction", "all_evidence_turns_delivered"):
        delivery[key] = None
    return {"ordinal": ordinal, "question_id": probe["question_id"], "question_type": probe["question_type"],
        "abstention": probe["abstention"], "strategy": request["strategy"], "replicate": request["replicate"],
        "operational_complete": False, "official_qa_score": None, "official_qa_status": "pending_official_judge",
        "answer_bytes": None, "answer_sha256": None,
        "delivery": delivery,
        "failure_code": reason, "metadata": None}


def score_native(native, directory, history, document):
    """Return content-free attempts and a separate private prediction inventory."""
    probe = validate_history(history)
    requested = document["attempts"]
    if (canonical_json(document) != canonical_json(cases.runner_input(history, CONFIGURATION, version=RUNNER_DOCUMENT_VERSION))
            or len(requested) != 2 or [r["strategy"] for r in requested] != list(e.STRATEGIES)
            or any(type(r.get("replicate")) is not int or r["replicate"] != 0 for r in requested)):
        raise e.EvaluationError("benchmark runner document mismatch")
    if not isinstance(native, dict) or type(native.get("version")) is not int or native["version"] != 1:
        raise e.EvaluationError("invalid native report version")
    raw = native.get("attempts")
    if not isinstance(raw, list) or len(raw) > len(requested) or any(not isinstance(row, dict) for row in raw):
        raise e.EvaluationError("invalid native attempt inventory")
    pins = {"input_sha256": e.digest(canonical_json(document)),
            "public_projection_sha256": e.digest(canonical_json({k: v for k, v in document.items() if k != "configuration"})),
            "native_configuration_sha256": native_configuration_sha256(CONFIGURATION)}
    if any((key in native and native[key] != value) or (raw and key not in native) for key, value in pins.items()):
        raise e.EvaluationError("native document provenance mismatch")
    if raw and (native.get("history_id") != history["id"] or native.get("split") != "development"
            or type(native.get("declared_attempts")) is not int or native["declared_attempts"] != len(requested)
            or type(native.get("completed_attempts")) is not int
            or native["completed_attempts"] != sum(row.get("terminalized") is True for row in raw)):
        raise e.EvaluationError("native declared attempt linkage mismatch")
    public_ids = frozenset([history["id"], probe["id"], probe["question_id"], *(event["id"] for event in history["events"])])
    results, predictions = [], []
    for ordinal, request in enumerate(requested):
        row = _empty_attempt(history, request, ordinal, "native_attempt_unavailable")
        answer = ""
        if ordinal < len(raw):
            item = raw[ordinal]
            if (type(item.get("ordinal")) is not int or item["ordinal"] != ordinal
                    or type(item.get("replicate")) is not int
                    or any(item.get(k) != request[k] for k in ("probe_id", "strategy", "replicate"))
                    or type(item.get("terminalized")) is not bool
                    or (item["terminalized"] and item.get("answer_file") != f"answer-{ordinal:04d}.txt")
                    or ("answer_file" in item and item["answer_file"] != f"answer-{ordinal:04d}.txt")):
                raise e.EvaluationError("native terminal attempt linkage mismatch")
            row["metadata"] = e.content_free_metadata(item, public_ids)
            if item["terminalized"]:
                if (item.get("episode_state") not in (None, "completed", "failed", "cancelled", "interrupted", "deadlineExceeded", "budgetExceeded")
                        or item.get("invocation_status") not in (None, "complete", "partial", "failed", "cancelled")
                        or any(key in item and type(item[key]) is not bool for key in ("capture_healthy", "accounting_healthy", "invocation_started"))):
                    raise e.EvaluationError("invalid native terminal state")
                ranges, recent = item.get("delivered_ranges"), item.get("delivered_recent_source_ids")
                coverage = delivery_diagnostic(history, request, ranges, recent)
                validate_request_links(item, request, CONFIGURATION)
                encoded = e.read_file(directory / item["answer_file"], 4 * 1024 * 1024)
                if (type(item.get("answer_bytes")) is not int or item["answer_bytes"] != len(encoded)
                        or item.get("answer_sha256") != e.digest(encoded)):
                    raise e.EvaluationError("native answer IPC digest mismatch")
                try:
                    private_answer = encoded.decode("utf-8")
                except UnicodeError:
                    raise e.EvaluationError("invalid native answer encoding") from None
                operational = (item.get("episode_state") == "completed" and item.get("invocation_status") == "complete"
                    and item.get("capture_healthy") is True and item.get("accounting_healthy") is True
                    and item.get("invocation_started") is True and item.get("failure") is None)
                row.update(operational_complete=operational, answer_bytes=len(encoded), answer_sha256=e.digest(encoded),
                           delivery=coverage, failure_code=None if operational else "native_attempt_incomplete")
                answer = private_answer if operational else ""
                private_answer = ""
            else:
                row["failure_code"] = "native_attempt_interrupted"
        results.append(row)
        predictions.append({"strategy": request["strategy"], "question_id": probe["question_id"], "hypothesis": answer})
    return results, predictions


def summarize(attempts):
    result = {}
    for strategy in e.STRATEGIES:
        rows = [row for row in attempts if row["strategy"] == strategy]
        sessions = [row["delivery"]["session_hit_fraction"] for row in rows if row["delivery"]["session_hit_fraction"] is not None]
        turns = [row["delivery"]["full_evidence_turn_delivery_fraction"] for row in rows
                 if row["delivery"]["full_evidence_turn_delivery_fraction"] is not None]
        result[strategy] = {"declared_attempts": len(rows), "operational_completed": sum(row["operational_complete"] for row in rows),
            "operational_failures": sum(not row["operational_complete"] for row in rows),
            "official_qa_scored_attempts": 0, "official_qa_unscored_attempts": len(rows), "official_qa_score": None,
            "abstention_attempts": sum(row["abstention"] for row in rows),
            "session_hit_diagnostic_denominator": len(sessions),
            "mean_session_hit_fraction": sum(sessions) / len(sessions) if sessions else None,
            "full_evidence_turn_diagnostic_denominator": len(turns),
            "mean_full_evidence_turn_delivery_fraction": sum(turns) / len(turns) if turns else None}
    return result


def code_inventory():
    files = sorted(path for path in (e.ROOT / "Sources").rglob("*") if path.is_file())
    files += sorted((e.ROOT / "scripts").glob("*.py"))
    return {str(path.relative_to(e.ROOT)): e.digest(e.read_file(path)) for path in files}


def freeze_code(scratch, inventory):
    for relative, expected in inventory.items():
        data = e.read_file(e.ROOT / relative)
        if e.digest(data) != expected:
            raise e.EvaluationError("implementation changed before capture")
        target = scratch / "frozen-code" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        e.private_write(target, data)


def verified_driver(scratch, inventory, binary=None, binary_verification=None):
    if code_inventory() != inventory:
        raise e.EvaluationError("implementation changed before compilation")
    if binary is None:
        built, record = e.compile_driver(scratch)
        if (not isinstance(record, dict) or not isinstance(record.get("source_sha256"), dict)
                or any(inventory.get(key) != value for key, value in record["source_sha256"].items())
                or {k: v for k, v in record["source_sha256"].items() if k.startswith("Sources/")}
                    != {k: v for k, v in inventory.items() if k.startswith("Sources/")}):
            raise e.EvaluationError("compiled source inventory mismatch")
        binary_hash = e.digest(e.read_file(built, 256 * 1024 * 1024))
        if record.get("binary_sha256") != binary_hash:
            raise e.EvaluationError("compiled binary identity mismatch")
        implementation = {**record, "source_sha256": inventory,
            "source_binary_linkage": "compiled_native_sources_match_frozen_inventory",
            "python_dependencies_captured_before_compile": True}
    else:
        if binary_verification is None:
            raise e.EvaluationError("binary verification record required")
        encoded = e.read_file(binary_verification)
        try:
            record = e.strict_json(encoded)
        except Exception:
            raise e.EvaluationError("invalid binary verification record") from None
        built = Path(binary).absolute()
        binary_hash = e.digest(e.read_file(built, 256 * 1024 * 1024))
        if (not isinstance(record, dict) or record.get("terminal_passed") is not True
                or record.get("app_binary_sha256") != binary_hash
                or not isinstance(record.get("source_hashes"), dict)
                or any(record["source_hashes"].get(k) != v for k, v in inventory.items() if k.startswith("Sources/"))):
            raise e.EvaluationError("binary verification identity mismatch")
        implementation = {"source_sha256": inventory, "binary_sha256": binary_hash,
            "binary_verification_sha256": e.digest(encoded), "source_binary_linkage": "terminal_build_record_matches_all_native_sources",
            "python_dependencies_captured_before_compile": True}
    if code_inventory() != inventory:
        raise e.EvaluationError("implementation changed during compilation")
    return built, implementation


def export_hypotheses(directory, predictions, case_ids):
    result = {}
    for strategy in e.STRATEGIES:
        rows = [{"question_id": row["question_id"], "hypothesis": row["hypothesis"]}
                for row in predictions if row["strategy"] == strategy]
        if (len(rows) != len(case_ids) or [row["question_id"] for row in rows] != case_ids
                or any(type(row["hypothesis"]) is not str for row in rows)):
            raise e.EvaluationError("hypothesis export inventory mismatch")
        encoded = b"".join(canonical_json(row) + b"\n" for row in rows)
        e.private_write(directory / (strategy + ".jsonl"), encoded)
        result[strategy] = {"records": len(rows), "bytes": len(encoded), "sha256": e.digest(encoded)}
    return result


def _paths(output, hypotheses_directory):
    output = Path(output).absolute()
    directory = Path(hypotheses_directory)
    if not directory.is_absolute():
        raise e.EvaluationError("absolute hypothesis directory required")
    if directory.exists() or directory.is_symlink() or output.exists() or output.is_symlink():
        raise e.EvaluationError("evaluation output already exists")
    resolved = directory.resolve()
    # Also protect another repository selected by an absolute output path.
    for ancestor in (resolved, *resolved.parents):
        if (ancestor / ".git").exists() and not resolved.is_relative_to(ancestor / ".build"):
            raise e.EvaluationError("private hypotheses must be outside tracked source")
    if resolved.is_relative_to(e.ROOT.resolve()) and not resolved.is_relative_to((e.ROOT / ".build").resolve()):
        raise e.EvaluationError("private hypotheses must be outside tracked source")
    if output.resolve() in {resolved / name for name in ("declaration.json", "recent_only.jsonl", "hybrid.jsonl")}:
        raise e.EvaluationError("evaluation output path collision")
    return output, resolved


def run(source, output, hypotheses_directory, *, timeout=10800, binary=None, binary_verification=None):
    output, directory = _paths(output, hypotheses_directory)
    if type(timeout) is not int or not 60 <= timeout <= 21600:
        raise e.EvaluationError("invalid runner timeout")
    if (binary is None) != (binary_verification is None):
        raise e.EvaluationError("binary and verification record must be paired")
    histories = cases.prepare(source)
    if len(histories) != 7 or len({h["id"] for h in histories}) != 7:
        raise e.EvaluationError("invalid declared benchmark case inventory")
    probes = [validate_history(history) for history in histories]
    if (sum(probe["abstention"] for probe in probes) != 1
            or {probe["question_type"] for probe in probes if not probe["abstention"]} != TYPES):
        raise e.EvaluationError("invalid declared benchmark category inventory")
    documents = [cases.runner_input(history, CONFIGURATION, version=RUNNER_DOCUMENT_VERSION) for history in histories]
    annotations = []
    for history, document in zip(histories, documents):
        probe = validate_history(history)
        annotations.append({"question_id": probe["question_id"], "question_type": probe["question_type"],
            "abstention": probe["abstention"], "source_count": len(history["events"]),
            "source_bytes": sum(len(event["text"].encode()) for event in history["events"]),
            "runner_input_sha256": e.digest(canonical_json(document)),
            "public_projection_sha256": e.digest(canonical_json({k: v for k, v in document.items() if k != "configuration"})),
            "scorer_annotations_sha256": oracle_sha256(history)})
    inventory = code_inventory()
    declaration = {"version": 1, "split": "development", "declared_attempts": 14,
        "runner_document_version": RUNNER_DOCUMENT_VERSION,
        "case_ids": [row["question_id"] for row in annotations], "cases": annotations,
        "source_revision": cases.SOURCE_REVISION, "source_sha256": cases.SOURCE_SHA256,
        "configuration_sha256": e.digest(canonical_json(CONFIGURATION)),
        "native_configuration_sha256": native_configuration_sha256(CONFIGURATION),
        "system_sha256": e.digest(CONFIGURATION["system"].encode()), "source_hashes": inventory,
        "protocol_commit": PROTOCOL_COMMIT, "protocol_hashes": PROTOCOL_HASHES,
        "official_qa_score": None, "official_qa_status": "pending_official_judge"}
    # This durable, content-free declaration precedes compiler or provider work.
    directory.parent.mkdir(parents=True, exist_ok=True)
    directory.mkdir(mode=0o700)
    e.private_write(directory / "declaration.json", canonical_json(declaration) + b"\n")
    with tempfile.TemporaryDirectory(prefix="boros-longmemeval-") as temporary:
        scratch = Path(temporary).resolve(); os.chmod(scratch, 0o700)
        freeze_code(scratch, inventory)
        built, implementation = verified_driver(scratch, inventory, binary, binary_verification)
        results, predictions = [], []
        for index, (history, document) in enumerate(zip(histories, documents)):
            if code_inventory() != inventory or e.digest(e.read_file(built, 256 * 1024 * 1024)) != implementation["binary_sha256"]:
                raise e.EvaluationError("implementation changed before execution")
            input_path, native_directory = scratch / f"input-{index}.json", scratch / f"output-{index}"
            e.private_write(input_path, canonical_json(document))
            try:
                native = e.execute(built, input_path, native_directory, timeout)
                if (e.digest(e.read_file(input_path)) != annotations[index]["runner_input_sha256"]
                        or oracle_sha256(history) != annotations[index]["scorer_annotations_sha256"]):
                    raise e.EvaluationError("frozen benchmark evidence changed")
                attempts, private_predictions = score_native(native, native_directory, history, document)
            except Exception as error:
                # Do not publish exceptions containing source-bearing paths/text.
                native = {"version": 1, "fatal_failure": "runner_report_invalid", "attempts": []}
                if isinstance(error, e.EvaluationError):
                    native["validation_error_sha256"] = e.digest(str(error).encode())
                attempts, private_predictions = score_native(native, native_directory, history, document)
            results.append({"case": annotations[index], "attempts": attempts, "driver": e.native_metadata(native)})
            predictions.extend(private_predictions)
        if code_inventory() != inventory or e.digest(e.read_file(built, 256 * 1024 * 1024)) != implementation["binary_sha256"]:
            raise e.EvaluationError("implementation changed during execution")
        exports = export_hypotheses(directory, predictions, declaration["case_ids"])
        predictions.clear()
        attempts = [attempt for result in results for attempt in result["attempts"]]
        report = {"longmemeval_evaluation_version": 1, "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
            "registration_status": "unregistered_development_subset", "split": "development", "runner_document_version": RUNNER_DOCUMENT_VERSION,
            "source": {"repository": "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned",
                "revision": cases.SOURCE_REVISION, "path": cases.SOURCE_NAME, "sha256": cases.SOURCE_SHA256, "bytes": cases.SOURCE_BYTES},
            "configuration": {key: value for key, value in CONFIGURATION.items() if key != "system"},
            "declaration": declaration, "declaration_sha256": e.digest(canonical_json(declaration) + b"\n"),
            "implementation": implementation, "histories": results, "summary": summarize(attempts),
            "private_hypothesis_exports": exports, "replicates": 1, "strategy_order": list(e.STRATEGIES),
            "official_qa_score": None, "official_qa_status": "pending_official_judge",
            "official_retrieval_score": None, "longmemeval_v2_status": "unimplemented",
            "limitations": ["seven frozen development cases; no full benchmark or representative quality claim",
                "official QA judge not called; complete natural answers exported privately for separate authorized scoring",
                "session hit diagnostic requires any validated source range; it does not establish complete session recall",
                "full evidence turn delivery checks both roles and all original UTF-8 bytes; it is not official top-k recall",
                "abstentions excluded only from delivery denominators; all declared QA and operational attempts retained",
                "request linkage check is metadata consistency; native journal verification establishes original source and body provenance",
                "recent-only uses the final supplied session; source array need not be date-sorted",
                "one replicate; fixed strategy order; uncontrolled caches; judge and host diagnostic work excluded from episode charges"]}
        output.parent.mkdir(parents=True, exist_ok=True)
        e.private_write(output, canonical_json(report) + b"\n")
    return report


def main():
    parser = e.SafeParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--hypotheses-directory", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=10800)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--binary-verification", type=Path)
    args = parser.parse_args()
    try:
        report = run(args.source, args.output, args.hypotheses_directory, timeout=args.timeout,
                     binary=args.binary, binary_verification=args.binary_verification)
        print(json.dumps({"declared_attempts": 14, "official_qa_score": None, "summary": report["summary"]}, sort_keys=True))
        return 0
    except Exception:
        print("LongMemEval evaluation failed; content diagnostics suppressed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
