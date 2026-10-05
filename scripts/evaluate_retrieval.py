#!/usr/bin/env python3
"""Execute frozen, public synthetic retrieval probes against the Swift core."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone

from evaluation_fixtures import canonical_json, corpus_summary, generate
from evaluation_statistics import clustered_recall, percentile


ROOT = Path(__file__).resolve().parents[1]
PREREGISTRATION = ROOT / "Tests/fixtures/evaluation/preregistration-v1.json"
PROTOCOL_AMENDMENT = ROOT / "Tests/fixtures/evaluation/development-protocol-amendment-v4.json"
CORE_FILES = ("Sources/Boros/MemoryStore.swift", "Sources/Boros/ContextAssembler.swift",
              "Sources/Boros/ChatContextPreparation.swift", "Sources/Boros/SemanticIndex.swift",
              "Sources/Boros/EpisodeBudget.swift", "Sources/Boros/EpisodeLease.swift",
              "Sources/Boros/EpisodeSQLFence.swift", "Sources/Boros/MeteredRetrieval.swift",
              "Tests/Evaluation/RetrievalHarness.swift", "Sources/CSQLite/module.modulemap",
              "Sources/CSQLite/shim.h")
PYTHON_FILES = ("scripts/evaluate_retrieval.py", "scripts/evaluation_fixtures.py", "scripts/evaluation_statistics.py")
PROTOCOLS = ("recent_only", "current_prompt_lexical", "targeted_lexical", "gui_lexical_anyterm", "raw_source_probe")


def machine_value(name: str, *, integer: bool = False):
    process = subprocess.run(["/usr/sbin/sysctl", "-n", name], capture_output=True, text=True)
    if process.returncode:
        return None
    value = process.stdout.strip()
    return int(value) if integer else value


def compile_harness(scratch: Path) -> tuple[Path, dict]:
    captured = scratch / "source"
    hashes = {}
    for relative in (*CORE_FILES, *PYTHON_FILES):
        source = ROOT / relative
        destination = captured / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        hashes[relative] = hashlib.sha256(destination.read_bytes()).hexdigest()
    binary = scratch / "retrieval-evaluation"
    command = ["/usr/bin/swiftc", "-I", str(captured / "Sources/CSQLite"), "-framework", "NaturalLanguage", "-o", str(binary),
               *(str(captured / relative) for relative in CORE_FILES if relative.endswith(".swift"))]
    subprocess.run(command, check=True, capture_output=True, text=True)
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    return binary, {"gitRevision": revision, "sourceSHA256": hashes,
                    "sourceSnapshot": "copied before compilation; hashes identify evaluated source, including uncommitted edits",
                    "swiftVersion": subprocess.run(["/usr/bin/swiftc", "--version"], capture_output=True, text=True, check=True).stdout.strip()}


def rows(report: dict) -> list[dict]:
    return [episode for history in report["histories"] for episode in history["episodes"]]


def binary_coverage(protocol: dict) -> int:
    value = protocol["allRequiredSpansPresent"]
    if type(value) is not bool:
        raise ValueError("source coverage outcome must be a strict boolean before numeric aggregation")
    return 1 if value else 0


def summarize(report: dict) -> dict:
    observations = rows(report)
    feasible = [row for row in observations if row["answerable"] and row["prototypeByteFeasible"]]
    result = {}
    for protocol in PROTOCOLS:
        metric_rows = [{"historyID": row["historyID"], "category": row["category"],
                        "recall": binary_coverage(row["protocols"][protocol])}
                       for row in feasible]
        durations = [row["protocols"][protocol]["memoryPathMilliseconds"] for row in observations]
        result[protocol] = {
            "allRequiredSpanRecall": clustered_recall(metric_rows, "recall"),
            "eligibleProbeCount": len(feasible),
            "eligibleRequiredSpanCount": sum(row["goldSpanCount"] for row in feasible),
            "coveredRequiredSpanCount": sum(sum(row["protocols"][protocol]["goldSpanCoverage"]) for row in feasible),
            "successfulProbeCount": sum(row["protocols"][protocol]["allRequiredSpansPresent"] for row in feasible),
            "selectionFailures": sum(row["protocols"][protocol]["terminalStatus"] == "error" for row in observations),
            "scopeViolations": sum(row["protocols"][protocol]["scopeViolations"] for row in observations),
            "memoryPathMilliseconds": {"p50": percentile(durations, 0.5), "p95": percentile(durations, 0.95),
                                       "maximum": max(durations)},
            "oracleScoringMilliseconds": {"p50": percentile([row["protocols"][protocol].get("oracleScoringMilliseconds", 0) for row in observations], 0.5),
                                           "p95": percentile([row["protocols"][protocol].get("oracleScoringMilliseconds", 0) for row in observations], 0.95)},
            "prototypeByteInfeasibleProbeCount": sum(row["answerable"] and not row["prototypeByteFeasible"] for row in observations),
            "absentEvidenceProbeCount": sum(not row["answerable"] for row in observations),
        }
    raw = [row["protocols"]["raw_source_probe"] for row in observations]
    for endpoint in ("literal", "lexical"):
        durations = [row[endpoint + "EndpointMilliseconds"] for row in raw
                     if row[endpoint + "EndpointMilliseconds"] is not None]
        result["raw_source_probe"][endpoint + "EndpointMilliseconds"] = {
            "p50": percentile(durations, 0.5) if durations else None,
            "p95": percentile(durations, 0.95) if durations else None,
            "maximum": max(durations, default=None)}
    result["raw_source_probe"]["allReturnedReadBytesVerified"] = all(row["exactReadBytesVerified"] for row in raw)
    result["raw_source_probe"]["absenceProbeWithAnyHits"] = sum(
        bool(row["protocols"]["raw_source_probe"]["literalSourceIDs"] or row["protocols"]["raw_source_probe"]["lexicalSourceIDs"])
        for row in observations if not row["answerable"])
    return result


def execute(binary: Path, mode: str, input_path: Path, runtime: Path, scratch: Path, *, env=None) -> dict:
    output = scratch / (mode + ".json")
    process = subprocess.run([str(binary), mode, str(input_path), str(runtime), str(output)],
                             capture_output=True, text=True, timeout=900, env=env)
    if process.returncode:
        raise RuntimeError("Swift synthetic evaluation did not complete; no content diagnostics are emitted")
    return json.loads(output.read_text())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--split", choices=("development", "validation", "held-out"), default="development")
    parser.add_argument("--profile", choices=("warm", "restart", "both"), default="both")
    parser.add_argument("--history-count", type=int, help="Development diagnostic override; never a confirmation run")
    parser.add_argument("--scale-events", type=int, choices=(1000, 10000, 100000),
                        help="One-history development endpoint-scaling diagnostic")
    parser.add_argument("--contract-only", action="store_true",
                        help="Unregistered current-source contract fixtures only; never registered measurement or decision evidence")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.contract_only:
        if args.split != "development" or args.scale_events is not None or args.history_count not in (1, 2):
            parser.error("contract-only mode requires development, an explicit history-count of 1 or 2, and no scale override")
        if args.output is None:
            args.output = ROOT / ".build/evaluation/unregistered-contract-latest.json"
        if args.output.exists():
            parser.error("contract-only output already exists; use a new path to preserve existing evidence")
    if args.split == "held-out":
        parser.error("held-out execution is blocked: freeze full Arm B/B-D configurations, provider admission, workload, power design, and a completed decision sheet first")
    if args.split == "validation":
        parser.error("protocol amendment v4 is development-only; freeze a separate validation protocol before consuming validation results")
    if (args.history_count is not None or args.scale_events is not None) and args.split != "development":
        parser.error("fixture-count and scale overrides are development diagnostics only")
    preregistration = json.loads(PREREGISTRATION.read_text())
    amendment = json.loads(PROTOCOL_AMENDMENT.read_text())
    if amendment["basePreregistrationSHA256"] != hashlib.sha256(PREREGISTRATION.read_bytes()).hexdigest():
        raise RuntimeError("Original preregistration changed; preserve it before amending a protocol")
    if not args.contract_only:
        for relative, expected in amendment["frozenEvaluationImplementationSHA256"].items():
            if hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() != expected:
                raise RuntimeError("Frozen v4 evaluation implementation changed; establish an amendment before rerunning")
    fixtures = generate(args.split, history_count=args.history_count, scale_events=args.scale_events)
    corpus = corpus_summary(fixtures)
    diagnostic = args.history_count is not None or args.scale_events is not None
    if not diagnostic and corpus != preregistration["fixtureSets"][args.split]:
        raise RuntimeError("Frozen fixture hash/count mismatch; change fixture version and preregistration instead of silently changing a run")
    if hashlib.sha256((ROOT / "scripts/evaluation_fixtures.py").read_bytes()).hexdigest() != preregistration["generatorSHA256"]:
        raise RuntimeError("Frozen fixture generator changed; establish a new preregistration version")
    with tempfile.TemporaryDirectory(prefix="boros-public-evaluation-") as temporary:
        scratch = Path(temporary)
        input_path = scratch / "fixtures.json"
        input_path.write_bytes(canonical_json(fixtures))
        binary, implementation = compile_harness(scratch)
        runtime = scratch / "stores"
        profiles = {}
        if args.profile in ("warm", "both"):
            report = execute(binary, "warm", input_path, runtime, scratch)
            profiles["warm"] = {"report": report,
                                "cacheBoundary": "Index built and probes run in one process; no provider calls/cache. Fixed protocol order warms later probes."}
            if not args.contract_only:
                profiles["warm"]["summary"] = summarize(report)
        else:
            build_report = execute(binary, "build", input_path, runtime, scratch)
            profiles["construction"] = {"report": build_report}
        if args.profile in ("restart", "both"):
            report = execute(binary, "restart", input_path, runtime, scratch)
            profiles["process_restart"] = {"report": report,
                                           "cacheBoundary": "Fresh evaluation process, retained index; OS disk cache is uncontrolled. Only the first probe per history starts after opening; later probes are warm. Provider cache/TTL absent."}
            if not args.contract_only:
                profiles["process_restart"]["summary"] = summarize(report)
        full = {"reportSchemaVersion": 4, "recordedAtUTC": datetime.now(timezone.utc).isoformat(),
                "purpose": "public synthetic partial-Arm-B retrieval groundwork; no answerer or deployment decision",
                "preregistrationSHA256": hashlib.sha256(PREREGISTRATION.read_bytes()).hexdigest(),
                "protocolAmendmentSHA256": hashlib.sha256(PROTOCOL_AMENDMENT.read_bytes()).hexdigest(),
                "diagnosticOverride": diagnostic, "fixtureSet": corpus, "implementation": implementation,
                "hardware": {"architecture": platform.machine(), "operatingSystem": platform.mac_ver()[0],
                             "machineModel": machine_value("hw.model"),
                             "logicalCPUCount": machine_value("hw.ncpu", integer=True),
                             "memoryBytes": machine_value("hw.memsize", integer=True),
                             "concurrency": 1, "providerRequests": 0},
                "profiles": profiles,
                "pending": ["semantic/metadata/neighbor-expanded Arm B", "provider-token feasible gold labels",
                            "answer quality and answer citation correctness", "complete model episode budgets/latency",
                            "paused provider-cache profile", "100k-event endpoint gate" if args.scale_events != 100000 else "independent 100k-event corpus/config confirmation",
                            "credible workload pilot and all-in costs", "B/D held-out comparison"]}
        if args.contract_only:
            full = {"contractReportSchemaVersion": 1, "recordedAtUTC": full["recordedAtUTC"],
                    "purpose": "unregistered public synthetic current-source contract checks; no registered measurement or deployment decision",
                    "executionMode": "contract-only-current-source", "registrationStatus": "unregistered",
                    "registeredProtocolApplied": False, "comparisonUse": "prohibited",
                    "historicalPreregistrationSHA256": full["preregistrationSHA256"],
                    "historicalProtocolAmendmentSHA256": full["protocolAmendmentSHA256"],
                    "fixtureSet": corpus, "implementation": implementation, "hardware": full["hardware"],
                    "profiles": profiles,
                    "limitations": ["historical protocol source pins are not applied in this explicit contract-only mode",
                                    "each retrieval protocol uses an isolated durable read episode; answering token feasibility remains unknown",
                                    "no registered source-coverage, answer quality, latency, cost, or deployment claims"]}
        if args.output is None:
            args.output = ROOT / (".build/evaluation/unregistered-contract-latest.json" if args.contract_only
                                  else ".build/evaluation/development-latest.json")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(full, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False).encode() + b"\n"
        if args.contract_only:
            with args.output.open("xb") as destination:
                destination.write(payload)
        else:
            args.output.write_bytes(payload)
        for name, profile in profiles.items():
            if "summary" in profile:
                print(json.dumps({"profile": name, "fixtureSet": corpus, "summary": profile["summary"]}, sort_keys=True, allow_nan=False))
        print("Metadata-only report: " + str(args.output.resolve()))


if __name__ == "__main__":
    main()
