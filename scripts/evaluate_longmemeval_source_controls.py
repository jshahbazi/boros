#!/usr/bin/env python3
"""Run six separately pinned supplementary-source controls with a verified app."""
from __future__ import annotations

from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import sys
import tempfile

import evaluate_answers as e
import evaluate_longmemeval as baseline
import longmemeval_source_controls as controls

CONFIGURATION = dict(baseline.CONFIGURATION)
OUTCOME_VERSION = "declared-original-sources-v1"
OUTCOME_FIELDS = {"version", "declared_source_count", "declared_source_bytes", "delivered_source_count",
    "complete_declared_sources_delivered", "source_body_count_revalidated", "input_proof_version",
    "failure_code", "validation_milliseconds"}
FAILURES = {None, "source_control_outcome_unavailable", "source_control_source_body_count_invalid",
    "declared_sources_not_delivered"}


def unavailable_control(history, request):
    inventory = controls.source_inventory(history, request["evidence_source_ids"])
    return {"version": OUTCOME_VERSION, "declared_source_count": len(inventory),
        "declared_source_bytes": sum(source["byte_length"] for source in inventory),
        "delivered_source_count": None, "complete_declared_sources_delivered": None,
        "source_body_count_revalidated": None, "input_proof_version": None,
        "failure_code": "source_control_outcome_unavailable", "validation_milliseconds": None}


def union_complete(intervals, source_id, length):
    cursor = 0
    for start, end in sorted(intervals.get(source_id, [])):
        if start > cursor:
            return False
        cursor = max(cursor, end)
    return cursor >= length


def validate_control_outcome(item, history, request):
    outcome = item.get("source_control_validation")
    expected = unavailable_control(history, request)
    if (not isinstance(outcome, dict) or set(outcome) != OUTCOME_FIELDS or outcome.get("version") != OUTCOME_VERSION
            or any(type(outcome.get(key)) is not int or outcome[key] != expected[key]
                   for key in ("declared_source_count", "declared_source_bytes"))
            or outcome.get("failure_code") not in FAILURES):
        raise e.EvaluationError("invalid source control outcome inventory")
    for field in ("complete_declared_sources_delivered", "source_body_count_revalidated"):
        if outcome[field] is not None and type(outcome[field]) is not bool:
            raise e.EvaluationError("invalid source control boolean")
    count = outcome["delivered_source_count"]
    if count is not None and (type(count) is not int or not 0 <= count <= expected["declared_source_count"]):
        raise e.EvaluationError("invalid source control delivered count")
    duration = outcome["validation_milliseconds"]
    if duration is not None and (type(duration) not in (int, float) or duration < 0 or not math.isfinite(duration)):
        raise e.EvaluationError("invalid source control validation time")
    if outcome["input_proof_version"] is not None and (type(outcome["input_proof_version"]) is not int or outcome["input_proof_version"] != 3):
        raise e.EvaluationError("invalid source control proof version")
    if outcome["source_body_count_revalidated"] is True:
        if (item.get("preparation") is None or count is None or type(outcome["complete_declared_sources_delivered"]) is not bool
                or outcome["input_proof_version"] != 3):
            raise e.EvaluationError("source control proof outcome unavailable")
        intervals = baseline.validated_intervals(history, request, item.get("delivered_ranges"), item.get("delivered_recent_source_ids"))
        sources = {event["id"]: event for event in history["events"]}
        actual = sum(union_complete(intervals, source_id, len(sources[source_id]["text"].encode()))
                     for source_id in request["evidence_source_ids"])
        complete = actual == len(request["evidence_source_ids"])
        if (count != actual or outcome["complete_declared_sources_delivered"] != complete
                or outcome["failure_code"] != (None if complete else "declared_sources_not_delivered")):
            raise e.EvaluationError("source control full range union mismatch")
    else:
        if (count is not None or outcome["complete_declared_sources_delivered"] is not None
                or outcome["input_proof_version"] is not None or outcome["failure_code"] is None):
            raise e.EvaluationError("unverified source control claims delivery")
    return dict(outcome)


def _empty_attempt(history, request, reason):
    row = baseline._empty_attempt(history, request, 0, reason)
    row["source_control_validation"] = unavailable_control(history, request)
    row["full_pack_delivery_eligible"] = False
    row["semantic_sufficiency"] = None
    row["provider_token_feasibility"] = None
    row["official_qa_status"] = "not_run_source_control_judge"
    return row


