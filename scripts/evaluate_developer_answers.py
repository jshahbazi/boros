#!/usr/bin/env python3
"""Pinned DevGPT exact-quote/citation development diagnostic; content-free reports."""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile

import devgpt_answer_cases as cases
import evaluate_answers as e
from answer_rubrics import score_response, validate_oracle
from evaluation_fixtures import canonical_json

CONFIGURATION = {**e.DEFAULTS, "maximum_output": 2048}


def validate_probe(history, probe):
    validate_oracle(probe["oracle"])
    if set(probe["oracle"]["required_source_ids"]) != {span["eventID"] for span in probe["goldSpans"]}:
        raise e.EvaluationError("public developer citation source mismatch")
    if e.expected_values(history, probe) != probe["oracle"]["expected_answers"]:
        raise e.EvaluationError("public developer oracle source mismatch")


def score(history, probe, answer, operational, coverage):
    # Validate frozen source bytes independently of model output, including
    # failed attempts. Metadata alone is never citation support.
    validate_probe(history, probe)
    delivered = set(coverage["covered_required_source_ids"])
    return score_response(answer, probe["oracle"], operational_complete=operational,
                          delivered_source_ids=delivered)


def summarize(attempts):
    summary = e.summarize(attempts)
    for strategy, row in summary.items():
        row["successful_task_attempts"] = row.pop("successful_factual_attempts")
        selected = [item["task_score"] for item in attempts if item["strategy"] == strategy]
        for field in ("response_valid", "answer_correct", "citation_correct", "abstention_correct"):
            row[field + "_attempts"] = sum(item[field] for item in selected)
    return summary


def run(source, output, *, timeout=10800):
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise e.EvaluationError("report already exists")
    if type(timeout) is not int or not 60 <= timeout <= 21600:
        raise e.EvaluationError("invalid runner timeout")
    histories = cases.prepare(source)
    documents = [cases.runner_input(history, CONFIGURATION) for history in histories]
    # Freeze all oracles before any compilation, provider call or answer.
    for history in histories:
        for probe in history["episodes"]:
            validate_probe(history, probe)
    with tempfile.TemporaryDirectory(prefix="boros-developer-answers-") as temporary:
        scratch = Path(temporary).resolve(); os.chmod(scratch, 0o700)
        binary, implementation = e.compile_driver(scratch)
        results = []
        for index, (history, document) in enumerate(zip(histories, documents)):
            input_path, directory = scratch / f"input-{index}.json", scratch / f"output-{index}"
            e.private_write(input_path, canonical_json(document))
            native = e.execute(binary, input_path, directory, timeout)
            try:
                if native.get("input_sha256") is not None and native["input_sha256"] != e.digest(canonical_json(document)):
                    raise e.EvaluationError("runner input provenance mismatch")
                attempts = e.score_driver_report(native, directory, history, document["attempts"], score)
            except (e.EvaluationError, OSError, UnicodeError, ValueError):
                native = {"version": 1, "fatal_failure": "runner_report_invalid", "attempts": []}
                attempts = e.score_driver_report(native, directory, history, document["attempts"], score)
            results.append({"corpus": cases.metadata(history), "attempts": attempts,
                "summary": summarize(attempts), "driver": e.native_metadata(native),
                "runner_input_sha256": e.digest(canonical_json(document))})
        report = {"developer_answer_evaluation_version": 1, "case_version": cases.VERSION,
            "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
            "registration_status": "unregistered_development_diagnostic", "split": "development",
            "source": {"repository": "https://github.com/NAIST-SE/DevGPT", "revision": cases.REVISION,
                       "path": cases.SOURCE_PATH, "sha256": cases.SOURCE_SHA256, "bytes": cases.SOURCE_BYTES,
                       "license_status": "redistribution_permission_unverified_payload_not_in_git"},
            "configuration": {key: value for key, value in CONFIGURATION.items() if key != "system"},
            "configuration_sha256": e.digest(canonical_json(CONFIGURATION)),
            "system_sha256": e.digest(CONFIGURATION["system"].encode()), "implementation": implementation,
            "histories": results, "replicates": 1, "strategy_order": list(e.STRATEGIES),
            "rubric_version": cases.RUBRIC_VERSION, "five_category_quality_gate": "inconclusive",
            "sufficient_evidence_provider_feasibility": None,
            "limitations": ["three distinct public sharing identities do not establish independent authors or representative histories",
                "source-derived anchored questions test exact reproduction and citation, not natural developer reasoning",
                "serialized Prompt/Answer text retained; code-block sidecars excluded; original generation completeness unknown",
                "original timestamps unindexed; correction and scoped lifecycle cases not measured",
                "absence target is corpus-verified; retrieval omission alone cannot prove absence",
                "recent context has no visible event IDs; citation availability can differ between strategies",
                "one replicate; fixed paired order; caches uncontrolled; per-hybrid construction charged separately",
                "gold delivery does not establish provider-token feasibility; Apple input tokens and local billed cost unknown"]}
        output.parent.mkdir(parents=True, exist_ok=True)
        e.private_write(output, canonical_json(report) + b"\n")
    return report


def main():
    parser = e.SafeParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Exact pinned public DevGPT PR JSON")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=10800)
    args = parser.parse_args()
    try:
        report = run(args.source, args.output, timeout=args.timeout)
        print(json.dumps({"histories": len(report["histories"]),
                          "declared_attempts": sum(sum(arm["attempts"] for arm in row["summary"].values()) for row in report["histories"]),
                          "five_category_quality_gate": "inconclusive"}, sort_keys=True))
        return 0
    except e.EvaluationError as error:
        print("Developer answer evaluation failed: " + str(error) + ".", file=__import__("sys").stderr)
        return 1
    except Exception:
        print("Developer answer evaluation failed; content diagnostics suppressed.", file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
