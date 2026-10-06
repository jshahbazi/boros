#!/usr/bin/env python3
"""Separate private QA for the frozen fourteen-case independent recall cohort.

Ordinary recall delivery is diagnostic only. Metadata consistency relies on the
pinned native journal validation; this adapter cannot replay an opaque context
digest. No model calls occur on import and no source-bearing text is published.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
from pathlib import Path
import sys

import evaluate_answers as evidence
import evaluate_longmemeval as baseline
import longmemeval_independent_cases as independent
import local_longmemeval_qa as qa

VERSION = "local-independent-recall-qa-v1"
DEPENDENCIES = ("local_longmemeval_independent_qa.py", "local_longmemeval_qa.py",
    "longmemeval_independent_cases.py", "longmemeval_cases.py", "evaluate_longmemeval.py",
    "evaluate_answers.py", "evaluation_fixtures.py", "import_chat.py")


def require(condition, code):
    if not condition:
        raise qa.GradeError(code)


class FrozenDict(dict):
    """JSON-compatible deeply frozen data; identity also detects bypassed writes."""
    def _deny(self, *_args, **_kwargs):
        raise TypeError("validated_data_immutable")
    __setitem__ = __delitem__ = clear = pop = popitem = setdefault = update = __ior__ = _deny


def freeze(value):
    if isinstance(value, dict):
        return FrozenDict({key: freeze(item) for key, item in value.items()})
    if isinstance(value, (list, tuple)):
        return tuple(freeze(item) for item in value)
    return value


def field(value, key):
    return value[key] if key in value else value["field_sha256_" + qa.digest(key.encode())]


def matches(value, expected):
    return value == expected or value == {"sha256": qa.digest(expected.encode()), "bytes": len(expected.encode())}


def hash_inventory(value):
    require(isinstance(value, dict) and bool(value), "source_inventory_invalid")
    for key, digest in value.items():
        path = Path(key) if isinstance(key, str) else None
        require(path is not None and not path.is_absolute() and ".." not in path.parts
            and path.parts and path.parts[0] in ("Sources", "scripts", "Tests")
            and isinstance(digest, str) and qa.SHA.fullmatch(digest), "source_inventory_invalid")
    require(any(key.startswith("Sources/") for key in value), "native_source_inventory_missing")
    return value


@dataclass(frozen=True)
class Bundle:
    attempts: tuple
    pins: dict
    immutable_files: tuple
    implementation_continuity: bool
    identity_sha256: str


def bundle_identity(attempts, pins, continuity, immutable_files=()):
    return qa.digest(qa.canonical({"attempts": attempts, "pins": pins,
        "implementation_continuity": continuity,
        "immutable_files": [[str(path), digest] for path, digest in immutable_files]}))


def _bundle_matches(bundle):
    return bundle_identity(bundle.attempts, bundle.pins, bundle.implementation_continuity,
        bundle.immutable_files) == bundle.identity_sha256


def _annotation(history, document):
    probe = baseline.validate_history(history)
    return {"question_id": probe["question_id"], "question_type": probe["question_type"],
        "abstention": probe["abstention"], "source_count": len(history["events"]),
        "source_bytes": sum(len(event["text"].encode()) for event in history["events"]),
        "runner_input_sha256": qa.digest(qa.canonical(document)),
        "public_projection_sha256": independent.projection_sha256(document),
        "scorer_annotations_sha256": baseline.oracle_sha256(history)}


def _unknown_delivery(history, request):
    return baseline._empty_attempt(history, request, 0, "native_attempt_unavailable")["delivery"]


def _metadata_consistency(row, history, request, ordinal):
    """Validate sanitized original-range and v3 source/body/count receipt links."""
    item = row.get("metadata")
    require(item is None or isinstance(item, dict), "native_metadata_invalid")
    if not item:
        require(row["operational_complete"] is False and row["delivery"] == _unknown_delivery(history, request),
            "unavailable_native_claim_invalid")
        return
    require(type(item.get("terminalized")) is bool
        and type(item.get("ordinal")) is int and item["ordinal"] == ordinal
        and type(item.get("replicate")) is int and item["replicate"] == 0
        and item.get("probe_id") == history["id"] and item.get("strategy") == request["strategy"],
        "native_attempt_linkage_invalid")
    for key in ("capture_healthy", "accounting_healthy", "invocation_started"):
        require(key not in item or type(item[key]) is bool, "native_operational_shape_invalid")
    operational = (item["terminalized"] and item.get("episode_state") == "completed"
        and item.get("invocation_status") == "complete"
        and all(item.get(key) is True for key in ("capture_healthy", "accounting_healthy", "invocation_started"))
        and item.get("failure") is None)
    require(row["operational_complete"] is operational, "operational_outcome_invalid")
    if not item["terminalized"]:
        require(row["delivery"] == _unknown_delivery(history, request), "nonterminal_delivery_claim_invalid")
    if item["terminalized"]:
        require(matches(item.get("answer_file"), f"answer-{ordinal:04d}.txt")
            and type(item.get("answer_bytes")) is int and item["answer_bytes"] >= 0
            and item["answer_bytes"] == row["answer_bytes"] and item.get("answer_sha256") == row["answer_sha256"]
            and isinstance(item["answer_sha256"], str) and qa.SHA.fullmatch(item["answer_sha256"]),
            "native_answer_linkage_invalid")
    require(isinstance(item.get("delivered_ranges", []), list)
        and isinstance(item.get("delivered_recent_source_ids", []), list), "native_delivery_inventory_invalid")
    ranges = [{key: field(span, key) for key in ("event_id", "offset", "byte_length", "sha256")}
        for span in item.get("delivered_ranges", [])]
    recent = item.get("delivered_recent_source_ids", [])
    diagnostic = baseline.delivery_diagnostic(history, request, ranges, recent)
    if item["terminalized"]:
        require(row["delivery"] == diagnostic, "delivery_diagnostic_invalid")
    preparation = item.get("preparation")
    if preparation is None:
        require(not operational and item.get("invocation_started") is not True
            and item.get("invocation_status") not in ("complete", "partial") and not ranges and not recent,
            "missing_native_provenance")
        return
    require(isinstance(preparation, dict) and isinstance(item.get("identifiers"), dict), "native_provenance_invalid")
    identifiers = item["identifiers"]
    for key in ("episodeID", "invocationID", "humanEventID", "assistantEventID", "turnID"):
        require(isinstance(identifiers.get(key), str) and evidence.UUID.fullmatch(identifiers[key]),
            "native_invocation_identifiers_invalid")
    for key in ("selection_work_id", "answer_work_id"):
        require(isinstance(preparation.get(key), str) and evidence.UUID.fullmatch(preparation[key]),
            "native_work_linkage_invalid")
    for key in ("request_sha256", "selection_sha256"):
        require(isinstance(preparation.get(key), str) and qa.SHA.fullmatch(preparation[key]), "native_digest_invalid")
    admission = field(preparation, "admission_audit")
    receipt, audit = preparation["admission"], preparation["context_audit"]
    require(all(isinstance(value, dict) for value in (admission, receipt, audit)), "native_admission_metadata_invalid")
    proof = receipt["componentProof"]
    context = field(admission, "context")
    require(isinstance(context, dict) and set(context) == {"bytes", "sha256"}
        and type(context["bytes"]) is int and 0 < context["bytes"] <= qa.MAX_SMALL
        and context["bytes"] % 4 == 0 and isinstance(context["sha256"], str) and qa.SHA.fullmatch(context["sha256"]),
        "opaque_native_context_digest_invalid")
    require(type(admission.get("version")) is int and admission["version"] == 3
        and field(admission, "receipt") == receipt
        and isinstance(field(admission, "inputProofWorkID"), str)
        and evidence.UUID.fullmatch(field(admission, "inputProofWorkID"))
        and isinstance(field(admission, "inputProofSHA256"), str)
        and qa.SHA.fullmatch(field(admission, "inputProofSHA256"))
        and receipt["bodyDigest"] == proof["bodyDigest"] == preparation["request_sha256"]
        and proof["sourceSnapshotDigest"] == audit["source_snapshot_sha256"] == preparation["selection_sha256"]
        and baseline._same_uuid(audit["selection_work_id"], preparation["selection_work_id"])
        and baseline._same_uuid(receipt["episodeID"], identifiers["episodeID"])
        and baseline._same_uuid(proof["episodeID"], identifiers["episodeID"])
        and matches(proof["projectID"], "answer-evaluation-public:" + request["project_id"])
        and matches(receipt["endpoint"], baseline.chat_endpoint(independent.CONFIGURATION["endpoint"]))
        and proof["endpoint"] == receipt["endpoint"]
        and type(receipt["outputReserve"]) is int and type(proof["outputReserve"]) is int
        and receipt["outputReserve"] == proof["outputReserve"] == 1024
        and proof == audit["components"], "native_body_count_receipt_linkage_invalid")
    require(type(audit.get("recent_source_count")) is int and audit["recent_source_count"] == len(recent)
        and audit.get("ordered_recent_source_ids_sha256") == qa.digest(qa.canonical(recent))
        and isinstance(audit.get("historical_sources"), list), "native_source_audit_invalid")
    expected = [{"event_id": span["event_id"], "offset": span["excerpt_offset"],
        "byte_length": span["excerpt_bytes"], "sha256": span["excerpt_sha256"]} for span in audit["historical_sources"]]
    require(ranges[:len(expected)] == expected and [span["event_id"] for span in ranges[len(expected):]] == recent,
        "native_source_audit_linkage_invalid")


def validate_bundle(report_path, report_sha256, hypotheses_directory, source_path, binary_verification):
    """Reconstruct the exact cohort and bind historical native evidence privately."""
    try:
        report_raw = qa.read_file(report_path)
        require(isinstance(report_sha256, str) and qa.SHA.fullmatch(report_sha256)
            and qa.digest(report_raw) == report_sha256, "answer_report_pin_mismatch")
        report = qa.strict_json(report_raw)
        require(type(report["longmemeval_evaluation_version"]) is int and report["longmemeval_evaluation_version"] == 2
            and type(report["runner_document_version"]) is int and report["runner_document_version"] == 7
            and report["cohort"] == independent.COHORT and report["split"] == "development"
            and report["registration_status"] == "predeclared_independent_development_subset"
            and type(report["replicates"]) is int and report["replicates"] == 1
            and report["strategy_order"] == list(qa.STRATEGIES)
            and report["official_qa_score"] is None and report["official_qa_status"] == "pending_official_judge",
            "answer_report_contract_invalid")
        declaration = report["declaration"]
        declaration_path = Path(hypotheses_directory) / "declaration.json"
        declaration_raw = qa.read_file(declaration_path)
        require(qa.digest(qa.canonical(declaration) + b"\n") == report["declaration_sha256"]
            == qa.digest(declaration_raw) and qa.strict_json(declaration_raw) == declaration, "declaration_pin_mismatch")
        source_raw = qa.read_file(source_path, independent.SOURCE_BYTES)
        require(len(source_raw) == independent.SOURCE_BYTES and qa.digest(source_raw) == independent.SOURCE_SHA256,
            "independent_source_pin_mismatch")
        histories, manifest = independent.prepare_with_manifest(source_path)
        require(len(histories) == 14 and tuple(history["id"] for history in histories) == independent.CASE_IDS
            and tuple(baseline.validate_history(history)["question_type"] for history in histories) == independent.CASE_TYPES,
            "independent_case_inventory_invalid")
        documents = [independent.runner_input(history, independent.CONFIGURATION) for history in histories]
        annotations = [_annotation(history, document) for history, document in zip(histories, documents)]
        require(all(annotation["public_projection_sha256"] == independent.PROJECTION_PINS[annotation["question_id"]]
            for annotation in annotations), "independent_projection_pin_mismatch")
        historical = hash_inventory(declaration["source_hashes"])
        expected = {"version": 2, "split": "development", "declared_attempts": 28,
            "runner_document_version": 7, "case_ids": list(independent.CASE_IDS), "cases": annotations,
            "source_revision": independent.SOURCE_REVISION, "source_sha256": independent.SOURCE_SHA256,
            "configuration_sha256": qa.digest(qa.canonical(independent.CONFIGURATION)),
            "native_configuration_sha256": baseline.native_configuration_sha256(independent.CONFIGURATION),
            "system_sha256": qa.digest(independent.CONFIGURATION["system"].encode()), "source_hashes": historical,
            "protocol_commit": baseline.PROTOCOL_COMMIT, "protocol_hashes": baseline.PROTOCOL_HASHES,
            "official_qa_score": None, "official_qa_status": "pending_official_judge",
            "cohort": independent.COHORT, "selection_manifest": manifest}
        require(qa.canonical(declaration) == qa.canonical(expected) and report["selection_manifest"] == manifest
            and report["configuration"] == {k: v for k, v in independent.CONFIGURATION.items() if k != "system"},
            "independent_declaration_contract_invalid")
        require(report["source"] == {"repository": "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned",
            "revision": independent.SOURCE_REVISION, "path": independent.SOURCE_NAME,
            "sha256": independent.SOURCE_SHA256, "bytes": independent.SOURCE_BYTES}, "answer_source_pin_mismatch")
        proof_raw = qa.read_file(binary_verification)
        proof = qa.strict_json(proof_raw)
        implementation = report["implementation"]
        proof_sources = hash_inventory(proof["source_hashes"])
        require(implementation["source_sha256"] == historical and proof["terminal_passed"] is True
            and isinstance(implementation["binary_sha256"], str) and qa.SHA.fullmatch(implementation["binary_sha256"])
            and proof["app_binary_sha256"] == implementation["binary_sha256"]
            and qa.digest(proof_raw) == implementation["binary_verification_sha256"]
            and implementation["source_binary_linkage"] == "terminal_build_record_matches_all_native_sources"
            and implementation["python_dependencies_captured_before_compile"] is True
            and {k: v for k, v in historical.items() if k.startswith("Sources/")} ==
                {k: v for k, v in proof_sources.items() if k.startswith("Sources/")}
            and all(proof_sources.get(k) == v for k, v in historical.items()), "historical_native_build_proof_invalid")
        continuity = report["implementation_continuity"]
        require(type(continuity) is bool, "implementation_continuity_invalid")
        immutable = [(Path(report_path), qa.digest(report_raw)), (declaration_path, qa.digest(declaration_raw)),
            (Path(source_path), qa.digest(source_raw)), (Path(binary_verification), qa.digest(proof_raw))]
        require(set(report["private_hypothesis_exports"]) == set(qa.STRATEGIES), "hypothesis_export_inventory_invalid")
        predictions, export_hashes = {}, {}
        for strategy in qa.STRATEGIES:
            path = Path(hypotheses_directory) / (strategy + ".jsonl")
            raw = qa.read_file(path)
            require(report["private_hypothesis_exports"][strategy] == {"records": 14, "bytes": len(raw), "sha256": qa.digest(raw)},
                "hypothesis_export_pin_mismatch")
            exported = [qa.strict_json(line) for line in raw.splitlines()]
            require(len(exported) == 14 and all(isinstance(value, dict) and set(value) == {"question_id", "hypothesis"}
                and type(value["hypothesis"]) is str for value in exported)
                and [value["question_id"] for value in exported] == list(independent.CASE_IDS), "hypothesis_inventory_invalid")
            predictions[strategy] = exported
            export_hashes[strategy] = qa.digest(raw)
            immutable.append((path, qa.digest(raw)))
        require(isinstance(report["histories"], list) and len(report["histories"]) == 14, "answer_inventory_invalid")
        attempts = []
        for index, (history, document, annotation, measured) in enumerate(zip(histories, documents, annotations, report["histories"])):
            require(measured["case"] == annotation and isinstance(measured["attempts"], list)
                and len(measured["attempts"]) == 2, "answer_case_linkage_invalid")
            driver = measured["driver"]
            if any(row.get("metadata") for row in measured["attempts"]):
                require(type(driver["version"]) is int and driver["version"] == 1
                    and driver["input_sha256"] == annotation["runner_input_sha256"]
                    and driver["public_projection_sha256"] == annotation["public_projection_sha256"]
                    and driver["native_configuration_sha256"] == declaration["native_configuration_sha256"]
                    and matches(driver["history_id"], history["id"]) and driver["split"] == "development"
                    and type(driver["declared_attempts"]) is int and driver["declared_attempts"] == 2
                    and type(driver["completed_attempts"]) is int and driver["completed_attempts"] == sum(
                        row.get("metadata", {}).get("terminalized") is True for row in measured["attempts"] if row.get("metadata")),
                    "native_projection_linkage_invalid")
            probe = history["episodes"][0]
            for ordinal, (request, row) in enumerate(zip(document["attempts"], measured["attempts"])):
                require(row["question_id"] == history["id"] and row["question_type"] == probe["question_type"]
                    and row["abstention"] is probe["abstention"] and row["strategy"] == qa.STRATEGIES[ordinal]
                    and type(row["ordinal"]) is int and row["ordinal"] == ordinal
                    and type(row["replicate"]) is int and row["replicate"] == 0
                    and type(row["operational_complete"]) is bool and row["official_qa_score"] is None
                    and row["official_qa_status"] == "pending_official_judge", "answer_attempt_contract_invalid")
                _metadata_consistency(row, history, request, ordinal)
                hypothesis = predictions[request["strategy"]][index]["hypothesis"]
                if row["operational_complete"]:
                    require(type(row["answer_bytes"]) is int and row["answer_bytes"] == len(hypothesis.encode())
                        and row["answer_sha256"] == qa.digest(hypothesis.encode()) and row["failure_code"] is None,
                        "completed_answer_export_invalid")
                else:
                    require(hypothesis == "" and row["failure_code"] is not None, "failed_answer_export_must_be_empty")
                attempts.append({"category": "abstention" if probe["abstention"] else probe["question_type"],
                    "task": probe["question_type"], "abstention": probe["abstention"], "strategy": request["strategy"],
                    "question_id": history["id"], "question": probe["prompt"], "reference": probe["answer"],
                    "hypothesis": hypothesis, "case_sha256": qa.digest(history["id"].encode()),
                    "native_operational_complete": row["operational_complete"], "judge_eligible": row["operational_complete"]})
        require(report["summary"] == baseline.summarize([row for measured in report["histories"] for row in measured["attempts"]]),
            "answer_summary_invalid")
        pins = {"answer_report_sha256": report_sha256, "answer_declaration_sha256": report["declaration_sha256"],
            "source_sha256": independent.SOURCE_SHA256, "binary_sha256": implementation["binary_sha256"],
            "binary_verification_sha256": qa.digest(proof_raw), "historical_source_inventory_sha256": qa.digest(qa.canonical(historical)),
            "selection_manifest_sha256": qa.digest(qa.canonical(manifest)), "hypothesis_export_sha256": export_hashes,
            "projection_sha256": [value["public_projection_sha256"] for value in annotations],
            "oracle_projection_sha256": [value["scorer_annotations_sha256"] for value in annotations]}
        attempts, pins, immutable = freeze(attempts), freeze(pins), tuple((path.resolve(), digest) for path, digest in immutable)
        return Bundle(attempts, pins, immutable, continuity, bundle_identity(attempts, pins, continuity, immutable))
    except qa.GradeError:
        raise
    except (evidence.EvaluationError, KeyError, TypeError, ValueError, AttributeError, IndexError, UnicodeError):
        raise qa.GradeError("independent_bundle_invalid") from None


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
                for status in ("completed", "operational_failed", "implementation_unverified", "judge_unknown")},
            "accepted_count": accepted, "accepted_fraction_declared": accepted / len(selected) if selected else None,
            "accepted_fraction_scored": accepted / len(scored) if scored else None,
            "usage_observed_attempts": sum(row["usage"] is not None for row in selected),
            "usage_unknown_attempts": sum(row["usage"] is None for row in selected),
            "observed_prompt_tokens": sum(row["usage"]["prompt_tokens"] for row in selected if row["usage"]),
            "observed_completion_tokens": sum(row["usage"]["completion_tokens"] for row in selected if row["usage"])}
    return result


def immutable_inputs_match(files):
    return all(qa.digest(qa.read_file(path, max(qa.MAX_SMALL, independent.SOURCE_BYTES))) == digest for path, digest in files)


def run(bundle, protocol_path, controls_report, controls_sha256, output_directory, private_directory,
        *, endpoint=qa.ANSWER_CONFIGURATION["endpoint"], timeout=30, transport=qa.call_local):
    require(isinstance(bundle, Bundle) and len(bundle.attempts) == 28 and private_directory is not None,
        "independent_bundle_required")
    require(_bundle_matches(bundle), "validated_bundle_changed")
    require(type(timeout) in (int, float) and math.isfinite(timeout) and 0 < timeout <= 60, "invalid_timeout")
    settings = qa.local_settings(endpoint)
    require(immutable_inputs_match(bundle.immutable_files), "answer_inputs_changed_before_declaration")
    prompt_function, protocol_raw = qa.load_prompt_function(protocol_path, expected_sha=qa.PROTOCOL_SHA256)
    fp = fingerprints(settings, protocol_raw)
    require(fp["dependencies_sha256"] == IMPORTED_DEPENDENCY_HASHES, "loaded_grader_dependencies_changed")
    controls_pin = qa.validate_controls(controls_report, controls_sha256, fp["shared_grader"])
    attempts = tuple(qa.strict_json(qa.canonical(attempt)) for attempt in bundle.attempts)
    require(type(bundle.implementation_continuity) is bool
        and tuple(attempt["question_id"] for attempt in attempts) == tuple(case for case in independent.CASE_IDS for _ in qa.STRATEGIES)
        and tuple(attempt["strategy"] for attempt in attempts) == qa.STRATEGIES * 14
        and all(type(attempt["native_operational_complete"]) is bool and type(attempt["judge_eligible"]) is bool
            and attempt["judge_eligible"] is attempt["native_operational_complete"] for attempt in attempts), "independent_attempt_shape_invalid")
    requests = tuple(qa.make_request(prompt_function, attempt["task"], attempt["question"], attempt["reference"],
        attempt["hypothesis"], attempt["abstention"], settings) for attempt in attempts)
    statuses = tuple("implementation_unverified" if not bundle.implementation_continuity else
        "operational_failed" if not attempt["native_operational_complete"] else "eligible" for attempt in attempts)
    declaration = {"local_independent_qa_declaration_version": 1, "contract_version": VERSION,
        "mode": "independent_qa", "cohort": independent.COHORT, "runner_document_version": 7,
        "declared_attempts": 28, "fingerprints": fp, "input_pins": bundle.pins,
        "implementation_continuity": bundle.implementation_continuity, "controls_report_sha256": controls_pin,
        "request_sha256": [qa.digest(raw) for raw in requests], "pre_execution_status": list(statuses),
        "case_sha256": [attempt["case_sha256"] for attempt in attempts], "ordinary_recall_arm": True,
        "real_judge_calibration_status": "unrun", "official_qa_score": None}
    output_path, private_path = Path(output_directory), Path(private_directory)
    output_identity, private_identity = output_path.resolve(), private_path.resolve()
    require(output_path.is_absolute() and private_path.is_absolute() and output_identity != private_identity
        and output_identity not in private_identity.parents and private_identity not in output_identity.parents,
        "separate_fresh_absolute_destinations_required")
    input_paths = [path for path, _digest in bundle.immutable_files] + [Path(protocol_path), Path(controls_report)]
    require(all(not path.resolve().is_relative_to(destination) for path in input_paths
        for destination in (output_identity, private_identity)), "input_output_path_collision")
    output, private = qa.new_directory(output_path), qa.new_directory(private_path)
    declaration_raw = qa.canonical(declaration) + b"\n"
    qa.private_write(output / "declaration.json", declaration_raw)
    qa.private_write(private / "requests.jsonl", b"".join(raw + b"\n" for raw in requests))
    rows = []
    def frozen_call_inputs_match(attempt, raw_request):
        require(_bundle_matches(bundle), "validated_bundle_changed")
        require(fingerprints(settings, protocol_raw) == fp, "grader_changed_after_declaration")
        require(qa.digest(qa.read_file(protocol_path)) == qa.digest(protocol_raw)
            and qa.digest(qa.read_file(controls_report)) == controls_pin, "grading_input_changed")
        require(immutable_inputs_match(bundle.immutable_files), "answer_inputs_changed")
        require(qa.make_request(prompt_function, attempt["task"], attempt["question"], attempt["reference"],
            attempt["hypothesis"], attempt["abstention"], settings) == raw_request, "frozen_request_changed")

    for index, (attempt, raw_request, status) in enumerate(zip(attempts, requests, statuses)):
        row = {"ordinal": index, "question_id": attempt["question_id"], "strategy": attempt["strategy"],
            "category": attempt["category"], "case_sha256": attempt["case_sha256"], "request_sha256": qa.digest(raw_request),
            "judge_eligible": status == "eligible", "terminal_status": status, "scored": False,
            "upstream_yes_substring_label": None, "strict_yes_no_format_valid": False, "usage": None,
            "usage_status": "unknown", "raw_response_sha256": None, "judge_terminal_status": None}
        if status == "eligible":
            try:
                frozen_call_inputs_match(attempt, raw_request)
                response = transport(dict(settings), raw_request, timeout=timeout)
                require(isinstance(response, bytes), "transport_response_invalid")
                # Preserve received-byte identity and available usage even when
                # capture or the post-response continuity check denies credit.
                judgment = qa.parse_judgment(response)
                row.update({key: judgment[key] for key in ("raw_response_sha256", "usage", "usage_status")})
                qa.private_write(private / f"judgment-{index:04d}.json", response)
                frozen_call_inputs_match(attempt, raw_request)
                row.update(judgment)
                row["judge_terminal_status"] = judgment["terminal_status"]
                row["terminal_status"] = "completed" if judgment["scored"] else "judge_unknown"
            except Exception:
                row["scored"] = False
                row["upstream_yes_substring_label"] = None
                row["terminal_status"] = "judge_unknown"
                row["judge_terminal_status"] = "transport_or_capture_or_frozen_input_failed"
        rows.append(row)
    report = {"local_independent_qa_version": 1, "contract_version": VERSION, "mode": "independent_qa",
        "cohort": independent.COHORT, "fingerprints": fp, "declaration_sha256": qa.digest(declaration_raw),
        "attempts": rows, "summary": aggregate(rows), "strategy_summary": {
            strategy: aggregate([row for row in rows if row["strategy"] == strategy]) for strategy in qa.STRATEGIES},
        "synthetic_controls_validated": True, "real_judge_calibration_status": "unrun",
        "performance_trust": "same_answerer_self_judge_uncalibrated", "ordinary_recall_arm": True,
        "official_qa_score": None, "private_capture_sha256": qa.digest(qa.canonical([row["raw_response_sha256"] for row in rows])),
        "limitations": ["fourteen fixed independent development cases; denominator twenty-eight; one replicate",
            "delivery diagnostics do not gate ordinary recall judging or establish semantic sufficiency",
            "opaque native context digest and source/body/count integrity rely on pinned native validation; no journal replay here",
            "local answerer and judge share Qwen; real-answer calibration and official scoring remain unrun",
            "judge resources are outside Boros answering episode charges"]}
    qa.private_write(output / "report.json", qa.canonical(report) + b"\n")
    return report


class SafeParser(argparse.ArgumentParser):
    def error(self, _message):
        raise qa.GradeError("invalid_cli_arguments")


def main(argv=None):
    parser = SafeParser(description="Private local QA for the frozen independent recall cohort.")
    for name in ("source", "answer-report", "answer-report-sha256", "hypotheses-directory", "binary-verification",
            "protocol", "controls-report", "controls-report-sha256", "output-directory", "private-directory"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--endpoint", default=qa.ANSWER_CONFIGURATION["endpoint"])
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--execute", action="store_true")
    try:
        args = parser.parse_args(argv)
        require(args.execute, "explicit_execution_required")
        bundle = validate_bundle(args.answer_report, args.answer_report_sha256, args.hypotheses_directory,
            args.source, args.binary_verification)
        report = run(bundle, args.protocol, args.controls_report, args.controls_report_sha256,
            args.output_directory, args.private_directory, endpoint=args.endpoint, timeout=args.timeout)
        print(qa.canonical({"declared_attempts": 28, "scored_attempts": report["summary"]["all"]["scored_attempts"],
            "official_qa_score": None}).decode())
        return 0
    except (qa.GradeError, OSError, ValueError, TypeError, KeyError):
        print("Independent local QA failed validation.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