def score_native(native, directory, history, document, *, source_ids=None):
    controls.validate_document(history, document, CONFIGURATION, source_ids)
    request = document["attempts"][0]
    if (not isinstance(native, dict) or type(native.get("version")) is not int or native["version"] != 1
            or not isinstance(native.get("attempts"), list) or len(native["attempts"]) > 1):
        raise e.EvaluationError("invalid control native attempt inventory")
    raw = native["attempts"]
    pins = {"input_sha256": e.digest(e.canonical_json(document)),
        "public_projection_sha256": controls.projection_sha256(document),
        "native_configuration_sha256": baseline.native_configuration_sha256(CONFIGURATION)}
    if any((key in native and native[key] != value) or (raw and key not in native) for key, value in pins.items()):
        raise e.EvaluationError("control native projection mismatch")
    if raw and (native.get("history_id") != history["id"] or native.get("split") != "development"
            or type(native.get("declared_attempts")) is not int or native["declared_attempts"] != 1
            or type(native.get("completed_attempts")) is not int
            or native["completed_attempts"] != sum(row.get("terminalized") is True for row in raw if isinstance(row, dict))):
        raise e.EvaluationError("control native declared attempt mismatch")
    row = _empty_attempt(history, request, "native_attempt_unavailable")
    answer = ""
    if raw:
        item = raw[0]
        if (not isinstance(item, dict) or type(item.get("ordinal")) is not int or item["ordinal"] != 0
                or type(item.get("replicate")) is not int or item["replicate"] != 0
                or any(item.get(key) != request[key] for key in ("probe_id", "strategy", "replicate"))
                or type(item.get("terminalized")) is not bool
                or ("answer_file" in item and item["answer_file"] != "answer-0000.txt")
                or (item["terminalized"] and item.get("answer_file") != "answer-0000.txt")):
            raise e.EvaluationError("control native attempt linkage mismatch")
        public_ids = frozenset([history["id"], request["probe_id"], *(event["id"] for event in history["events"])])
        row["metadata"] = e.content_free_metadata(item, public_ids)
        row["source_control_validation"] = validate_control_outcome(item, history, request)
        if item["terminalized"]:
            if (item.get("episode_state") not in (None, "completed", "failed", "cancelled", "interrupted", "deadlineExceeded", "budgetExceeded")
                    or item.get("invocation_status") not in (None, "complete", "partial", "failed", "cancelled")
                    or any(key in item and type(item[key]) is not bool for key in ("capture_healthy", "accounting_healthy", "invocation_started"))):
                raise e.EvaluationError("invalid control native operational state")
            ranges, recent = item.get("delivered_ranges"), item.get("delivered_recent_source_ids")
            delivery = baseline.delivery_diagnostic(history, request, ranges, recent)
            baseline.validate_request_links(item, request, CONFIGURATION)
            if item.get("preparation") is not None:
                selected = set(request["evidence_source_ids"])
                audit = item["preparation"]["context_audit"]
                retrieval = audit.get("retrieval")
                inventory = controls.source_inventory(history, request["evidence_source_ids"])
                if (not isinstance(retrieval, dict) or retrieval.get("mode") != "declared_original_sources"
                        or retrieval.get("version") != OUTCOME_VERSION
                        or type(retrieval.get("declared_source_count")) is not int
                        or retrieval["declared_source_count"] != len(inventory)
                        or type(retrieval.get("declared_source_bytes")) is not int
                        or retrieval["declared_source_bytes"] != sum(row["byte_length"] for row in inventory)
                        or retrieval.get("declared_source_ids_sha256") != e.digest(e.canonical_json(request["evidence_source_ids"]))
                        or retrieval.get("semantic_available") is not False):
                    raise e.EvaluationError("control retrieval declaration binding mismatch")
                historical = audit["historical_sources"]
                if any(source["event_id"] not in selected for source in historical):
                    raise e.EvaluationError("control includes undeclared historical evidence")
            encoded = e.read_file(Path(directory) / item["answer_file"], 4 * 1024 * 1024)
            if (type(item.get("answer_bytes")) is not int or item["answer_bytes"] != len(encoded)
                    or item.get("answer_sha256") != e.digest(encoded)):
                raise e.EvaluationError("control answer IPC digest mismatch")
            try:
                private_answer = encoded.decode("utf-8")
            except UnicodeError:
                raise e.EvaluationError("invalid control answer encoding") from None
            operational = (item.get("episode_state") == "completed" and item.get("invocation_status") == "complete"
                and all(item.get(key) is True for key in ("capture_healthy", "accounting_healthy", "invocation_started"))
                and item.get("failure") is None)
            row.update(operational_complete=operational, answer_bytes=len(encoded), answer_sha256=e.digest(encoded),
                delivery=delivery, failure_code=None if operational else "native_attempt_incomplete")
            row["full_pack_delivery_eligible"] = row["source_control_validation"]["complete_declared_sources_delivered"] is True
            answer = private_answer if operational else ""
            private_answer = ""
        else:
            if (row["source_control_validation"]["source_body_count_revalidated"] is not None
                    or row["source_control_validation"]["delivered_source_count"] is not None):
                raise e.EvaluationError("nonterminal control claims a delivery outcome")
            row["failure_code"] = "native_attempt_interrupted"
    return row, {"question_id": history["episodes"][0]["question_id"], "hypothesis": answer}


