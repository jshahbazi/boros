#!/usr/bin/env python3
"""Fixed local native-investigation pilot; private captures, no retries."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

import evaluate_answers as e
import evaluate_longmemeval as evaluation
import jevk5_saved_qa as jev
import longmemeval_independent_cases as cases
import orientation_zoom_judging as judging

ROOT = Path(__file__).resolve().parents[1]
VERSION = "native-memory-investigation-trial-v1"
CASE_IDS = ("1b9b7252", "4baee567", "gpt4_70e84552")
ARMS = ("recent_only", "native_investigation")


def require(condition, code):
    if not condition:
        raise e.EvaluationError(code)


def write(path, value):
    e.private_write(path, jev.canonical(value))


def selection(histories):
    selected = sorted(histories, key=lambda history: cases.rank_sha256(history["id"]))[:3]
    require(tuple(h["id"] for h in selected) == CASE_IDS, "trial_selection_changed")
    return selected


def empty_rows():
    return [{"ordinal": case * 2 + arm, "case_ordinal": case, "arm": name,
             "status": "not_run", "operational_complete": False, "judgment": None}
            for case in range(3) for arm, name in enumerate(ARMS)]


def summary(rows):
    require(len(rows) == 6 and [r["ordinal"] for r in rows] == list(range(6)), "trial_denominator_invalid")
    return {arm: {"declared": 3, "completed": sum(r["operational_complete"] for r in rows if r["arm"] == arm),
                  "scored": sum(r["judgment"] is not None for r in rows if r["arm"] == arm),
                  "accepted": sum(r["judgment"] is not None and r["judgment"]["choice"] == "yes"
                                  for r in rows if r["arm"] == arm),
                  "not_run": sum(r["status"] == "not_run" for r in rows if r["arm"] == arm)} for arm in ARMS}


def prepare(source, binary, verification, protocol, output):
    output = Path(output).absolute()
    require(output.is_relative_to(ROOT / ".build") and not output.exists()
            and not any(p.is_symlink() for p in (output, *output.parents)), "trial_destination_invalid")
    selected = selection(cases.prepare(source))
    binary = Path(binary).resolve()
    record_raw = e.read_file(Path(verification))
    record = e.strict_json(record_raw)
    inventory = evaluation.code_inventory()
    binary_sha = e.digest(e.read_file(binary, 256 * 1024 * 1024))
    require(record.get("terminal_passed") is True and record.get("app_binary_sha256") == binary_sha
            and all(record.get("source_hashes", {}).get(k) == v for k, v in inventory.items() if k.startswith("Sources/")),
            "trial_binary_unverified")
    protocol_raw = e.read_file(Path(protocol))
    require(e.digest(protocol_raw) == jev.PROTOCOL_SHA256, "trial_protocol_changed")
    output.mkdir(mode=0o700, parents=True)
    artifacts = {}

    def freeze(relative, raw):
        path = output / relative
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        e.private_write(path, raw)
        artifacts[relative] = e.digest(raw)

    freeze("qa-protocol.py", protocol_raw)
    freeze("build-verification.json", record_raw)
    freeze("controls.json", jev.canonical(jev.controls(judging, output / "qa-protocol.py")))
    case_metadata = []
    for ordinal, history in enumerate(selected):
        document = cases.runner_input(history, cases.CONFIGURATION)
        require(cases.projection_sha256(document) == cases.PROJECTION_PINS[history["id"]], "trial_projection_changed")
        freeze(f"input-{ordinal}.json", jev.canonical(document))
        freeze(f"scorer-{ordinal}.json", jev.canonical(history))
        case_metadata.append({"ordinal": ordinal, **cases.case_annotation(history)})
    for relative, sha in inventory.items():
        raw = e.read_file(ROOT / relative)
        require(e.digest(raw) == sha, "trial_source_changed")
        freeze("source-capture/" + relative, raw)
    declaration = {"version": VERSION, "selection_rule": "first_three_existing_answer_blind_rank_of_frozen_14",
                   "development_only": True, "cases": case_metadata, "declared_attempts": 6, "arms": list(ARMS),
                   "native_flag": "--investigate-memory", "source_sha256": cases.SOURCE_SHA256,
                   "binary": str(binary), "binary_sha256": binary_sha, "source_hashes": inventory,
                   "artifacts": artifacts, "judge_model": jev.MODEL, "connector_command": list(jev.COMMAND),
                   "connector_executable_sha256": e.digest(e.read_file(Path(jev.COMMAND[0]), 1024 * 1024 * 1024)),
                   "maximum_answer_attempts": 6, "maximum_judge_decisions": 12, "pair_process_timeout_seconds": 660,
                   "retry_count": 0, "stop_on_first_operational_failure": True, "remote_calls": 0}
    write(output / "declaration.json", declaration)
    return declaration


def verify(output, declaration):
    require(declaration["version"] == VERSION and declaration["declared_attempts"] == 6
            and tuple(c["question_id"] for c in declaration["cases"]) == CASE_IDS
            and declaration["maximum_judge_decisions"] == 12 and declaration["remote_calls"] == 0
            and declaration["maximum_answer_attempts"] == 6 and declaration["pair_process_timeout_seconds"] == 660
            and declaration["retry_count"] == 0 and declaration["stop_on_first_operational_failure"] is True
            and declaration["arms"] == list(ARMS) and declaration["native_flag"] == "--investigate-memory"
            and declaration["judge_model"] == jev.MODEL and declaration["connector_command"] == list(jev.COMMAND),
            "trial_contract_changed")
    require(evaluation.code_inventory() == declaration["source_hashes"], "trial_live_source_changed")
    require(e.digest(e.read_file(Path(declaration["binary"]), 256 * 1024 * 1024)) == declaration["binary_sha256"],
            "trial_binary_changed")
    require(e.digest(e.read_file(Path(jev.COMMAND[0]), 1024 * 1024 * 1024)) == declaration["connector_executable_sha256"],
            "trial_connector_changed")
    for relative, expected in declaration["artifacts"].items():
        require(e.digest(e.read_file(output / relative, 32 * 1024 * 1024)) == expected, "trial_artifact_changed")


def assert_investigation(native, scored):
    require(native.get("mode") == VERSION and native.get("preparation_mode") == "native-investigation-paired-v1",
            "trial_native_mode_missing")
    for ordinal, item in enumerate(native.get("attempts", [])):
        require(item.get("memory_investigation") is (ordinal == 1), "trial_arm_mode_invalid")
        if ordinal == 1 and scored[1]["operational_complete"]:
            audit = item.get("preparation", {}).get("context_audit", {}).get("retrieval", {}).get("native_investigation", {})
            require(audit.get("version") == "native-investigation-v1" and audit.get("private_stages", 0) >= 2
                    and audit.get("derived_notes_in_final_request") is False, "trial_native_preparation_missing")


def answer_case(output, declaration, ordinal, run):
    verify(output, declaration)
    document = e.strict_json(e.read_file(output / f"input-{ordinal}.json"))
    history = e.strict_json(e.read_file(output / f"scorer-{ordinal}.json"))
    directory = output / f"native-{ordinal}"
    try:
        process = run([declaration["binary"], "--answer-evaluation", str(output / f"input-{ordinal}.json"),
                       "--output-directory", str(directory), "--investigate-memory"], capture_output=True,
                      timeout=declaration["pair_process_timeout_seconds"],
                      env={**os.environ, "BOROS_DATA_DIR": str(output / "unused-app-runtime")})
    except subprocess.TimeoutExpired as error:
        e.private_write(output / f"native-{ordinal}-stdout", error.stdout or b"")
        e.private_write(output / f"native-{ordinal}-stderr", error.stderr or b"")
        raise e.EvaluationError("trial_native_process_timeout") from None
    e.private_write(output / f"native-{ordinal}-stdout", process.stdout)
    e.private_write(output / f"native-{ordinal}-stderr", process.stderr)
    native = e.strict_json(e.read_file(directory / "report.json"))
    scored, _predictions = evaluation.score_native(native, directory, history, document,
        configuration=cases.CONFIGURATION, runner_document_version=7)
    assert_investigation(native, scored)
    write(output / f"native-{ordinal}-validated.json", scored)
    return native, scored, process.returncode


def status(score, native_item):
    if score["operational_complete"]:
        return "completed"
    if score.get("failure_code") == "native_attempt_unavailable" or (native_item.get("terminalized") is False
            and native_item.get("failure") == "trial_stopped_after_operational_failure"):
        return "not_run"
    return "incomplete"


def execute(output, client_factory=jev.StdioMCP, run=subprocess.run):
    output = Path(output).resolve()
    declaration_raw = e.read_file(output / "declaration.json")
    declaration = e.strict_json(declaration_raw)
    verify(output, declaration)
    # Exclusive durable intent is a one-shot dispatch fence, including after a crash.
    write(output / "execution-intent.json", {"declaration_sha256": e.digest(declaration_raw), "authorized": True})
    rows, control_results, halt, client = empty_rows(), [], None, None
    decisions = 0
    connector = output / "connector"
    connector.mkdir(mode=0o700)
    try:
        client = client_factory(connector)
        client.connect()
        controls = e.strict_json(e.read_file(output / "controls.json"))
        require(len(controls) == 6, "trial_control_inventory_invalid")
        for control in controls:
            decisions += 1
            decision = client.decide(control["arguments"], "control-" + control["name"])
            control_results.append({"name": control["name"], "expected": control["expected"], "decision": decision,
                                    "passed": decision["choice"] == control["expected"]})
        write(output / "controls-result.json", control_results)
        require(all(c["passed"] for c in control_results), "trial_public_controls_failed")
        for ordinal in range(3):
            rows[ordinal * 2]["status"] = "dispatched"
            rows[ordinal * 2 + 1]["status"] = "dispatch_unknown"
            try:
                native, scored, process_code = answer_case(output, declaration, ordinal, run)
            except Exception as error:
                halt = str(error) if isinstance(error, e.EvaluationError) else "trial_native_capture_invalid"
                break
            for arm, score in enumerate(scored):
                row = rows[ordinal * 2 + arm]
                raw_item = native.get("attempts", [])[arm] if arm < len(native.get("attempts", [])) else {}
                row.update(status=status(score, raw_item),
                           operational_complete=score["operational_complete"], answer_sha256=score["answer_sha256"],
                           answer_bytes=score["answer_bytes"], delivery=score["delivery"], metadata=score["metadata"])
            if process_code or not all(r["operational_complete"] for r in scored):
                halt = "trial_native_process_failed" if process_code else "trial_native_attempt_incomplete"
                break
        # Score completed answers even when a later attempt failed; the denominator stays six.
        for row in rows:
            if not row["operational_complete"]:
                continue
            verify(output, declaration)
            ordinal, arm = row["case_ordinal"], row["ordinal"] % 2
            history = e.strict_json(e.read_file(output / f"scorer-{ordinal}.json"))
            probe = history["episodes"][0]
            answer = e.read_file(output / f"native-{ordinal}/answer-{arm:04d}.txt").decode("utf-8")
            require(e.digest(answer.encode()) == row["answer_sha256"], "trial_answer_changed")
            prompt = judging.official_qa_messages(probe["question_type"], probe["prompt"], probe["answer"], answer,
                probe["abstention"], output / "qa-protocol.py")[0]["content"]
            require(decisions < 12, "trial_judge_limit")
            decisions += 1
            row["judgment"] = client.decide(jev.qa_request(prompt), f"answer-{row['ordinal']}")
    except Exception as error:
        # Persist fixed failure labels, never a source-bearing exception message.
        halt = str(error) if isinstance(error, (e.EvaluationError, jev.SavedQAError)) else "trial_execution_failed"
    finally:
        if client is not None:
            client.close()
        report = {"version": VERSION, "declaration_sha256": e.digest(declaration_raw), "declared_attempts": 6,
                  "attempts": rows, "controls": control_results, "decision_calls": decisions,
                  "halt": halt, "summary": summary(rows), "remote_calls": 0,
                  "limitations": ["three reused development histories in two categories; one replicate",
                                  "recent-context control; no matched ordinary-hybrid control",
                                  "native preparation has a larger allowance; no causal isolation of orientation",
                                  "JevK5 QA acceptance is not source support or calibrated semantic accuracy"]}
        write(output / "report.json", report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "execute"))
    parser.add_argument("--output", required=True, type=Path)
    for name in ("source", "binary", "verification", "protocol"):
        parser.add_argument("--" + name, type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        require(all(getattr(args, key) is not None for key in ("source", "binary", "verification", "protocol")),
                "trial_prepare_arguments_missing")
        result = prepare(args.source, args.binary, args.verification, args.protocol, args.output)
        print(json.dumps({"prepared": True, "version": result["version"], "declared_attempts": 6}))
    else:
        require(all(getattr(args, key) is None for key in ("source", "binary", "verification", "protocol")),
                "trial_execute_arguments_invalid")
        result = execute(args.output)
        print(json.dumps({"version": result["version"], "halt": result["halt"], "summary": result["summary"],
                          "decision_calls": result["decision_calls"], "remote_calls": 0}))


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except Exception:
        print(json.dumps({"failed": True, "code": "trial_preparation_or_dispatch_refused"}))
        raise SystemExit(1)
