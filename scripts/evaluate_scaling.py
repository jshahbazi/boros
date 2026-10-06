#!/usr/bin/env python3
"""Declare and measure provider-free synthetic retrieval scaling diagnostics."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess

import evaluate_retrieval as retrieval
from evaluation_fixtures import canonical_json, corpus_summary, generate
from evaluation_statistics import percentile

ROOT = Path(__file__).resolve().parents[1]
SCALES = (1000, 10000, 100000)
MODES = ("warm", "restart")
FILES = (*retrieval.CORE_FILES, *retrieval.PYTHON_FILES, "scripts/evaluate_scaling.py")
RESOURCE_KEYS = ("inputTokens", "outputTokens", "modelCalls", "httpAttempts", "memoryOperations",
                 "rawSourceBytes", "vectorBytes", "metadataRows", "encoderInputBytes")
IMPORT_HASHES = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in FILES}
CONFIGURATION = {"history_count_per_scale": 1, "concurrency": 1, "protocol_order": list(retrieval.PROTOCOLS),
    "context_bytes": 65536, "recent_bytes": 24000, "evidence_bytes": 12000,
    "hit_limit": 16, "read_limit": 19, "provider_requests": 0,
    "semantic_index": False, "episode_limits": "EpisodeLimits() in captured harness source",
    "environment_memory_cap_override": None, "retries": 0}
LIMITATIONS = ["one synthetic history per scale; shared prefix and query set, not independent workload samples",
    "fixed protocol and case order; OS disk cache uncontrolled; restart process opens retained store",
    "warm profile includes ingestion and lexical indexing; later warm probes benefit from earlier probes",
    "standalone harness, not full application or selected-Qwen counted answering path",
    "semantic chunks, semantic indexing backlog, RSS, model feasibility, answer latency and cost unknown",
    "paused schedule, concurrent clients, representative workload and independent 100k confirmation unrun",
    "no registered v1-v4 measurement or tree decision; endpoint timing alone does not complete N5"]


class ScalingError(ValueError):
    pass


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root: Path = None) -> dict:
    root = ROOT if root is None else root
    return {name: digest(root / name) for name in FILES}


def new_directory(path: Path) -> Path:
    if not path.is_absolute() or ".." in path.parts:
        raise ScalingError("fresh absolute output directory required")
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            if ancestor == Path("/var") and ancestor.resolve() == Path("/private/var"):
                continue
            if ancestor == Path("/tmp") and ancestor.resolve() == Path("/private/tmp"):
                continue
            raise ScalingError("caller symlink refused")
    target = path.resolve()
    if not target.is_relative_to((ROOT / ".build").resolve()):
        raise ScalingError("output must be inside the private ignored build directory")
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    target.mkdir(mode=0o700)
    return target


def write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_json(path: Path, value) -> None:
    write_bytes(path, canonical_json(value) + b"\n")


def compile_flags() -> list[str]:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ScalingError("optimized harness requires Apple silicon macOS")
    return ["-O", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macos14.0",
            "-framework", "NaturalLanguage", "-lsqlite3"]


def compile_harness(output: Path, flags: list[str]) -> Path:
    source = output / "source"
    binary = output / "retrieval-scaling"
    command = ["/usr/bin/swiftc", *flags, "-I", str(source / "Sources/CSQLite"), "-o", str(binary),
        *(str(source / name) for name in retrieval.CORE_FILES if name.endswith(".swift"))]
    result = subprocess.run(command, capture_output=True, timeout=900)
    # Compiler diagnostics can contain source text; retain them privately.
    write_bytes(output / "compile.stdout", result.stdout)
    write_bytes(output / "compile.stderr", result.stderr)
    if result.returncode != 0 or not binary.is_file():
        raise ScalingError("native compilation failed")
    return binary


def execute(binary: Path, mode: str, corpus: Path, runtime: Path, output: Path, timeout: int) -> dict:
    env = dict(os.environ)
    env.pop("BOROS_EVALUATION_MEMORY_OPERATION_CAP", None)
    with (output.parent / (mode + ".stdout")).open("xb") as out, (output.parent / (mode + ".stderr")).open("xb") as err:
        os.chmod(out.name, 0o600)
        os.chmod(err.name, 0o600)
        process = subprocess.run([str(binary), mode, str(corpus), str(runtime), str(output)],
            stdout=out, stderr=err, timeout=timeout, env=env)
    if output.exists():
        os.chmod(output, 0o600)
    if process.returncode != 0:
        raise ScalingError("native profile failed")
    return json.loads(output.read_bytes())


def numeric(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ScalingError("invalid native metric")
    return value


def distribution(values: list) -> dict:
    return {"observations": len(values), "p50": percentile(values, 0.5) if values else None,
        "p95": percentile(values, 0.95) if values else None, "maximum": max(values, default=None)}


def summarize(report: dict, mode: str, expected: dict, fixtures: dict) -> dict:
    """Validate the fixed native metadata grid and aggregate only declared metrics."""
    history_fixture = fixtures["histories"][0]
    if (report.get("schemaVersion") != 2 or report.get("mode") != mode or report.get("split") != "development"
        or report.get("fixtureVersion") != fixtures["version"] or report.get("seed") != fixtures["seed"]
        or report.get("episodeAccountingVersion") != "standalone-read-episode-v1"
        or type(report.get("histories")) is not list or len(report["histories"]) != 1):
        raise ScalingError("native report identity refused")
    history = report["histories"][0]
    if (history.get("historyID") != history_fixture["id"] or history.get("eventCount") != expected["eventCount"]
        or history.get("sourceBytes") != expected["sourceBytes"] or len(history.get("episodes", [])) != expected["episodeCount"]):
        raise ScalingError("native corpus denominator refused")
    ingestion = history.get("ingestionMilliseconds")
    if (mode == "restart" and ingestion is not None) or (mode == "warm" and ingestion is None):
        raise ScalingError("native ingestion mode refused")
    protocols = {}
    for name in retrieval.PROTOCOLS:
        observations, charges, statuses, limits, missing = [], Counter(), Counter(), Counter(), 0
        feasible_count = feasible_success = covered = required = scope = 0
        raw_metrics = {key: [] for key in ("returnedSourceBytes", "sourceReadCalls", "memoryServiceCalls", "serializedContextBytes")}
        endpoints = {key: [] for key in ("literalEndpointMilliseconds", "lexicalEndpointMilliseconds")}
        full_episodes = []
        exact_reads = []
        absence_with_hits = 0
        for row, episode in zip(history["episodes"], history_fixture["episodes"]):
            if (row.get("episodeID") != episode["id"] or row.get("historyID") != history_fixture["id"]
                or row.get("category") != episode["category"] or row.get("answerable") is not episode["answerable"]
                or row.get("prototypeByteFeasible") is not episode["prototypeByteFeasible"]
                or row.get("goldSpanCount") != len(episode["goldSpans"])
                or row.get("goldSourceIDs") != [span["eventID"] for span in episode["goldSpans"]]
                or set(row.get("protocols", {})) != set(retrieval.PROTOCOLS)):
                raise ScalingError("native probe grid refused")
            probe = row["protocols"][name]
            status = probe.get("terminalStatus")
            if status not in ("selected", "error") or type(probe.get("coverageLimited")) is not bool:
                raise ScalingError("native outcome refused")
            coverage = probe.get("goldSpanCoverage")
            if type(coverage) is not list or len(coverage) != len(episode["goldSpans"]) or any(type(v) is not bool for v in coverage):
                raise ScalingError("native span coverage refused")
            success = probe.get("allRequiredSpansPresent")
            if type(success) is not bool or success != (status == "selected" and bool(coverage) and all(coverage)):
                raise ScalingError("native source success refused")
            scope += numeric(probe.get("scopeViolations"))
            observations.append(numeric(probe.get("memoryPathMilliseconds")))
            statuses[status] += 1
            for reason in probe.get("coverageLimits", []):
                if type(reason) is not str or reason not in {"raw_source_budget", "semantic_index_incomplete", "vector_candidate_window", "semantic_pending_sources", "semantic_unsupported_sources", "semantic_failed_sources", "semantic_metadata_window", "semantic_hole_report_window", "lexical_candidate_window", "source_read_window", "returned_evidence_byte_window", "episode_budget", "episode_deadline", "mandatory_byte_envelope", "result_limit", "source_window"}:
                    raise ScalingError("unknown native coverage reason")
                limits[reason] += 1
            journal = probe.get("episodeAccounting")
            if journal is None:
                missing += 1
            else:
                receipt = journal.get("receipt", {})
                charged = receipt.get("charged", {})
                if set(charged) != set(RESOURCE_KEYS) or receipt.get("state") == "active":
                    raise ScalingError("native receipt refused")
                for key, value in charged.items():
                    if type(value) is not int:
                        raise ScalingError("native charge refused")
                    charges[key] += numeric(value)
                if charged["modelCalls"] or charged["httpAttempts"] or charged["encoderInputBytes"]:
                    raise ScalingError("provider-free native receipt refused")
                full_episodes.append(numeric(journal.get("fullEpisodeMilliseconds")))
            if episode["answerable"] and episode["prototypeByteFeasible"]:
                feasible_count += 1; feasible_success += int(success); covered += sum(coverage); required += len(coverage)
            accounting = probe.get("accounting", {})
            for key in raw_metrics:
                value = probe.get(key) if key == "serializedContextBytes" else accounting.get(key)
                if value is not None:
                    raw_metrics[key].append(numeric(value))
            if name == "raw_source_probe":
                if type(probe.get("exactReadBytesVerified")) is not bool:
                    raise ScalingError("native read verification refused")
                exact_reads.append(probe["exactReadBytesVerified"])
                if not episode["answerable"] and (probe.get("literalSourceIDs") or probe.get("lexicalSourceIDs")):
                    absence_with_hits += 1
            for key in endpoints:
                if probe.get(key) is not None:
                    endpoints[key].append(numeric(probe[key]))
        protocols[name] = {"declared_probes": expected["episodeCount"], "terminal_statuses": dict(statuses),
            "selection_failures": statuses["error"], "scope_violations": scope, "coverage_limits": dict(limits),
            "memory_path_milliseconds": distribution(observations), "full_read_episode_milliseconds": distribution(full_episodes),
            "charged_resources": dict(charges), "missing_episode_receipts": missing,
            "byte_feasible_answerable_probes": feasible_count, "complete_span_successes": feasible_success,
            "covered_required_spans": covered, "required_spans": required,
            "all_returned_read_bytes_verified": all(exact_reads) if exact_reads else None,
            "absence_probes_with_hits": absence_with_hits if name == "raw_source_probe" else None,
            **{key: distribution(values) for key, values in endpoints.items()},
            **{key: {"observations": len(values), "total": sum(values) if values else None} for key, values in raw_metrics.items()}}
    return {"event_count": expected["eventCount"], "source_bytes": expected["sourceBytes"],
        "ingestion_milliseconds": numeric(ingestion) if ingestion is not None else None,
        "store_open_milliseconds": numeric(history.get("storeOpenMilliseconds")),
        "store_bytes": numeric(history.get("storeBytes")), "harness_elapsed_milliseconds": numeric(report.get("elapsedMilliseconds")),
        "semantic_chunks": None, "indexing_backlog": None, "rss_bytes": None, "protocols": protocols}


def run(output_directory: Path, scales=SCALES, *, timeout=900) -> dict:
    if (not scales or len(set(scales)) != len(scales) or any(type(v) is not int or v not in SCALES for v in scales)
        or type(timeout) is not int or not 1 <= timeout <= 900):
        raise ScalingError("invalid scale or profile timeout")
    flags = compile_flags()
    initial = inventory()
    if initial != IMPORT_HASHES:
        raise ScalingError("loaded dependencies changed before declaration")
    output = new_directory(output_directory)
    for name in FILES:
        write_bytes(output / "source" / name, (ROOT / name).read_bytes())
    if inventory(output / "source") != initial or inventory() != initial:
        raise ScalingError("source snapshot drift")
    fixtures, corpora = {}, {}
    for scale in scales:
        fixtures[scale] = generate("development", scale_events=scale)
        corpora[scale] = corpus_summary(fixtures[scale])
        write_bytes(output / str(scale) / "fixtures.json", canonical_json(fixtures[scale]))
    declaration = {"version": "boros-synthetic-scaling-v1", "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "scales": list(scales), "modes": list(MODES), "declared_attempts": len(scales) * len(MODES),
        "attempts": [{"scale_events": scale, "mode": mode} for scale in scales for mode in MODES],
        "corpora": {str(k): v for k, v in corpora.items()}, "source_sha256": initial,
        "source_captured_before_compile": True, "compile_flags": flags, "configuration": CONFIGURATION,
        "profile_timeout_seconds": timeout, "limitations": LIMITATIONS}
    declaration_path = output / "declaration.json"
    write_json(declaration_path, declaration)
    declaration_sha = digest(declaration_path)
    attempts = []
    binary = None
    binary_sha = None
    compile_status = "failed"
    try:
        binary = compile_harness(output, flags)
        binary_sha = digest(binary)
        compile_status = "completed"
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    def unchanged():
        try:
            return (inventory() == initial and inventory(output / "source") == initial
                and digest(declaration_path) == declaration_sha and binary is not None and digest(binary) == binary_sha
                and all(digest(output / str(k) / "fixtures.json") == v["sha256"] for k, v in corpora.items()))
        except OSError:
            return False
    for scale in scales:
        warm_complete = False
        for mode in MODES:
            attempt = {"scale_events": scale, "mode": mode, "status": "compile_failed", "summary": None}
            if compile_status == "completed":
                if not unchanged():
                    attempt["status"] = "implementation_unverified"
                elif mode == "restart" and not warm_complete:
                    attempt["status"] = "prerequisite_failed"
                else:
                    directory = output / str(scale)
                    native_path = directory / (mode + ".json")
                    try:
                        native = execute(binary, mode, directory / "fixtures.json", directory / "stores", native_path, timeout)
                        summary = summarize(native, mode, corpora[scale], fixtures[scale])
                        attempt.update(status="completed", summary=summary, native_report_sha256=digest(native_path))
                        warm_complete = mode == "warm"
                    except subprocess.TimeoutExpired:
                        attempt["status"] = "timed_out"
                    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                        attempt["status"] = "profile_failed"
                    if not unchanged():
                        attempt.update(status="implementation_unverified", summary=None)
                        warm_complete = False
            attempts.append(attempt)
            write_json(output / ("attempt-" + str(len(attempts)) + ".json"), attempt)
    continuity = unchanged()
    if not continuity:
        for attempt in attempts:
            if attempt["status"] == "completed":
                attempt.update(status="implementation_unverified", summary=None)
    result = {"version": "boros-synthetic-scaling-v1", "declaration_sha256": declaration_sha,
        "declaration": declaration, "compile_status": compile_status, "binary_sha256": binary_sha,
        "implementation_continuity": continuity, "declared_attempts": len(attempts),
        "completed_attempts": sum(a["status"] == "completed" for a in attempts), "attempts": attempts,
        "provider_requests": 0, "hardware": {"architecture": platform.machine(), "macos": platform.mac_ver()[0]},
        "n5_complete": False, "registered_measurement": False}
    write_json(output / "report.json", result)
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--scales", type=int, nargs="+", choices=SCALES, default=list(SCALES))
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args(argv)
    if not args.execute:
        print("Execution requires --execute.")
        return 1
    try:
        report = run(args.output_directory, args.scales, timeout=args.timeout)
        print(json.dumps({"declared_attempts": report["declared_attempts"], "completed_attempts": report["completed_attempts"],
            "implementation_continuity": report["implementation_continuity"], "provider_requests": 0}, sort_keys=True))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Scaling diagnostic refused; no corpus or compiler diagnostics are emitted.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