def summarize(attempts):
    return {"declared_attempts": len(attempts), "operational_completed": sum(row["operational_complete"] for row in attempts),
        "operational_failures": sum(not row["operational_complete"] for row in attempts),
        "full_declared_sources_delivered": sum(row["full_pack_delivery_eligible"] for row in attempts),
        "source_body_count_revalidated": sum(row["source_control_validation"]["source_body_count_revalidated"] is True for row in attempts),
        "control_outcomes_unavailable": sum(row["source_control_validation"]["complete_declared_sources_delivered"] is None for row in attempts),
        "official_qa_scored_attempts": 0, "official_qa_unscored_attempts": len(attempts), "official_qa_score": None,
        "semantic_sufficiency": None, "provider_token_feasibility": None}


def export_hypotheses(directory, predictions):
    if (len(predictions) != 6 or [row.get("question_id") for row in predictions] != list(controls.CASE_IDS)
            or any(set(row) != {"question_id", "hypothesis"} or type(row["hypothesis"]) is not str for row in predictions)):
        raise e.EvaluationError("control private hypothesis inventory mismatch")
    data = b"".join(e.canonical_json(row) + b"\n" for row in predictions)
    e.private_write(Path(directory) / "source_control.jsonl", data)
    return {"source_control": {"records": 6, "bytes": len(data), "sha256": e.digest(data)}}


def implementation_matches(binary, inventory, binary_sha256):
    try:
        return (baseline.code_inventory() == inventory
                and e.digest(e.read_file(binary, 256 * 1024 * 1024)) == binary_sha256)
    except Exception:
        return False


