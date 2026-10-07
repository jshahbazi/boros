#!/usr/bin/env python3
"""Frozen 100-question local investigation with durable per-operation replay fences."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import statistics
import subprocess
import time
import uuid

import evaluate_answers as e
import evaluate_longmemeval as evaluation
import jevk5_saved_qa as jev
import native_investigation_hundred_cases as cases
import orientation_zoom_judging as judging

ROOT = Path(__file__).resolve().parents[1]
VERSION = "native-memory-investigation-100-v1"
PREPARATION_MODE = "native-investigation-100-v1"
CASE_FAILURES = frozenset(("episode_budget_exceeded", "episode_deadline_exceeded", "context_full",
    "native_investigation_format_failed", "native_investigation_output_bound_exceeded", "incomplete_result"))


def require(condition, code):
    if not condition:
        raise e.EvaluationError(code)


def code(error, fallback):
    # Never publish free-form exception text, even for a nominally trusted class.
    value = str(error)
    return value if isinstance(error, (e.EvaluationError, jev.SavedQAError)) and value.replace("_", "").isalnum() else fallback


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write(path, value):
    e.private_write(path, jev.canonical(value))
    sync_directory(path.parent)


def atomic_write(path, value):
    temporary = path.parent / (".checkpoint-" + uuid.uuid4().hex)
    write(temporary, value)
    os.replace(temporary, path)
    sync_directory(path.parent)


def private_destination(output):
    output = Path(output).absolute()
    require(output.is_relative_to(ROOT / ".build") and not output.exists()
        and not any(parent.is_symlink() for parent in (output, *output.parents)), "hundred_destination_invalid")
    output.mkdir(mode=0o700, parents=True)
    return output


def select(source, output):
    histories, manifest = cases.prepare(source)
    output = private_destination(output)
    artifacts = {}
    for ordinal, history in enumerate(histories):
        for prefix, value in (("input", cases.runner_input(history)), ("scorer", history)):
            name = f"{prefix}-{ordinal}.json"
            raw = jev.canonical(value)
            e.private_write(output / name, raw)
            artifacts[name] = e.digest(raw)
    manifest["artifacts"] = artifacts
    write(output / "selection-manifest.json", manifest)
    return manifest


def validate_selection(selection):
    manifest = e.strict_json(e.read_file(selection / "selection-manifest.json"))
    require(manifest.get("version") == cases.DOMAIN and manifest.get("cohort") == cases.COHORT
        and manifest.get("declared_questions") == 100 and manifest.get("runner_document_version") == 8
        and manifest.get("configuration") == cases.CONFIGURATION
        and manifest.get("excluded_case_ids") == list(cases.EXCLUDED_CASE_IDS)
        and manifest.get("source", {}).get("sha256") == cases.qa.SOURCE_SHA256
        and len(manifest.get("cases", [])) == 100 and len(manifest.get("case_ids", [])) == 100
        and len(set(manifest["case_ids"])) == 100 and not set(manifest["case_ids"]).intersection(cases.EXCLUDED_CASE_IDS),
        "hundred_selection_manifest_invalid")
    require(set(manifest["artifacts"]) == {f"{prefix}-{ordinal}.json" for prefix in ("input", "scorer") for ordinal in range(100)},
        "hundred_selection_artifact_inventory_invalid")
    for ordinal, metadata in enumerate(manifest["cases"]):
        require(metadata.get("ordinal") == ordinal and metadata.get("question_id") == manifest["case_ids"][ordinal],
            "hundred_selection_order_invalid")
        document = e.strict_json(e.read_file(selection / f"input-{ordinal}.json"))
        history = e.strict_json(e.read_file(selection / f"scorer-{ordinal}.json"))
        evaluation.validate_history(history)
        require(document == cases.runner_input(history) and cases.annotation(history) == {k: v for k, v in metadata.items() if k != "ordinal"},
            "hundred_selection_projection_invalid")
        for prefix in ("input", "scorer"):
            name = f"{prefix}-{ordinal}.json"
            require(e.digest(e.read_file(selection / name)) == manifest["artifacts"][name], "hundred_selection_capture_changed")
    return manifest


def prepare(selection, binary, verification, protocol, output):
    selection = Path(selection).resolve()
    manifest = validate_selection(selection)
    binary = Path(binary).resolve()
    record_raw = e.read_file(Path(verification))
    record = e.strict_json(record_raw)
    inventory = evaluation.code_inventory()
    binary_sha = e.digest(e.read_file(binary, 256 * 1024 * 1024))
    require(record.get("terminal_passed") is True and record.get("app_binary_sha256") == binary_sha
        and all(record.get("source_hashes", {}).get(key) == sha for key, sha in inventory.items() if key.startswith("Sources/")),
        "hundred_binary_unverified")
    protocol_raw = e.read_file(Path(protocol))
    require(e.digest(protocol_raw) == jev.PROTOCOL_SHA256, "hundred_protocol_changed")
    output = private_destination(output)
    artifacts = {}

    def freeze(relative, raw):
        destination = output / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        e.private_write(destination, raw)
        artifacts[relative] = e.digest(raw)

    for relative in ("selection-manifest.json", *manifest["artifacts"]):
        freeze(relative, e.read_file(selection / relative))
    freeze("build-verification.json", record_raw)
    freeze("qa-protocol.py", protocol_raw)
    freeze("controls.json", jev.canonical(jev.controls(judging, output / "qa-protocol.py")))
    for relative, sha in inventory.items():
        raw = e.read_file(ROOT / relative)
        require(e.digest(raw) == sha, "hundred_source_changed")
        freeze("source-capture/" + relative, raw)
    declaration = {"version": VERSION, "preparation_mode": PREPARATION_MODE, "runner_document_version": 8,
        "declared_questions": 100, "declared_attempts": 100, "maximum_answer_attempts": 100,
        "maximum_judge_decisions": 106, "native_flag": "--investigate-memory", "strategy": "hybrid",
        "configuration": cases.CONFIGURATION, "case_ids": manifest["case_ids"], "cases": manifest["cases"],
        "selection_manifest_sha256": artifacts["selection-manifest.json"], "source_sha256": cases.qa.SOURCE_SHA256,
        "binary": str(binary), "binary_sha256": binary_sha, "source_hashes": inventory, "artifacts": artifacts,
        "judge_model": jev.MODEL, "connector_command": list(jev.COMMAND),
        "connector_executable_sha256": e.digest(e.read_file(Path(jev.COMMAND[0]), 1024 * 1024 * 1024)),
        "process_timeout_seconds": 400, "retry_count": 0, "remote_calls": 0,
        "failure_policy": "continue_case_budget_format_output_failures_stop_infrastructure_provenance_unknown_usage",
        "resumption_policy": "recover_durable_completed_capture_never_replay_ambiguous_dispatch_or_judgment"}
    write(output / "declaration.json", declaration)
    return declaration


def verify(output, declaration, *, check_live=True):
    require(declaration.get("version") == VERSION and declaration.get("preparation_mode") == PREPARATION_MODE
        and declaration.get("runner_document_version") == 8 and declaration.get("declared_questions") == 100
        and declaration.get("declared_attempts") == 100 and declaration.get("maximum_answer_attempts") == 100
        and declaration.get("maximum_judge_decisions") == 106 and declaration.get("retry_count") == 0
        and declaration.get("remote_calls") == 0 and declaration.get("process_timeout_seconds") == 400
        and declaration.get("native_flag") == "--investigate-memory" and declaration.get("strategy") == "hybrid"
        and declaration.get("configuration") == cases.CONFIGURATION and declaration.get("judge_model") == jev.MODEL
        and declaration.get("connector_command") == list(jev.COMMAND), "hundred_contract_changed")
    if check_live:
        require(evaluation.code_inventory() == declaration["source_hashes"], "hundred_live_source_changed")
        require(e.digest(e.read_file(Path(declaration["binary"]), 256 * 1024 * 1024)) == declaration["binary_sha256"],
            "hundred_binary_changed")
        require(e.digest(e.read_file(Path(jev.COMMAND[0]), 1024 * 1024 * 1024)) == declaration["connector_executable_sha256"],
            "hundred_connector_changed")
    for relative, sha in declaration["artifacts"].items():
        require(e.digest(e.read_file(output / relative)) == sha, "hundred_artifact_changed")
    manifest = validate_selection(output)
    require(manifest["case_ids"] == declaration["case_ids"] and manifest["cases"] == declaration["cases"],
        "hundred_declaration_selection_mismatch")


def empty_rows(declaration):
    return [{"ordinal": ordinal, "question_id": metadata["question_id"], "question_type": metadata["question_type"],
        "abstention": metadata["abstention"], "status": "not_run", "operational_complete": False,
        "judgment": None} for ordinal, metadata in enumerate(declaration["cases"])]


def summary(rows):
    require(len(rows) == 100 and [row["ordinal"] for row in rows] == list(range(100)), "hundred_denominator_invalid")
    latencies = [row["metadata"].get("full_host_milliseconds") for row in rows if row["operational_complete"]]
    latencies = [value for value in latencies if type(value) in (int, float)]
    accepted = sum(row["judgment"] is not None and row["judgment"]["choice"] == "yes" for row in rows)
    scored = sum(row["judgment"] is not None for row in rows)
    return {"declared": 100, "completed": sum(row["operational_complete"] for row in rows), "scored": scored,
        "accepted": accepted, "accepted_fraction_all_declared": accepted / 100,
        "accepted_fraction_scored": accepted / scored if scored else None,
        "not_run": sum(row["status"] == "not_run" for row in rows),
        "case_failures": sum(row["status"] == "case_failure" for row in rows),
        "median_turn_milliseconds": statistics.median(latencies) if latencies else None,
        "by_category": {category: {"declared": sum(row["question_type"] == category for row in rows),
            "completed": sum(row["question_type"] == category and row["operational_complete"] for row in rows),
            "scored": sum(row["question_type"] == category and row["judgment"] is not None for row in rows),
            "accepted": sum(row["question_type"] == category and row["judgment"] is not None
                and row["judgment"]["choice"] == "yes" for row in rows)} for category in cases.CATEGORIES},
        "abstention": {"declared": sum(row["abstention"] for row in rows),
            "scored": sum(row["abstention"] and row["judgment"] is not None for row in rows),
            "accepted": sum(row["abstention"] and row["judgment"] is not None
                and row["judgment"]["choice"] == "yes" for row in rows)}}


def assert_native(native, score):
    require(native.get("mode") == VERSION and native.get("preparation_mode") == PREPARATION_MODE
        and native.get("declared_attempts") == 1 and len(native.get("attempts", [])) == 1,
        "hundred_native_mode_missing")
    item = native["attempts"][0]
    require(item.get("memory_investigation") is True, "hundred_native_investigation_disabled")
    episode = item.get("episode")
    require(item.get("terminalized") is True and item.get("capture_healthy") is True
        and item.get("accounting_healthy") is True and isinstance(episode, dict)
        and episode.get("unknownInputOperations") == 0
        and item.get("unknown_output_operations") == 0 and item.get("unresolved_work_count") == 0
        and isinstance(episode.get("held"), dict) and all(type(v) is int and v == 0 for v in episode["held"].values()),
        "hundred_unknown_or_unhealthy_accounting")
    if score["operational_complete"]:
        audit = item.get("preparation", {}).get("context_audit", {}).get("retrieval", {}).get("native_investigation", {})
        require(audit.get("version") == "native-investigation-v1" and audit.get("private_stages", 0) >= 2
            and audit.get("derived_notes_in_final_request") is False, "hundred_native_preparation_missing")
        return "completed"
    require(item.get("failure") in CASE_FAILURES, "hundred_native_infrastructure_failure")
    return "case_failure"


def capture_case(output, declaration, ordinal):
    directory = output / f"native-{ordinal}"
    document = e.strict_json(e.read_file(output / f"input-{ordinal}.json"))
    history = e.strict_json(e.read_file(output / f"scorer-{ordinal}.json"))
    native = e.strict_json(e.read_file(directory / "report.json"))
    scores, _predictions = evaluation.score_native(native, directory, history, document,
        configuration=cases.CONFIGURATION, runner_document_version=8)
    require(len(scores) == 1, "hundred_native_score_inventory_invalid")
    score = scores[0]
    status = assert_native(native, score)
    return {"ordinal": ordinal, "question_id": history["episodes"][0]["question_id"], "status": status,
        "operational_complete": score["operational_complete"], "answer_sha256": score["answer_sha256"],
        "answer_bytes": score["answer_bytes"], "delivery": score["delivery"], "metadata": score["metadata"],
        "failure_code": None if status == "completed" else native["attempts"][0]["failure"],
        "native_report_sha256": e.digest(e.read_file(directory / "report.json"))}


def answer_case(output, declaration, ordinal, run):
    intent = output / f"question-{ordinal}-dispatch.json"
    result = output / f"question-{ordinal}-answer-result.json"
    expected_intent = {"declaration_sha256": e.digest(e.read_file(output / "declaration.json")), "ordinal": ordinal,
        "input_sha256": declaration["artifacts"][f"input-{ordinal}.json"], "dispatch_may_have_started": True}
    if result.exists():
        require(intent.exists() and e.strict_json(e.read_file(intent)) == expected_intent, "hundred_dispatch_intent_changed")
        saved = e.strict_json(e.read_file(result))
        require(saved == capture_case(output, declaration, ordinal), "hundred_saved_answer_capture_changed")
        return saved
    if not intent.exists():
        write(intent, expected_intent)
        try:
            process = run([declaration["binary"], "--answer-evaluation", str(output / f"input-{ordinal}.json"),
                "--output-directory", str(output / f"native-{ordinal}"), "--investigate-memory"],
                capture_output=True, timeout=400, env={**os.environ, "BOROS_DATA_DIR": str(output / "unused-app-runtime")})
        except subprocess.TimeoutExpired as error:
            e.private_write(output / f"native-{ordinal}-stdout", error.stdout or b"")
            e.private_write(output / f"native-{ordinal}-stderr", error.stderr or b"")
            raise e.EvaluationError("hundred_native_process_timeout") from None
        e.private_write(output / f"native-{ordinal}-stdout", process.stdout)
        e.private_write(output / f"native-{ordinal}-stderr", process.stderr)
        write(output / f"question-{ordinal}-process-result.json", {"returncode": process.returncode})
    # A complete, validated report can be recovered after a host crash. An intent
    # without it is ambiguous and is NEVER dispatched a second time.
    require((output / f"native-{ordinal}/report.json").exists(), "hundred_ambiguous_answer_dispatch")
    require(e.strict_json(e.read_file(intent)) == expected_intent, "hundred_dispatch_intent_changed")
    saved = capture_case(output, declaration, ordinal)
    if (output / f"question-{ordinal}-process-result.json").exists():
        process = e.strict_json(e.read_file(output / f"question-{ordinal}-process-result.json"))
        require(process.get("returncode") == 0 or saved["status"] == "case_failure", "hundred_native_process_failed")
    write(result, saved)
    return saved


def recover_decision(output, intent):
    directory, name = output / intent["connector_directory"], intent["name"]
    operation = e.strict_json(e.read_file(directory / (name + "-operation.json")))
    request_raw, response_raw = e.read_file(directory / (name + "-request.json")), e.read_file(directory / (name + "-response.json"))
    request, response = e.strict_json(request_raw), e.strict_json(response_raw)
    require(operation.get("dispatched") is True and operation.get("received") is True and "failure" not in operation
        and operation.get("request_sha256") == e.digest(request_raw) and operation.get("response_sha256") == e.digest(response_raw)
        and request.get("jsonrpc") == response.get("jsonrpc") == "2.0" and type(request.get("id")) is int
        and request["id"] == response.get("id") and "error" not in response
        and request.get("method") == "tools/call" and request.get("params", {}).get("name") == "jevk5_decide"
        and e.digest(jev.canonical(request["params"].get("arguments"))) == intent["arguments_sha256"],
        "hundred_judge_receipt_invalid")
    return jev.validate_decision(response["result"])


@contextmanager
def execution_lock(output):
    fd = os.open(output / "execution.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise e.EvaluationError("hundred_execution_already_running") from None
        yield
    finally:
        os.close(fd)


def execute(output, client_factory=jev.StdioMCP, run=subprocess.run, progress=True):
    output = Path(output).resolve()
    declaration_raw = e.read_file(output / "declaration.json")
    declaration = e.strict_json(declaration_raw)
    verify(output, declaration)
    with execution_lock(output):
        return _execute_locked(output, declaration, e.digest(declaration_raw), client_factory, run, progress)


def _execute_locked(output, declaration, declaration_sha, client_factory, run, progress):
    rows, controls, halt, client, connector_directory = empty_rows(declaration), [], None, None, None

    def checkpoint():
        report = {"version": VERSION, "declaration_sha256": declaration_sha, "declared_attempts": 100,
            "attempts": rows, "controls": controls, "decision_calls": len(list(output.glob("decision-*-intent.json"))),
            "halt": halt, "summary": summary(rows), "remote_calls": 0,
            "limitations": ["one proportional category-stratified local sample; no paired comparison",
                "prior question identities excluded; overlapping history and benchmark training contamination unverified",
                "JevK5 acceptance is reference-based grading; semantic calibration and source support accuracy unverified"]}
        atomic_write(output / "report.json", report)
        if progress:
            print(json.dumps({"completed": report["summary"]["completed"], "scored": report["summary"]["scored"],
                "accepted": report["summary"]["accepted"], "case_failures": report["summary"]["case_failures"],
                "declared": 100, "decision_calls": report["decision_calls"], "halt": halt}), flush=True)
        return report

    def connection():
        nonlocal client, connector_directory
        if client is None:
            index = 0
            while (output / f"connector-session-{index:04d}").exists():
                index += 1
            connector_directory = f"connector-session-{index:04d}"
            (output / connector_directory).mkdir(mode=0o700)
            client = client_factory(output / connector_directory)
            client.connect()
        return client

    def decide(arguments, name):
        intent_path, result_path = output / ("decision-" + name + "-intent.json"), output / ("decision-" + name + "-result.json")
        expected = {"name": name, "arguments_sha256": e.digest(jev.canonical(arguments)), "declaration_sha256": declaration_sha}
        if result_path.exists():
            intent = e.strict_json(e.read_file(intent_path))
            require(all(intent.get(key) == value for key, value in expected.items()), "hundred_judge_intent_changed")
            result = e.strict_json(e.read_file(result_path))
            require(result == recover_decision(output, intent), "hundred_saved_judgment_changed")
            return result
        if intent_path.exists():
            intent = e.strict_json(e.read_file(intent_path))
            require(all(intent.get(key) == value for key, value in expected.items()), "hundred_judge_intent_changed")
            try:
                result = recover_decision(output, intent)
            except Exception:
                raise e.EvaluationError("hundred_ambiguous_judge_dispatch") from None
        else:
            require(len(list(output.glob("decision-*-intent.json"))) < 106, "hundred_judge_limit")
            verify(output, declaration)
            active = connection()
            write(intent_path, {**expected, "connector_directory": connector_directory, "dispatch_may_have_started": True})
            result = active.decide(arguments, name)
            require(result == recover_decision(output, e.strict_json(e.read_file(intent_path))), "hundred_judge_capture_invalid")
        write(result_path, result)
        return result

    try:
        control_inputs = e.strict_json(e.read_file(output / "controls.json"))
        require(len(control_inputs) == 6, "hundred_controls_inventory_invalid")
        for control in control_inputs:
            decision = decide(control["arguments"], "control-" + control["name"])
            controls.append({"name": control["name"], "expected": control["expected"], "decision": decision,
                "passed": decision["choice"] == control["expected"]})
            checkpoint()
        require(all(control["passed"] for control in controls), "hundred_public_controls_failed")
        for ordinal in range(100):
            # Pin changes refuse dispatch; all rows retain their original denominator.
            verify(output, declaration)
            rows[ordinal]["status"] = "dispatch_unknown"
            checkpoint()
            rows[ordinal].update(answer_case(output, declaration, ordinal, run))
            checkpoint()
            if rows[ordinal]["operational_complete"]:
                history = e.strict_json(e.read_file(output / f"scorer-{ordinal}.json"))
                probe = history["episodes"][0]
                answer = e.read_file(output / f"native-{ordinal}/answer-0000.txt").decode()
                require(e.digest(answer.encode()) == rows[ordinal]["answer_sha256"], "hundred_answer_changed")
                prompt = judging.official_qa_messages(probe["question_type"], probe["prompt"], probe["answer"], answer,
                    probe["abstention"], output / "qa-protocol.py")[0]["content"]
                rows[ordinal]["judgment"] = decide(jev.qa_request(prompt), f"answer-{ordinal:04d}")
                checkpoint()
    except Exception as error:
        halt = code(error, "hundred_execution_failed")
    finally:
        if client is not None:
            client.close()
        report = checkpoint()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("select", "prepare", "execute", "verify"))
    parser.add_argument("--output", required=True, type=Path)
    for name in ("source", "selection", "binary", "verification", "protocol"):
        parser.add_argument("--" + name, type=Path)
    args = parser.parse_args()
    if args.action == "select":
        require(args.source is not None, "hundred_source_argument_missing")
        manifest = select(args.source, args.output)
        print(json.dumps({"prepared_selection": True, "declared_questions": 100,
            "category_counts": manifest["category_quotas"], "manifest_sha256": e.digest(jev.canonical(manifest))}), flush=True)
    elif args.action == "prepare":
        require(all(getattr(args, name) is not None for name in ("selection", "binary", "verification", "protocol")),
            "hundred_prepare_arguments_missing")
        declaration = prepare(args.selection, args.binary, args.verification, args.protocol, args.output)
        print(json.dumps({"prepared": True, "version": VERSION, "declared_attempts": 100,
            "declaration_sha256": e.digest(jev.canonical(declaration))}), flush=True)
    elif args.action == "verify":
        verify(args.output, e.strict_json(e.read_file(args.output / "declaration.json")))
        print(json.dumps({"verified": True, "declared_attempts": 100}), flush=True)
    else:
        report = execute(args.output)
        print(json.dumps({"version": VERSION, "halt": report["halt"], "summary": report["summary"],
            "decision_calls": report["decision_calls"], "remote_calls": 0}), flush=True)
        raise SystemExit(1 if report["halt"] else 0)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except Exception:
        print(json.dumps({"failed": True, "code": "hundred_preparation_or_dispatch_refused"}), flush=True)
        raise SystemExit(1)
