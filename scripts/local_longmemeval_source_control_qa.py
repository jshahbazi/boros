#!/usr/bin/env python3
"""Separate, pinned six-row QA diagnostic for declared-original-source controls.

No judge calls occur on import. Private judge inputs stay outside public reports.
Source delivery and pinned native proof consistency do not establish semantic
sufficiency or independently replay the native journal's body/count proof.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
from pathlib import Path
import sys

import evaluate_answers as evidence
import evaluate_longmemeval as baseline
import evaluate_longmemeval_source_controls as controls_runner
import longmemeval_source_controls as controls
import local_longmemeval_qa as qa

VERSION = "local-complete-source-qa-v1"
DEPENDENCIES = ("local_longmemeval_source_control_qa.py", "local_longmemeval_qa.py",
    "longmemeval_source_controls.py", "evaluate_longmemeval_source_controls.py",
    "longmemeval_cases.py", "evaluate_longmemeval.py", "evaluate_answers.py",
    "evaluation_fixtures.py", "import_chat.py")
HISTORICAL_DEPENDENCIES = DEPENDENCIES[1:]


def require(condition, code):
    if not condition:
        raise qa.GradeError(code)


def field(value, key):
    """Read a known field from the content-free native metadata projection."""
    return value[key] if key in value else value["field_sha256_" + qa.digest(key.encode())]


def matches(value, expected):
    return value == expected or value == {"sha256": qa.digest(expected.encode()), "bytes": len(expected.encode())}


def hash_inventory(value):
    require(isinstance(value, dict) and bool(value), "source_inventory_invalid")
    for key, digest in value.items():
        path = Path(key) if isinstance(key, str) else None
        require(path is not None and not path.is_absolute() and ".." not in path.parts
            and path.parts[0] in ("Sources", "scripts", "Tests")
            and isinstance(digest, str) and qa.SHA.fullmatch(digest), "source_inventory_invalid")
    return value


@dataclass(frozen=True)
class Bundle:
    attempts: tuple
    pins: dict
    immutable_files: tuple
    implementation_continuity: bool
    identity_sha256: str


def bundle_identity(attempts, pins, continuity):
    return qa.digest(qa.canonical({"attempts": attempts, "pins": pins, "implementation_continuity": continuity}))


def _source_histories(raw, pins):
    require(len(raw) == pins.byte_count and qa.digest(raw) == pins.sha256, "source_pin_mismatch")
    require(pins.case_ids == qa.CASE_IDS and pins.case_types == qa.CASE_TYPES, "source_selection_invalid")
    rows = qa.strict_json(raw)
    require(isinstance(rows, list) and len(rows) == pins.record_count, "source_inventory_mismatch")
    # The original seven-case selection is preserved; the absent case is excluded
    # only from this separately declared six-case control contract.
    for category in pins.case_types[:6]:
        selected = sorted(row["question_id"] for row in rows if row["question_type"] == category
                          and not row["question_id"].endswith("_abs"))
        require(selected and selected[0] == pins.case_ids[pins.case_types.index(category)], "source_selection_invalid")
    absent = sorted(row["question_id"] for row in rows if row["question_id"].endswith("_abs"))
    require(absent and absent[0] == pins.case_ids[-1], "source_selection_invalid")
    return controls.cases.prepare_rows(rows, pins.sha256)[:6]


def _delivery_consistency(row, history, document):
    outcome = row["source_control_validation"]
    item = row.get("metadata")
    require(item is None or isinstance(item, dict), "native_metadata_invalid")
    item = {} if item is None else item
    if not item:
        require(outcome == controls_runner.unavailable_control(history, document["attempts"][0])
                and row["operational_complete"] is False, "unavailable_control_claim_invalid")
        return
    request = document["attempts"][0]
    require(type(item.get("terminalized")) is bool, "native_operational_shape_invalid")
    for key in ("capture_healthy", "accounting_healthy", "invocation_started"):
        require(key not in item or type(item[key]) is bool, "native_operational_shape_invalid")
    require(item.get("probe_id") == history["id"] and item.get("strategy") == "hybrid"
            and type(item.get("ordinal")) is int and item["ordinal"] == 0
            and type(item.get("replicate")) is int and item["replicate"] == 0,
            "native_attempt_linkage_invalid")
    ranges = [{key: field(span, key) for key in ("event_id", "offset", "byte_length", "sha256")}
              for span in item.get("delivered_ranges", [])]
    copied = dict(item, delivered_ranges=ranges)
    require(controls_runner.validate_control_outcome(copied, history, request) == outcome,
            "native_outcome_projection_invalid")
    operational = (item.get("terminalized") is True and item.get("episode_state") == "completed"
        and item.get("invocation_status") == "complete"
        and all(item.get(key) is True for key in ("capture_healthy", "accounting_healthy", "invocation_started"))
        and item.get("failure") is None)
    require(row["operational_complete"] is operational, "operational_outcome_invalid")
    if not item["terminalized"]:
        require(outcome["source_body_count_revalidated"] is None, "nonterminal_proof_invalid")
        return
    require(matches(item.get("answer_file"), "answer-0000.txt")
        and item.get("answer_bytes") == row["answer_bytes"]
        and item.get("answer_sha256") == row["answer_sha256"], "native_answer_linkage_invalid")
    preparation = item.get("preparation")
    if preparation is None:
        require(not operational and not ranges and not item.get("delivered_recent_source_ids"), "missing_provenance")
        return
    audit = preparation["context_audit"]
    recent = item["delivered_recent_source_ids"]
    baseline.validated_intervals(history, request, ranges, recent)
    require(row.get("delivery") == baseline.delivery_diagnostic(history, request, ranges, recent), "delivery_diagnostic_invalid")
    inventory = controls.source_inventory(history, request["evidence_source_ids"])
    retrieval = audit["retrieval"]
    require(matches(retrieval["mode"], "declared_original_sources")
        and matches(retrieval["version"], controls_runner.OUTCOME_VERSION)
        and type(retrieval["declared_source_count"]) is int and retrieval["declared_source_count"] == len(inventory)
        and type(retrieval["declared_source_bytes"]) is int
        and retrieval["declared_source_bytes"] == sum(v["byte_length"] for v in inventory)
        and retrieval["declared_source_ids_sha256"] == qa.digest(qa.canonical(request["evidence_source_ids"]))
        and retrieval["semantic_available"] is False, "source_control_binding_invalid")
    historical = audit["historical_sources"]
    require(all(v["event_id"] in request["evidence_source_ids"] for v in historical), "undeclared_historical_source")
    expected = [{"event_id": v["event_id"], "offset": v["excerpt_offset"],
                 "byte_length": v["excerpt_bytes"], "sha256": v["excerpt_sha256"]} for v in historical]
    require(ranges[:len(expected)] == expected and [v["event_id"] for v in ranges[len(expected):]] == recent
        and audit["recent_source_count"] == len(recent)
        and audit["ordered_recent_source_ids_sha256"] == qa.digest(qa.canonical(recent)), "source_audit_linkage_invalid")
    admission = field(preparation, "admission_audit")
    receipt = preparation["admission"]
    proof = receipt["componentProof"]
    encoded_context = field(admission, "context")
    proof_work_id = field(admission, "inputProofWorkID")
    proof_sha256 = field(admission, "inputProofSHA256")
    require(isinstance(encoded_context, dict) and set(encoded_context) == {"bytes", "sha256"}
        and type(encoded_context["bytes"]) is int and 0 < encoded_context["bytes"] <= qa.MAX_SMALL
        and encoded_context["bytes"] % 4 == 0 and isinstance(encoded_context["sha256"], str)
        and qa.SHA.fullmatch(encoded_context["sha256"]), "opaque_native_context_digest_invalid")
    require(field(admission, "receipt") == receipt and admission["version"] == 3
        and type(admission["version"]) is int
        and isinstance(proof_work_id, str) and evidence.UUID.fullmatch(proof_work_id)
        and isinstance(proof_sha256, str) and qa.SHA.fullmatch(proof_sha256)
        and receipt["bodyDigest"] == proof["bodyDigest"] == preparation["request_sha256"]
        and proof["sourceSnapshotDigest"] == audit["source_snapshot_sha256"] == preparation["selection_sha256"]
        and isinstance(preparation["request_sha256"], str) and qa.SHA.fullmatch(preparation["request_sha256"])
        and isinstance(preparation["selection_sha256"], str) and qa.SHA.fullmatch(preparation["selection_sha256"])
        and audit["selection_work_id"].lower() == preparation["selection_work_id"].lower()
        and proof == audit["components"]
        and proof["episodeID"].lower() == receipt["episodeID"].lower() == item["identifiers"]["episodeID"].lower()
        and matches(proof["projectID"], "answer-evaluation-public:" + request["project_id"])
        and matches(receipt["endpoint"], baseline.chat_endpoint(controls_runner.CONFIGURATION["endpoint"]))
        and proof["endpoint"] == receipt["endpoint"]
        and receipt["outputReserve"] == proof["outputReserve"] == controls_runner.CONFIGURATION["maximum_output"],
        "native_body_count_receipt_linkage_invalid")


def validate_bundle(report_path, report_sha256, hypotheses_directory, source_path, binary_verification,
                    pins=qa.SourcePins()):
    """Bind historical answer artifacts without comparing all current sources."""
    try:
        report_raw = qa.read_file(report_path)
        require(isinstance(report_sha256, str) and qa.SHA.fullmatch(report_sha256)
                and qa.digest(report_raw) == report_sha256, "answer_report_pin_mismatch")
        report = qa.strict_json(report_raw)
        require(report["source_control_evaluation_version"] == 1 and type(report["source_control_evaluation_version"]) is int
            and report["runner_document_version"] == 6 and type(report["runner_document_version"]) is int
            and report["control_version"] == controls.CONTROL_VERSION and report["split"] == "development"
            and report["registration_status"] == "unregistered_reused_development_source_control"
            and report["ordinary_recall_arm"] is False and type(report["implementation_continuity"]) is bool,
            "answer_report_contract_invalid")
        declaration = report["declaration"]
        declaration_raw = qa.read_file(Path(hypotheses_directory) / "declaration.json")
        require(qa.digest(qa.canonical(declaration) + b"\n") == report["declaration_sha256"]
            == qa.digest(declaration_raw) and qa.strict_json(declaration_raw) == declaration, "declaration_pin_mismatch")
        source_raw = qa.read_file(source_path, pins.byte_count)
        histories = _source_histories(source_raw, pins)
        configuration = controls_runner.CONFIGURATION
        documents = [controls.runner_input(history, configuration) for history in histories]
        annotations = [controls.declaration_case(history, doc) for history, doc in zip(histories, documents)]
        require(tuple(h["id"] for h in histories) == controls.CASE_IDS
            and all(a["public_projection_sha256"] == controls.PROJECTION_PINS[a["question_id"]]
                and a["source_inventory_sha256"] == controls.PACK_INVENTORY_PINS[a["question_id"]] for a in annotations),
            "source_projection_pack_pin_mismatch")
        expected = {"version": 1, "control_version": controls.CONTROL_VERSION, "split": "development",
            "declared_attempts": 6, "runner_document_version": 6, "strategy": "hybrid", "replicates": 1,
            "case_ids": list(controls.CASE_IDS), "cases": annotations, "source_revision": pins.revision,
            "source_sha256": pins.sha256, "source_bytes": pins.byte_count,
            "configuration_sha256": qa.digest(qa.canonical(configuration)),
            "native_configuration_sha256": baseline.native_configuration_sha256(configuration),
            "system_sha256": qa.digest(configuration["system"].encode()), "ordinary_recall_arm": False,
            "selection_uses_positive_annotations": True, "semantic_sufficiency": None, "provider_token_feasibility": None,
            "official_qa_status": "not_run_source_control_judge", "official_qa_score": None,
            "source_hashes": hash_inventory(declaration["source_hashes"])}
        require(qa.canonical(declaration) == qa.canonical(expected)
            and report["configuration"] == {k: v for k, v in configuration.items() if k != "system"}, "declaration_contract_invalid")
        implementation = report["implementation"]
        historical = expected["source_hashes"]
        proof_raw = qa.read_file(binary_verification)
        proof = qa.strict_json(proof_raw)
        proof_sources = hash_inventory(proof["source_hashes"])
        require(implementation["source_sha256"] == historical and proof["terminal_passed"] is True
            and isinstance(implementation["binary_sha256"], str) and qa.SHA.fullmatch(implementation["binary_sha256"])
            and proof["app_binary_sha256"] == implementation["binary_sha256"]
            and qa.digest(proof_raw) == implementation["binary_verification_sha256"]
            and implementation["source_binary_linkage"] == "terminal_build_record_matches_all_native_sources"
            and implementation["python_dependencies_captured_before_compile"] is True
            and {k: v for k, v in historical.items() if k.startswith("Sources/")} ==
                {k: v for k, v in proof_sources.items() if k.startswith("Sources/")}
            and all(proof_sources.get(k) == v for k, v in historical.items()), "historical_build_proof_invalid")
        # These loaded adapters reconstruct the frozen historical projections.
        # New grader files are deliberately absent from the historical inventory.
        directory = Path(__file__).resolve().parent
        require(all(historical.get("scripts/" + name) == qa.digest(qa.read_file(directory / name))
                    for name in HISTORICAL_DEPENDENCIES), "historical_validator_dependency_mismatch")
        export_path = Path(hypotheses_directory) / "source_control.jsonl"
        export_raw = qa.read_file(export_path)
        exports = report["private_hypothesis_exports"]
        require(exports == {"source_control": {"records": 6, "bytes": len(export_raw), "sha256": qa.digest(export_raw)}},
                "hypothesis_export_pin_mismatch")
        predictions = [qa.strict_json(line) for line in export_raw.splitlines()]
        require(len(predictions) == 6 and all(isinstance(v, dict) and set(v) == {"question_id", "hypothesis"}
            and type(v["hypothesis"]) is str for v in predictions)
            and [v["question_id"] for v in predictions] == list(controls.CASE_IDS), "hypothesis_inventory_invalid")
        require(isinstance(report["histories"], list) and len(report["histories"]) == 6, "answer_inventory_invalid")
        attempts = []
        for history, doc, annotation, measured, prediction in zip(histories, documents, annotations, report["histories"], predictions):
            require(measured["case"] == annotation and isinstance(measured["attempts"], list)
                and len(measured["attempts"]) == 1, "answer_case_linkage_invalid")
            row = measured["attempts"][0]
            require(row["question_id"] == history["id"] and row["question_type"] == history["episodes"][0]["question_type"]
                and row["abstention"] is False and row["strategy"] == "hybrid"
                and type(row["ordinal"]) is int and row["ordinal"] == 0
                and type(row["replicate"]) is int and row["replicate"] == 0
                and type(row["operational_complete"]) is bool and type(row["full_pack_delivery_eligible"]) is bool
                and row["semantic_sufficiency"] is None and row["provider_token_feasibility"] is None
                and row["official_qa_score"] is None, "answer_attempt_contract_invalid")
            driver = measured["driver"]
            if row.get("metadata"):
                require(driver["input_sha256"] == annotation["runner_input_sha256"]
                    and driver["public_projection_sha256"] == annotation["public_projection_sha256"]
                    and driver["native_configuration_sha256"] == declaration["native_configuration_sha256"]
                    and matches(driver["history_id"], history["id"]) and driver["split"] == "development"
                    and type(driver["declared_attempts"]) is int and driver["declared_attempts"] == 1
                    and type(driver["completed_attempts"]) is int
                    and driver["completed_attempts"] == int(row["metadata"].get("terminalized") is True),
                    "native_projection_pin_mismatch")
            _delivery_consistency(row, history, doc)
            outcome = row["source_control_validation"]
            require(row["full_pack_delivery_eligible"] is (outcome["complete_declared_sources_delivered"] is True),
                    "delivery_eligibility_invalid")
            hypothesis = prediction["hypothesis"]
            if row["operational_complete"]:
                require(type(row["answer_bytes"]) is int and row["answer_bytes"] == len(hypothesis.encode())
                    and row["answer_sha256"] == qa.digest(hypothesis.encode()) and row["failure_code"] is None,
                    "completed_answer_export_invalid")
            else:
                require(hypothesis == "" and row["failure_code"] is not None, "failed_answer_export_must_be_empty")
            eligible = (row["operational_complete"] and row["full_pack_delivery_eligible"]
                and outcome["complete_declared_sources_delivered"] is True
                and outcome["source_body_count_revalidated"] is True and outcome["input_proof_version"] == 3
                and outcome["delivered_source_count"] == outcome["declared_source_count"]
                and outcome["failure_code"] is None)
            probe = history["episodes"][0]
            attempts.append({"category": probe["question_type"], "task": probe["question_type"], "abstention": False,
                "question": probe["prompt"], "reference": probe["answer"], "hypothesis": hypothesis,
                "case_sha256": qa.digest(history["id"].encode()), "native_operational_complete": row["operational_complete"],
                "full_pack_delivery_eligible": row["full_pack_delivery_eligible"], "judge_eligible": eligible})
        require(report["summary"] == controls_runner.summarize([h["attempts"][0] for h in report["histories"]]),
                "answer_summary_invalid")
        immutable = ((Path(report_path), qa.digest(report_raw)),
            (Path(hypotheses_directory) / "declaration.json", qa.digest(declaration_raw)),
            (Path(source_path), qa.digest(source_raw)), (Path(binary_verification), qa.digest(proof_raw)),
            (export_path, qa.digest(export_raw)))
        input_pins = {"answer_report_sha256": report_sha256,
            "answer_declaration_sha256": report["declaration_sha256"], "source_sha256": pins.sha256,
            "binary_sha256": implementation["binary_sha256"], "binary_verification_sha256": qa.digest(proof_raw),
            "historical_source_inventory_sha256": qa.digest(qa.canonical(historical)),
            "hypothesis_export_sha256": qa.digest(export_raw), "projection_sha256": [a["public_projection_sha256"] for a in annotations],
            "source_inventory_sha256": [a["source_inventory_sha256"] for a in annotations],
            "oracle_projection_sha256": [a["scorer_annotations_sha256"] for a in annotations]}
        return Bundle(tuple(attempts), input_pins, immutable, report["implementation_continuity"],
                      bundle_identity(attempts, input_pins, report["implementation_continuity"]))
    except qa.GradeError:
        raise
    except (evidence.EvaluationError, KeyError, TypeError, ValueError, AttributeError, IndexError):
        raise qa.GradeError("source_control_bundle_invalid") from None


def fingerprints(settings, protocol_raw):
    directory = Path(__file__).resolve().parent
    return {"adapter_version": VERSION, "dependencies_sha256": {
        "scripts/" + name: qa.digest(qa.read_file(directory / name)) for name in DEPENDENCIES},
        "shared_grader": qa.fingerprints(settings, protocol_raw)}


IMPORTED_DEPENDENCY_HASHES = fingerprints(qa.local_settings(qa.ANSWER_CONFIGURATION["endpoint"]), b"")["dependencies_sha256"]


def aggregate(rows):
    result = {}
    for category in ["all", *sorted({row["category"] for row in rows})]:
        selected = rows if category == "all" else [row for row in rows if row["category"] == category]
        scored = [row for row in selected if row["scored"]]
        accepted = sum(row["upstream_yes_substring_label"] is True for row in scored)
        result[category] = {"declared_attempts": len(selected), "eligible_attempts": sum(row["judge_eligible"] for row in selected),
            "scored_attempts": len(scored), "unscored_attempts": len(selected) - len(scored),
            **{status + "_attempts": sum(row["terminal_status"] == status for row in selected)
               for status in ("operational_failed", "delivery_ineligible", "implementation_unverified", "judge_unknown")},
            "accepted_count": accepted, "accepted_fraction_declared": accepted / len(selected) if selected else None,
            "accepted_fraction_scored": accepted / len(scored) if scored else None,
            "usage_observed_attempts": sum(row["usage"] is not None for row in selected),
            "usage_unknown_attempts": sum(row["usage"] is None for row in selected),
            "observed_prompt_tokens": sum(row["usage"]["prompt_tokens"] for row in selected if row["usage"]),
            "observed_completion_tokens": sum(row["usage"]["completion_tokens"] for row in selected if row["usage"])}
    return result


def immutable_inputs_match(files):
    return all(qa.digest(qa.read_file(path, max(qa.MAX_SMALL, qa.SOURCE_BYTES))) == digest for path, digest in files)


def run(bundle, protocol_path, controls_report, controls_sha256, output_directory, private_directory,
        *, endpoint=qa.ANSWER_CONFIGURATION["endpoint"], timeout=30, transport=qa.call_local):
    require(isinstance(bundle, Bundle) and len(bundle.attempts) == 6 and private_directory is not None,
            "six_control_bundle_required")
    require(bundle_identity(bundle.attempts, bundle.pins, bundle.implementation_continuity) == bundle.identity_sha256,
            "validated_bundle_changed")
    require(type(timeout) in (int, float) and math.isfinite(timeout) and 0 < timeout <= 60, "invalid_timeout")
    settings = qa.local_settings(endpoint)
    require(immutable_inputs_match(bundle.immutable_files), "answer_inputs_changed_before_declaration")
    prompt_function, protocol_raw = qa.load_prompt_function(protocol_path, expected_sha=qa.PROTOCOL_SHA256)
    fp = fingerprints(settings, protocol_raw)
    require(fp["dependencies_sha256"] == IMPORTED_DEPENDENCY_HASHES, "loaded_grader_dependencies_changed")
    controls_pin = qa.validate_controls(controls_report, controls_sha256, fp["shared_grader"])
    attempts = tuple(qa.strict_json(qa.canonical(a)) for a in bundle.attempts)
    require(type(bundle.implementation_continuity) is bool
        and tuple(a["category"] for a in attempts) == qa.CASE_TYPES[:6]
        and all(type(a["native_operational_complete"]) is bool and type(a["judge_eligible"]) is bool
                and type(a["full_pack_delivery_eligible"]) is bool for a in attempts), "six_control_attempt_shape_invalid")
    requests = tuple(qa.make_request(prompt_function, a["task"], a["question"], a["reference"], a["hypothesis"],
                    False, settings) for a in attempts)
    statuses = tuple("implementation_unverified" if not bundle.implementation_continuity else
        "operational_failed" if not a["native_operational_complete"] else
        "delivery_ineligible" if not a["judge_eligible"] else "eligible" for a in attempts)
    declaration = {"local_source_control_qa_declaration_version": 1, "contract_version": VERSION,
        "mode": "source_control_qa", "declared_attempts": 6, "fingerprints": fp,
        "input_pins": qa.strict_json(qa.canonical(bundle.pins)),
        "implementation_continuity": bundle.implementation_continuity, "controls_report_sha256": controls_pin,
        "request_sha256": [qa.digest(raw) for raw in requests], "pre_execution_status": list(statuses),
        "case_sha256": [a["case_sha256"] for a in attempts], "semantic_sufficiency": None,
        "real_judge_calibration_status": "unrun", "official_qa_score": None}
    output_path, private_path = Path(output_directory), Path(private_directory)
    output_identity, private_identity = output_path.resolve(), private_path.resolve()
    require(output_path.is_absolute() and private_path.is_absolute()
        and output_identity != private_identity and output_identity not in private_identity.parents
        and private_identity not in output_identity.parents,
        "separate_fresh_absolute_destinations_required")
    input_paths = [path for path, _digest in bundle.immutable_files] + [Path(protocol_path), Path(controls_report)]
    require(all(not input_path.resolve().is_relative_to(destination.resolve())
        for input_path in input_paths for destination in (output_path, private_path)), "input_output_path_collision")
    output = qa.new_directory(output_path)
    private = qa.new_directory(private_path)
    declaration_raw = qa.canonical(declaration) + b"\n"
    declaration_sha256 = qa.digest(declaration_raw)
    qa.private_write(output / "declaration.json", declaration_raw)
    qa.private_write(private / "requests.jsonl", b"".join(raw + b"\n" for raw in requests))
    rows = []
    for index, (attempt, raw_request, status) in enumerate(zip(attempts, requests, statuses)):
        row = {"ordinal": index, "category": attempt["category"], "case_sha256": attempt["case_sha256"],
            "request_sha256": qa.digest(raw_request), "judge_eligible": status == "eligible",
            "terminal_status": status, "scored": False, "upstream_yes_substring_label": None,
            "strict_yes_no_format_valid": False, "usage": None, "usage_status": "unknown",
            "raw_response_sha256": None, "judge_terminal_status": None}
        if status == "eligible":
            try:
                require(fingerprints(settings, protocol_raw) == fp, "grader_changed_after_declaration")
                require(qa.digest(qa.read_file(protocol_path)) == qa.digest(protocol_raw)
                    and qa.digest(qa.read_file(controls_report)) == controls_pin, "grading_input_changed")
                require(immutable_inputs_match(bundle.immutable_files), "answer_inputs_changed")
                require(qa.make_request(prompt_function, attempt["task"], attempt["question"], attempt["reference"],
                    attempt["hypothesis"], False, settings) == raw_request, "frozen_request_changed")
                response = transport(dict(settings), raw_request, timeout=timeout)
                require(isinstance(response, bytes), "transport_response_invalid")
                qa.private_write(private / f"judgment-{index:04d}.json", response)
                judgment = qa.parse_judgment(response)
                row.update(judgment)
                row["judge_terminal_status"] = judgment["terminal_status"]
                row["terminal_status"] = "completed" if judgment["scored"] else "judge_unknown"
            except Exception:
                row["terminal_status"] = "judge_unknown"
                row["judge_terminal_status"] = "transport_or_capture_or_frozen_input_failed"
        rows.append(row)
    report = {"local_source_control_qa_version": 1, "contract_version": VERSION, "mode": "source_control_qa",
        "fingerprints": fp, "declaration_sha256": declaration_sha256,
        "attempts": rows, "summary": aggregate(rows), "synthetic_controls_validated": True,
        "real_judge_calibration_status": "unrun", "performance_trust": "unvalidated_real_judge",
        "ordinary_recall_arm": False, "semantic_sufficiency": None, "official_qa_score": None,
        "private_capture_sha256": qa.digest(qa.canonical([row["raw_response_sha256"] for row in rows])),
        "limitations": ["six reused answerable development controls; absence excluded; fixed denominator six",
            "full declared source delivery does not establish semantic sufficiency or answer correctness",
            "body/count metadata consistency relies on pinned native offline revalidation; journal not replayed here",
            "local answerer and judge share Qwen; real judge calibration and official scoring remain unrun",
            "judge resources are outside Boros answering episode charges"]}
    qa.private_write(output / "report.json", qa.canonical(report) + b"\n")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description="Separate six-control private local QA diagnostic.")
    for name in ("source", "answer-report", "answer-report-sha256", "hypotheses-directory", "binary-verification",
                 "protocol", "controls-report", "controls-report-sha256", "output-directory", "private-directory"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--endpoint", default=qa.ANSWER_CONFIGURATION["endpoint"])
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    try:
        require(args.execute, "explicit_execution_required")
        bundle = validate_bundle(args.answer_report, args.answer_report_sha256, args.hypotheses_directory,
                                 args.source, args.binary_verification)
        report = run(bundle, args.protocol, args.controls_report, args.controls_report_sha256,
                     args.output_directory, args.private_directory, endpoint=args.endpoint, timeout=args.timeout)
        print(qa.canonical({"declared_attempts": 6, "scored_attempts": report["summary"]["all"]["scored_attempts"],
                            "official_qa_score": None}).decode())
        return 0
    except (qa.GradeError, OSError, ValueError, TypeError, KeyError):
        print("Source-control local QA failed validation.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
