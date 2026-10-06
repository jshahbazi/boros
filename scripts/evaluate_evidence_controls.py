#!/usr/bin/env python3
"""Separate pinned complete-exchange reproduction/citation feasibility control."""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile
import time

import devgpt_evidence_controls as controls
import devgpt_answer_cases as cases
import evaluate_answers as e
import evaluate_developer_answers as developer
from evaluation_fixtures import canonical_json


def full_pack_coverage(pack, ranges, recent_ids):
    # Validate complete original messages independently of the smaller gold
    # answer ranges. Disjoint ranges must cover every UTF-8 byte of both roles.
    probe = {"goldSpans": [{"eventID": event["id"], "offset": 0,
              "byteLength": len(event["text"].encode()), "sha256": e.digest(event["text"].encode())}
             for event in pack["events"]]}
    return e.delivered_coverage(pack, probe, ranges, recent_ids)


def witness_eligibility(native, item, pack, document, operational):
    metadata = controls.metadata(pack)
    _configuration_pin, native_configuration_pin, _amendment = controls.configuration_pins(document["configuration"])
    if not isinstance(item, dict) or not operational:
        return {"eligible": False, "failure_code": "witness_outcome_unavailable",
                "complete_pack_delivered": None, "covered_source_count": 0}
    coverage = full_pack_coverage(pack, item.get("delivered_ranges", []),
                                  item.get("delivered_recent_source_ids", []))
    complete = coverage["all_required_spans_delivered"] is True
    witness = item.get("witness_validation", {})
    evidence_valid = (isinstance(witness, dict)
        and native.get("witness_mode") == controls.VERSION and item.get("witness_mode") == controls.VERSION
        and native.get("input_sha256") == e.digest(canonical_json(document))
        and native.get("public_projection_sha256") == metadata["projection_sha256"]
        and native.get("native_configuration_sha256") == native_configuration_pin
        and witness.get("version") == controls.VALIDATION_VERSION
        and type(witness.get("declared_source_count")) is int
        and witness["declared_source_count"] == metadata["source_count"]
        and type(witness.get("declared_source_bytes")) is int
        and witness["declared_source_bytes"] == metadata["source_bytes"]
        and type(witness.get("delivered_source_count")) is int
        and witness["delivered_source_count"] == coverage["covered_span_count"]
        and witness.get("complete_pack_delivered") is True
        and witness.get("source_body_count_revalidated") is True
        and type(witness.get("input_proof_version")) is int and witness["input_proof_version"] == 3
        and witness.get("failure_code") is None)
    eligible = operational and complete and evidence_valid
    reason = (None if eligible else "invocation_incomplete" if not operational else
              "witness_pack_not_delivered" if not complete else "witness_source_body_count_invalid")
    return {"eligible": eligible, "failure_code": reason, "complete_pack_delivered": complete,
            "covered_source_count": coverage["covered_span_count"]}


def score_native(native, directory, pack, document):
    controls.validate_pack(pack)
    if native.get("input_sha256") is not None and native["input_sha256"] != e.digest(canonical_json(document)):
        raise e.EvaluationError("evidence control runner input provenance mismatch")
    attempts = e.score_driver_report(native, directory, pack, document["attempts"], developer.score)
    raw = native.get("attempts", [])
    for index, attempt in enumerate(attempts):
        started = time.monotonic()
        item = raw[index] if index < len(raw) else None
        eligibility = witness_eligibility(native, item, pack, document, attempt["operational_complete"])
        attempt["sufficient_evidence_validation"] = eligibility
        attempt["conditional_task_score"] = attempt["task_score"]["score"] if eligibility["eligible"] else None
        attempt["witness_scoring_milliseconds"] = (time.monotonic() - started) * 1000
    return attempts


def summarize(attempts):
    eligible = [attempt for attempt in attempts if attempt["sufficient_evidence_validation"]["eligible"]]
    verified_successes = sum(a["conditional_task_score"] for a in eligible)
    return {"declared_attempts": len(attempts), "operational_completed": sum(a["operational_complete"] for a in attempts),
        "operational_failures": sum(not a["operational_complete"] for a in attempts),
        "successful_task_attempts": sum(a["task_score"]["score"] for a in attempts),
        "conditional_eligible_attempts": len(eligible), "conditional_ineligible_attempts": len(attempts) - len(eligible),
        "conditional_successful_task_attempts": verified_successes,
        "conditional_success_rate": verified_successes / len(eligible) if eligible else None,
        "overall_task_success_rate": sum(a["task_score"]["score"] for a in attempts) / len(attempts) if attempts else None,
        "verified_control_successful_attempts": verified_successes,
        "overall_control_success_rate": verified_successes / len(attempts) if attempts else None}