def run(source, output, hypotheses_directory, *, timeout=10800, binary=None, binary_verification=None):
    if not Path(output).is_absolute():
        raise e.EvaluationError("absolute control report required")
    if binary is None or binary_verification is None:
        raise e.EvaluationError("source controls require verified prebuilt app")
    output, directory = baseline._paths(output, hypotheses_directory)
    if (output.resolve() == directory / "source_control.jsonl" or output.resolve() == directory
            or output.resolve() in directory.parents):
        raise e.EvaluationError("control output path collision")
    if type(timeout) is not int or not 60 <= timeout <= 21600:
        raise e.EvaluationError("invalid control runner timeout")
    histories = controls.prepare(source)
    documents = [controls.runner_input(history, CONFIGURATION) for history in histories]
    annotations = [controls.declaration_case(history, document) for history, document in zip(histories, documents)]
    inventory = baseline.code_inventory()
    declaration = {"version": 1, "control_version": controls.CONTROL_VERSION, "split": "development",
        "declared_attempts": 6, "runner_document_version": 6, "strategy": "hybrid", "replicates": 1,
        "case_ids": list(controls.CASE_IDS), "cases": annotations,
        "source_revision": controls.cases.SOURCE_REVISION, "source_sha256": controls.cases.SOURCE_SHA256,
        "source_bytes": controls.cases.SOURCE_BYTES, "source_hashes": inventory,
        "configuration_sha256": e.digest(e.canonical_json(CONFIGURATION)),
        "native_configuration_sha256": baseline.native_configuration_sha256(CONFIGURATION),
        "system_sha256": e.digest(CONFIGURATION["system"].encode()),
        "ordinary_recall_arm": False, "selection_uses_positive_annotations": True,
        "semantic_sufficiency": None, "provider_token_feasibility": None,
        "official_qa_status": "not_run_source_control_judge", "official_qa_score": None}
    directory.parent.mkdir(parents=True, exist_ok=True)
    directory.mkdir(mode=0o700)
    e.private_write(directory / "declaration.json", e.canonical_json(declaration) + b"\n")
    with tempfile.TemporaryDirectory(prefix="boros-longmemeval-source-control-") as temporary:
        scratch = Path(temporary).resolve(); os.chmod(scratch, 0o700)
        baseline.freeze_code(scratch, inventory)
        for parent, directories, _files in os.walk(scratch):
            os.chmod(parent, 0o700)
        built, implementation = baseline.verified_driver(scratch, inventory, binary, binary_verification)
        results, predictions = [], []
        implementation_continuity = True
        for index, (history, document) in enumerate(zip(histories, documents)):
            if not implementation_matches(built, inventory, implementation["binary_sha256"]):
                implementation_continuity = False
            input_path, native_directory = scratch / f"input-{index}.json", scratch / f"output-{index}"
            e.private_write(input_path, e.canonical_json(document))
            try:
                if not implementation_continuity:
                    raise e.EvaluationError("control implementation changed before execution")
                native = e.execute(built, input_path, native_directory, timeout)
                if (e.digest(e.read_file(input_path)) != annotations[index]["runner_input_sha256"]
                        or baseline.oracle_sha256(history) != annotations[index]["scorer_annotations_sha256"]):
                    raise e.EvaluationError("frozen control evidence changed")
                row, prediction = score_native(native, native_directory, history, document)
            except Exception:
                native = {"version": 1, "fatal_failure": "runner_report_invalid" if implementation_continuity else "implementation_changed",
                    "attempts": []}
                row, prediction = score_native(native, native_directory, history, document)
            results.append({"case": annotations[index], "attempts": [row], "driver": e.native_metadata(native)})
            predictions.append(prediction)
        if not implementation_matches(built, inventory, implementation["binary_sha256"]):
            implementation_continuity = False
        exports = export_hypotheses(directory, predictions); predictions.clear()
        attempts = [row for result in results for row in result["attempts"]]
        report = {"source_control_evaluation_version": 1, "control_version": controls.CONTROL_VERSION,
            "recorded_at_utc": datetime.now(timezone.utc).isoformat(), "split": "development",
            "registration_status": "unregistered_reused_development_source_control", "runner_document_version": 6,
            "declaration": declaration, "declaration_sha256": e.digest(e.canonical_json(declaration) + b"\n"),
            "implementation": implementation, "implementation_continuity": implementation_continuity,
            "configuration": {k: v for k, v in CONFIGURATION.items() if k != "system"},
            "histories": results, "summary": summarize(attempts), "private_hypothesis_exports": exports,
            "ordinary_recall_arm": False, "official_qa_score": None, "official_qa_status": "not_run_source_control_judge",
            "limitations": ["six reused answerable development cases; absence case excluded before execution",
                "oracle-derived selected originals supplement ordinary retained recent sources; distractors may remain",
                "full declared source delivery is not proof of semantic sufficiency or sufficient-evidence provider fit",
                "token or envelope reduction makes full-pack delivery ineligible; all attempts remain in denominator",
                "native body/count revalidation remains distinct from transport completion and answer correctness",
                "offline native proof checks and host diagnostics are separate from episode resource charges",
                "fixed original histories/questions/dates and provider caps; one hybrid attempt per case; uncontrolled caches",
                "QA not called; six-case exports require a separately implemented control judge contract"]}
        output.parent.mkdir(parents=True, exist_ok=True)
        e.private_write(output, e.canonical_json(report) + b"\n")
    return report


def main():
    parser = e.SafeParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--hypotheses-directory", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--binary-verification", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=10800)
    args = parser.parse_args()
    try:
        report = run(args.source, args.output, args.hypotheses_directory, timeout=args.timeout,
            binary=args.binary, binary_verification=args.binary_verification)
        print(json.dumps({"declared_attempts": 6, "summary": report["summary"]}, sort_keys=True))
        return 0
    except Exception:
        print("LongMemEval source controls failed; content diagnostics suppressed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