def run(source, output, *, timeout=10800, format_instructions=False):
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise e.EvaluationError("report already exists")
    if type(timeout) is not int or not 60 <= timeout <= 21600:
        raise e.EvaluationError("invalid runner timeout")
    packs = controls.prepare(source)
    configuration = controls.selected_configuration(format_instructions=format_instructions)
    configuration_pin, native_configuration_pin, amendment = controls.configuration_pins(configuration)
    documents = [controls.runner_input(pack, configuration) for pack in packs]
    pack_annotations = [controls.metadata(pack) for pack in packs]
    declaration = {"witness_mode": controls.VERSION, "declared_attempts": 9,
                   "source_sha256": cases.SOURCE_SHA256,
                   "configuration_sha256": configuration_pin,
                   "native_configuration_sha256": native_configuration_pin,
                   "packs": pack_annotations}
    if amendment is not None:
        declaration["development_amendment"] = amendment
    declaration_bytes = canonical_json(declaration)
    # All source/projection/configuration/oracle pins are frozen before compile.
    with tempfile.TemporaryDirectory(prefix="boros-evidence-controls-") as temporary:
        scratch = Path(temporary).resolve(); os.chmod(scratch, 0o700)
        # Fixed hashes/counts/rationales are committed to a private local record
        # before compilation or provider execution. No answer or source text.
        e.private_write(scratch / "declared-controls.json", declaration_bytes)
        binary, implementation = e.compile_driver(scratch)
        results = []
        for index, (pack, document) in enumerate(zip(packs, documents)):
            input_path, directory = scratch / f"input-{index}.json", scratch / f"output-{index}"
            e.private_write(input_path, canonical_json(document))
            native = e.execute(binary, input_path, directory, timeout)
            try:
                attempts = score_native(native, directory, pack, document)
            except (e.EvaluationError, OSError, UnicodeError, ValueError):
                native = {"version": 1, "fatal_failure": "runner_report_invalid", "attempts": []}
                attempts = score_native(native, directory, pack, document)
            results.append({"pack": pack_annotations[index], "attempts": attempts,
                "pack_metadata_sha256": e.digest(canonical_json(pack_annotations[index])),
                "driver": e.native_metadata(native), "runner_input_sha256": e.digest(canonical_json(document))})
        attempts = [attempt for result in results for attempt in result["attempts"]]
        report = {"evidence_control_evaluation_version": 1, "witness_mode": controls.VERSION,
            "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
            "registration_status": "unregistered_development_diagnostic", "split": "development",
            "source": {"repository": "https://github.com/NAIST-SE/DevGPT", "revision": cases.REVISION,
                       "path": cases.SOURCE_PATH, "sha256": cases.SOURCE_SHA256, "bytes": cases.SOURCE_BYTES,
                       "license_status": "redistribution_permission_unverified_payload_not_in_git"},
            "configuration": {key: value for key, value in configuration.items() if key != "system"},
            "configuration_sha256": configuration_pin,
            "native_configuration_sha256": native_configuration_pin,
            "configuration_representation": "Foundation emits frozen temperature 0.0 as numeric 0; values unchanged",
            "system_sha256": e.digest(configuration["system"].encode()), "implementation": implementation,
            "declaration": declaration, "declaration_sha256": e.digest(declaration_bytes),
            "packs": results, "replicates": 1, "strategy_order": ["recent_only"],
            "summary": summarize(attempts), "rubric_version": cases.RUBRIC_VERSION,
            "five_category_quality_gate": "inconclusive",
            "limitations": ["curated complete-exchange control for exact reproduction and citation feasibility",
                "nine reused answerable development probes; no absence or representative natural reasoning",
                "full original human and assistant messages retained; code sidecars and original times excluded",
                "fixed configuration and original episode/component/output caps; no full-history over-cap inference",
                "conditional scores require complete original pack delivery and native v3 source/body/count proof",
                "native witness validation and scorer inspection run after terminalization outside episode charges; runtime accounting is not total experiment cost",
                "failures remain in overall denominator; one replicate and uncontrolled caches",
                "controlled evidence availability does not establish general recall, model-instance identity or economics"]}
        if amendment is not None:
            report["development_amendment"] = amendment
            report["limitations"].append("generic JSON output instruction amendment changes only System text; original control and paired inputs remain frozen")
        output.parent.mkdir(parents=True, exist_ok=True)
        e.private_write(output, canonical_json(report) + b"\n")
    return report


def main():
    parser = e.SafeParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=10800)
    parser.add_argument("--format-instructions", action="store_true",
                        help="Separate pinned System-only JSON format instruction amendment")
    args = parser.parse_args()
    try:
        report = run(args.source, args.output, timeout=args.timeout, format_instructions=args.format_instructions)
        print(json.dumps({"declared_attempts": report["summary"]["declared_attempts"],
                          "five_category_quality_gate": "inconclusive"}, sort_keys=True))
        return 0
    except e.EvaluationError as error:
        print("Evidence control failed: " + str(error) + ".", file=__import__("sys").stderr)
        return 1
    except Exception:
        print("Evidence control failed; content diagnostics suppressed.", file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
